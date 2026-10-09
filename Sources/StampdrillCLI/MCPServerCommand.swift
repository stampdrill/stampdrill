import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StampdrillCore
import Stamp

/// `stampdrill mcp`: serves a workspace to an AI agent over the Model Context
/// Protocol, on stdio.
///
/// The agent writes `.stamp` files with its ordinary file tools and uses these
/// tools to run them and read what came back, so what it produces stays in the
/// repository rather than in a conversation.
struct MCPServerCommand {
    let arguments: Arguments
    let terminal: Terminal

    private static let latestProtocol = "2025-11-25"
    private static let supportedProtocols = ["2025-11-25", "2025-06-18", "2025-03-26"]
    /// Bodies are summarised past this, so a large response can't fill a context window.
    private static let bodyLimit = 4000

    func execute() async throws -> Int32 {
        let root = arguments.paths.first ?? "."
        log("stampdrill mcp on \(URL(fileURLWithPath: root).standardizedFileURL.path)")

        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let message = try? Value(json: Data(line.utf8)), let request = message.objectValue else {
                send(error: nil, code: -32700, message: "the line is not JSON")
                continue
            }
            let id = request["id"]
            let method = request["method"]?.stringValue ?? ""
            let params = request["params"]?.objectValue ?? ObjectValue([])

            do {
                guard let result = try await handle(method: method, params: params, root: root) else {
                    continue  // a notification, which takes no reply
                }
                if id != nil { send(id: id, result: result) }
            } catch let error as Failure {
                send(error: id, code: error.code, message: error.message)
            } catch {
                send(error: id, code: -32603, message: error.localizedDescription)
            }
        }
        return 0
    }

    // MARK: Methods

    private func handle(method: String, params: ObjectValue, root: String) async throws -> Value? {
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.stringValue ?? Self.latestProtocol
            let version = Self.supportedProtocols.contains(asked) ? asked : Self.latestProtocol
            return .object(ObjectValue([
                ("protocolVersion", .string(version)),
                ("capabilities", .object(ObjectValue([("tools", .object(ObjectValue([("listChanged", .bool(false))])))]))),
                ("serverInfo", .object(ObjectValue([
                    ("name", .string("stampdrill")),
                    ("title", .string("Stampdrill")),
                    ("version", .string(Stampdrill.version)),
                ]))),
                ("instructions", .string("""
                    Requests, assertions, test plans and load tests live in .stamp files in the workspace. \
                    Write them with your file tools, then use check to find mistakes before sending anything, \
                    run_request to send one, run_plan for a multi step plan and run_load for a load test. \
                    The language reference is at https://stampdrill.com/language/.
                    """)),
            ]))
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return .object(ObjectValue([]))
        case "tools/list":
            return .object(ObjectValue([("tools", .array(Self.tools))]))
        case "tools/call":
            return try await call(params: params, root: root)
        default:
            throw Failure(code: -32601, message: "unknown method '\(method)'")
        }
    }

    // MARK: Tools

    private static let workspaceArgument: (String, Value) = (
        "workspace",
        .object(ObjectValue([
            ("type", .string("string")),
            ("description", .string("Folder or file to work in, relative to where the server was started. Defaults to the whole workspace.")),
        ]))
    )

    private static func schema(_ properties: [(String, Value)], required: [String] = []) -> Value {
        .object(ObjectValue([
            ("type", .string("object")),
            ("properties", .object(ObjectValue(properties + [workspaceArgument]))),
            ("required", .array(required.map(Value.string))),
        ]))
    }

    private static let tools: [Value] = [
        tool("list_requests", "Every request, test plan and load test in the workspace, with the file each one is in.",
             schema([])),
        tool("check", "Parse every file and report mistakes without sending anything. Run this after writing a file.",
             schema([])),
        tool("run_request", "Send one request and return its status, timing, assertions and body. Dependencies declared with @needs run first.",
             schema([
                ("request", .object(ObjectValue([
                    ("type", .string("string")),
                    ("description", .string("Name of the request, or 'file.stamp#name' when two files use the same name.")),
                ]))),
                ("dimensions", .object(ObjectValue([
                    ("type", .string("object")),
                    ("description", .string("Dimension values to select, such as {\"environment\": \"qa\"}.")),
                    ("additionalProperties", .object(ObjectValue([("type", .string("string"))]))),
                ]))),
                ("variables", .object(ObjectValue([
                    ("type", .string("object")),
                    ("description", .string("Variables to override for this run.")),
                    ("additionalProperties", .object(ObjectValue([("type", .string("string"))]))),
                ]))),
             ], required: ["request"])),
        tool("run_plan", "Run a test plan over its matrix and return what passed and what failed.",
             schema([("plan", .object(ObjectValue([("type", .string("string")), ("description", .string("Name of the plan."))])))],
                    required: ["plan"])),
        tool("run_load", "Run a load test and return throughput, latency percentiles, failures and whether the thresholds held.",
             schema([("test", .object(ObjectValue([("type", .string("string")), ("description", .string("Name of the load test."))])))],
                    required: ["test"])),
        tool("show_environment", "The dimensions the workspace declares and the variables they resolve to.",
             schema([
                ("dimensions", .object(ObjectValue([
                    ("type", .string("object")),
                    ("description", .string("Dimension values to resolve for.")),
                    ("additionalProperties", .object(ObjectValue([("type", .string("string"))]))),
                ]))),
             ])),
    ]

    private static func tool(_ name: String, _ description: String, _ schema: Value) -> Value {
        .object(ObjectValue([
            ("name", .string(name)),
            ("description", .string(description)),
            ("inputSchema", schema),
        ]))
    }

    private func call(params: ObjectValue, root: String) async throws -> Value {
        let name = params["name"]?.stringValue ?? ""
        let input = params["arguments"]?.objectValue ?? ObjectValue([])
        let path = input["workspace"]?.stringValue.map { $0.hasPrefix("/") ? $0 : root + "/" + $0 } ?? root

        do {
            let target = try WorkspaceTarget(path)
            switch name {
            case "list_requests": return text(listing(target))
            case "check": return try check(target)
            case "run_request": return await runRequest(target, input: input)
            case "run_plan": return try await runPlan(target, input: input)
            case "run_load": return try await runLoad(target, input: input)
            case "show_environment": return environment(target, input: input)
            default: throw Failure(code: -32602, message: "unknown tool '\(name)'")
            }
        } catch let error as UsageError {
            return text(error.description, isError: true)
        }
    }

    // MARK: The work

    private func listing(_ target: WorkspaceTarget) -> String {
        var lines: [String] = []
        for file in target.files {
            let plans = file.document.plans
            guard !file.document.requests.isEmpty || !plans.isEmpty else { continue }
            lines.append(file.relativePath)
            for request in file.document.requests {
                lines.append("  \(request.method.padding(toLength: 7, withPad: " ", startingAt: 0))\(request.name)" + (request.title.map { "  \($0)" } ?? ""))
            }
            for plan in plans {
                lines.append("  \(plan.load == nil ? "plan   " : "load   ")\(plan.name)")
            }
        }
        return lines.isEmpty ? "The workspace has no requests yet." : lines.joined(separator: "\n")
    }

    private func check(_ target: WorkspaceTarget) throws -> Value {
        var problems: [String] = []
        for file in target.files {
            for diagnostic in file.document.diagnostics {
                problems.append("\(file.relativePath):\(diagnostic.range.start.line):\(diagnostic.range.start.column + 1): \(diagnostic.message)")
            }
        }
        if problems.isEmpty {
            let requests = target.files.reduce(0) { $0 + $1.document.requests.count }
            return text("No problems. \(target.files.count) file\(target.files.count == 1 ? "" : "s"), \(requests) request\(requests == 1 ? "" : "s").")
        }
        return text(problems.joined(separator: "\n"), isError: true)
    }

    private func selection(_ target: WorkspaceTarget, _ input: ObjectValue) -> DimensionSelection {
        var selection = target.workspace.environment.defaultSelection
        for (name, value) in input["dimensions"]?.objectValue ?? ObjectValue() {
            selection[name] = value.stringValue == "*" ? nil : value.stringValue
        }
        return selection
    }

    private func overrides(_ input: ObjectValue) -> [String: Value] {
        Dictionary(uniqueKeysWithValues: (input["variables"]?.objectValue ?? ObjectValue()).map { ($0.key, $0.value) })
    }

    private func runRequest(_ target: WorkspaceTarget, input: ObjectValue) async -> Value {
        guard let wanted = input["request"]?.stringValue else {
            return text("run_request needs a 'request' argument", isError: true)
        }
        guard let reference = reference(in: target, named: wanted) else {
            return text("no request called '\(wanted)'. Use list_requests to see what is there.", isError: true)
        }
        let runner = Runner(
            workspace: target.workspace, selection: selection(target, input), overrides: overrides(input),
            transport: PlatformHTTPTransport(userAgent: "stampdrill")
        )
        let results = await runner.run(reference)
        guard let last = results.last else { return text("nothing ran", isError: true) }

        var lines: [String] = []
        for result in results where result.isDependency {
            lines.append("(first ran \(result.reference.name): \(result.response.map { "\($0.statusCode)" } ?? "failed"))")
        }
        if let response = last.response {
            lines.append("\(response.statusCode) \(formatDuration(response.duration)) \(formatBytes(response.body.count))")
        }
        if let error = last.error { lines.append("error: \(error)") }
        for assertion in last.assertions {
            lines.append("\(assertion.passed ? "✓" : "✗") \(assertion.source)" + (assertion.message.map { ": \($0)" } ?? ""))
        }
        for message in last.logs { lines.append("| \(message)") }
        if let body = last.response?.formattedBody, !body.isEmpty {
            lines.append("")
            lines.append(body.count > Self.bodyLimit ? String(body.prefix(Self.bodyLimit)) + "\n… \(body.count - Self.bodyLimit) more characters" : body)
        }
        return text(lines.joined(separator: "\n"), isError: !last.passed)
    }

    private func reference(in target: WorkspaceTarget, named wanted: String) -> RequestReference? {
        if let separator = wanted.firstIndex(of: "#") {
            let path = String(wanted[..<separator]), name = String(wanted[wanted.index(after: separator)...])
            if let file = target.files.first(where: { $0.relativePath == path || $0.relativePath.hasSuffix("/" + path) }) {
                return RequestReference(path: file.relativePath, name: name)
            }
            return nil
        }
        for file in target.files {
            if file.document.requests.contains(where: { $0.name == wanted }) {
                return RequestReference(path: file.relativePath, name: wanted)
            }
        }
        return nil
    }

    private func plan(in target: WorkspaceTarget, named wanted: String, load: Bool) -> (WorkspaceFile, TestPlan)? {
        for file in target.files {
            for plan in file.document.plans where plan.name == wanted && (plan.load != nil) == load {
                return (file, plan)
            }
        }
        return nil
    }

    private func runPlan(_ target: WorkspaceTarget, input: ObjectValue) async throws -> Value {
        guard let wanted = input["plan"]?.stringValue else { return text("run_plan needs a 'plan' argument", isError: true) }
        guard let (file, plan) = plan(in: target, named: wanted, load: false) else {
            return text("no test plan called '\(wanted)'", isError: true)
        }
        let runner = PlanRunner(
            workspace: target.workspace, selection: selection(target, input), overrides: overrides(input),
            transport: PlatformHTTPTransport(userAgent: "stampdrill")
        )
        let report = try await runner.run(PlanReference(path: file.relativePath, name: plan.name))
        var lines: [String] = []
        for iteration in report.iterations {
            lines.append("\(iteration.passed ? "✓" : "✗") \(iteration.label.isEmpty ? "run" : iteration.label)  \(formatDuration(iteration.duration))")
            for event in iteration.events {
                for expectation in event.expectations where !expectation.passed {
                    lines.append("    ✗ \(expectation.source)" + (expectation.message.map { ": \($0)" } ?? ""))
                }
            }
        }
        let counts = report.expectationCounts
        lines.append("\(report.passed ? "✓" : "✗") \(report.iterations.count) iteration\(report.iterations.count == 1 ? "" : "s"), \(report.runs.count) requests, \(counts.passed + counts.failed) checks")
        return text(lines.joined(separator: "\n"), isError: !report.passed)
    }

    private func runLoad(_ target: WorkspaceTarget, input: ObjectValue) async throws -> Value {
        guard let wanted = input["test"]?.stringValue else { return text("run_load needs a 'test' argument", isError: true) }
        guard let (file, plan) = plan(in: target, named: wanted, load: true) else {
            return text("no load test called '\(wanted)'", isError: true)
        }
        let runner = LoadRunner(
            workspace: target.workspace, selection: selection(target, input), overrides: overrides(input),
            transport: PlatformHTTPTransport(userAgent: "stampdrill")
        )
        let report = try await runner.run(PlanReference(path: file.relativePath, name: plan.name))
        let snapshot = report.snapshot
        var lines = [
            "requests  \(snapshot.requests) in \(formatDuration(snapshot.elapsed)), \(String(format: "%.1f", snapshot.requestsPerSecond))/s, \(snapshot.failedRequests) failed",
            "latency   p50 \(Int(snapshot.p50)) ms  p95 \(Int(snapshot.p95)) ms  p99 \(Int(snapshot.p99)) ms",
            "checks    \(snapshot.checksPassed) passed, \(snapshot.checksFailed) failed, \(snapshot.iterations) iterations",
        ]
        for threshold in report.thresholds {
            lines.append("\(threshold.passed ? "✓" : "✗") \(threshold.threshold.source)")
        }
        for failure in report.failures.prefix(5) { lines.append("×\(failure.count) \(failure.message)") }
        let passed = report.thresholds.allSatisfy(\.passed)
        lines.append(passed ? "✓ passed" : "✗ failed")
        return text(lines.joined(separator: "\n"), isError: !passed)
    }

    private func environment(_ target: WorkspaceTarget, input: ObjectValue) -> Value {
        let environment = target.workspace.environment
        var lines: [String] = []
        for dimension in environment.dimensions {
            lines.append("dimension \(dimension.name) = \(dimension.values.joined(separator: ", "))")
        }
        if !lines.isEmpty { lines.append("") }
        for entry in environment.applicableEntries(for: selection(target, input)) {
            for declaration in entry.set.declarations {
                let kind: String
                switch declaration.value {
                case .text: kind = "text"
                case .expression: kind = "expression"
                case .function: kind = "function"
                }
                let hidden = SensitiveData.isSensitiveName(declaration.name)
                lines.append("\(declaration.name)  \(hidden ? "(hidden)" : kind)  [\(entry.origin)]")
            }
        }
        return text(lines.isEmpty ? "The workspace declares no dimensions or variables." : lines.joined(separator: "\n"))
    }

    // MARK: Transport

    private struct Failure: Error {
        var code: Int
        var message: String
    }

    private func text(_ body: String, isError: Bool = false) -> Value {
        .object(ObjectValue([
            ("content", .array([.object(ObjectValue([("type", .string("text")), ("text", .string(body))]))])),
            ("isError", .bool(isError)),
        ]))
    }

    private func send(id: Value?, result: Value) {
        write(.object(ObjectValue([("jsonrpc", .string("2.0")), ("id", id ?? .null), ("result", result)])))
    }

    private func send(error id: Value?, code: Int, message: String) {
        write(.object(ObjectValue([
            ("jsonrpc", .string("2.0")), ("id", id ?? .null),
            ("error", .object(ObjectValue([("code", .number(Double(code))), ("message", .string(message))]))),
        ])))
    }

    private func write(_ value: Value) {
        FileHandle.standardOutput.write(Data((value.jsonString() + "\n").utf8))
    }

    /// Diagnostics go to stderr: stdout carries the protocol and nothing else.
    private func log(_ message: String) {
        FileHandle.standardError.write(Data("stampdrill mcp: \(message)\n".utf8))
    }
}
