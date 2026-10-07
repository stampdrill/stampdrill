import Foundation
import Stamp

/// What the script of an MCP request can reach: functions that talk to the
/// server, and the tools, resources and prompts it announced.
///
/// Expressions stay synchronous. Before a statement runs, every server call in
/// it is made, innermost first, and replaced by a name bound to its result.
/// Calls are therefore made even when `&&`, `||` or `?:` would skip them, and
/// can't be made inside a function (`=>`), whose body runs later.
final class MCPScriptSession {
    static let functions: [String: String] = [
        "call": "call(tool, arguments, meta) calls a tool",
        "read": "read(uri) reads a resource",
        "getPrompt": "getPrompt(name, arguments) gets a prompt",
        "ping": "ping() checks the server answers",
        "request": "request(method, params) sends any request",
        "notify": "notify(method, params) sends a notification",
    ]

    let client: MCPClient
    private var results = 0

    init(client: MCPClient) {
        self.client = client
    }

    /// Placeholders for the functions. They only run when a call was left in
    /// place, which happens inside `=>` functions.
    static var bindings: [String: ScopeBinding] {
        var bindings: [String: ScopeBinding] = [:]
        for (name, _) in functions {
            bindings[name] = .value(.function(NativeFunction(name) { _ throws(EvaluationError) in
                throw EvaluationError("\(name)() talks to the server, so it can't be used inside a function (=>); call it first with let")
            }))
        }
        return bindings
    }

    // MARK: Statements

    /// The statement with its server calls made.
    func prepare(_ kind: ScriptStatement.Kind, in context: Scope) async throws(EvaluationError) -> ScriptStatement.Kind {
        switch kind {
        case .assert(let condition, let message):
            // The message is only needed when the assertion fails, but it's
            // cheaper to reject calls there than to make them.
            if let message, try containsCall(message, in: context, shadowed: []) {
                throw EvaluationError("an assertion message can't call the server")
            }
            return .assert(try await resolve(condition, in: context), message: message)
        case .set(let name, let expr): return .set(name, try await resolve(expr, in: context))
        case .let(let name, let expr): return .let(name, try await resolve(expr, in: context))
        case .save(let name, let expr): return .save(name, try await resolve(expr, in: context))
        case .print(let expr): return .print(try await resolve(expr, in: context))
        case .send(let expr): return .send(try await resolve(expr, in: context))
        case .evaluate(let expr): return .evaluate(try await resolve(expr, in: context))
        case .receive, .close, .wait: return kind
        }
    }

    private func resolve(_ expr: Expr, in context: Scope) async throws(EvaluationError) -> Expr {
        switch expr {
        case .call(.identifier(let name), let arguments) where try isServerFunction(name, in: context):
            var values: [Value] = []
            for argument in arguments {
                values.append(try context.evaluate(try await resolve(argument, in: context)))
            }
            let value = try await perform(name, values)
            results += 1
            let binding = "mcp·result\(results)"
            context.assign(binding, value)
            return .identifier(binding)
        case .literal, .identifier:
            return expr
        case .member(let base, let name):
            return .member(try await resolve(base, in: context), name)
        case .index(let base, let index):
            return .index(try await resolve(base, in: context), try await resolve(index, in: context))
        case .call(let callee, let arguments):
            var resolved: [Expr] = []
            for argument in arguments { resolved.append(try await resolve(argument, in: context)) }
            return .call(try await resolve(callee, in: context), resolved)
        case .unary(let op, let operand):
            return .unary(op, try await resolve(operand, in: context))
        case .binary(let op, let lhs, let rhs):
            return .binary(op, try await resolve(lhs, in: context), try await resolve(rhs, in: context))
        case .conditional(let condition, let then, let otherwise):
            return .conditional(
                try await resolve(condition, in: context), try await resolve(then, in: context), try await resolve(otherwise, in: context)
            )
        case .array(let items):
            var resolved: [Expr] = []
            for item in items { resolved.append(try await resolve(item, in: context)) }
            return .array(resolved)
        case .object(let entries):
            var resolved: [ObjectEntry] = []
            for entry in entries {
                var copy = entry
                copy.value = try await resolve(entry.value, in: context)
                resolved.append(copy)
            }
            return .object(resolved)
        case .lambda(let parameters, let body):
            if try containsCall(body, in: context, shadowed: Set(parameters)) {
                throw EvaluationError("server calls can't be made inside a function (=>); call first with let, then use the result")
            }
            return expr
        }
    }

    private func isServerFunction(_ name: String, in context: Scope) throws(EvaluationError) -> Bool {
        guard Self.functions[name] != nil, case .function(let function)? = try context.lookup(name) else { return false }
        return function.name == name
    }

    private func containsCall(_ expr: Expr, in context: Scope, shadowed: Set<String>) throws(EvaluationError) -> Bool {
        var children: [Expr]
        var shadowed = shadowed
        switch expr {
        case .call(.identifier(let name), let arguments):
            if !shadowed.contains(name), try isServerFunction(name, in: context) { return true }
            children = arguments
        case .literal, .identifier: children = []
        case .member(let base, _): children = [base]
        case .index(let base, let index): children = [base, index]
        case .call(let callee, let arguments): children = [callee] + arguments
        case .unary(_, let operand): children = [operand]
        case .binary(_, let lhs, let rhs): children = [lhs, rhs]
        case .conditional(let condition, let then, let otherwise): children = [condition, then, otherwise]
        case .array(let items): children = items
        case .object(let entries): children = entries.map(\.value)
        case .lambda(let parameters, let body):
            shadowed.formUnion(parameters)
            children = [body]
        }
        for child in children where try containsCall(child, in: context, shadowed: shadowed) { return true }
        return false
    }

    // MARK: Calls

    private func perform(_ name: String, _ arguments: [Value]) async throws(EvaluationError) -> Value {
        func argument(_ index: Int) -> Value? {
            guard arguments.indices.contains(index), arguments[index] != .null else { return Optional.none }
            return arguments[index]
        }
        func require(_ range: ClosedRange<Int>) throws(EvaluationError) {
            guard range.contains(arguments.count) else { throw EvaluationError("usage: \(Self.functions[name]!)") }
        }
        func object(_ index: Int, _ label: String) throws(EvaluationError) -> Value? {
            guard let value = argument(index) else { return nil }
            guard case .object = value else { throw EvaluationError("\(name)(): \(label) must be an object, not \(value.typeName)") }
            return value
        }

        do {
            switch name {
            case "call":
                try require(1...3)
                var params = ObjectValue([("name", .string(arguments[0].interpolated)), ("arguments", try object(1, "arguments") ?? [:])])
                if let meta = try object(2, "meta") { params["_meta"] = meta }
                return try await answer(isTool: true) { try await self.client.request("tools/call", .object(params)) }
            case "read":
                try require(1...1)
                return try await answer { try await self.client.request("resources/read", ["uri": .string(arguments[0].interpolated)]) }
            case "getPrompt":
                try require(1...2)
                var params = ObjectValue([("name", .string(arguments[0].interpolated))])
                if case .object(let values)? = try object(1, "arguments") {
                    // Prompt arguments are strings.
                    params["arguments"] = .object(ObjectValue(values.map { key, value in
                        (key, value.stringValue.map(Value.string) ?? .string(value.jsonString()))
                    }))
                }
                return try await answer { try await self.client.request("prompts/get", .object(params)) }
            case "ping":
                try require(0...0)
                return try await answer { try await self.client.request("ping") }
            case "request":
                try require(1...2)
                let params = argument(1)
                return try await answer { try await self.client.request(arguments[0].interpolated, params) }
            case "notify":
                try require(1...2)
                try await client.notify(arguments[0].interpolated, argument(1))
                return .null
            default:
                throw EvaluationError("\(name)() is not an MCP function")
            }
        } catch let error as EvaluationError {
            throw error
        } catch {
            throw EvaluationError("\(name)(): \(error.localizedDescription)")
        }
    }

    /// The result, with `text` added when it has text content. A JSON-RPC error
    /// comes back as `{ error }` instead of stopping the script, so it can be
    /// asserted on; a tool's error also sets `isError`.
    private func answer(isTool: Bool = false, _ send: () async throws -> Value) async throws -> Value {
        do {
            var result = try await send()
            if case .object(var object) = result, object["text"] == nil {
                let items = object["content"]?.arrayValue ?? object["contents"]?.arrayValue ?? []
                let texts = items.compactMap { $0.objectValue?["text"]?.stringValue }
                if !texts.isEmpty {
                    object["text"] = .string(texts.joined(separator: "\n"))
                    result = .object(object)
                }
            }
            return result
        } catch let error as MCPError {
            var object = ObjectValue([("error", error.value)])
            if isTool {
                object["isError"] = true
                object["content"] = []
                object["text"] = .string(error.message)
            }
            return .object(object)
        }
    }
}

/// Hands what a server writes to standard error to the client, which is
/// created after the transport.
public final class MCPLogRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var client: MCPClient?
    private var early: [String] = []

    public init() {}

    public func attach(_ client: MCPClient) {
        let lines = lock.withLock {
            self.client = client
            defer { early.removeAll() }
            return early
        }
        Task { for line in lines { await client.log(line) } }
    }

    public func log(_ line: String) {
        let client = lock.withLock {
            if self.client == nil { early.append(line) }
            return self.client
        }
        if let client { Task { await client.log(line) } }
    }
}
