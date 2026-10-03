import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Stamp

public struct AssertionResult: Hashable, Sendable {
    public var source: String
    public var line: Int
    public var passed: Bool
    public var message: String?
}

public struct RunResult: Identifiable, Sendable {
    public let id = UUID()
    public var reference: RequestReference
    public var startedAt: Date
    public var request: ResolvedRequest?
    public var response: HTTPResponse?
    public var assertions: [AssertionResult] = []
    public var logs: [String] = []
    /// The conversation of a WebSocket request.
    public var messages: [SocketMessage] = []
    /// Values from `save` statements, in the order they were saved.
    public var savedVariables: [(name: String, value: Value)] = []
    public var error: String?
    /// Set when the request ran only because another one needed it.
    public var isDependency = false

    public var passed: Bool {
        error == nil && assertions.allSatisfy(\.passed)
    }
}

/// State that outlives a single request: values stored with `set` and the
/// responses of requests that already ran, addressable by request name.
public actor Session {
    public private(set) var variables: [String: Value] = [:]
    public private(set) var responses: [String: Value] = [:]
    private var tokens: [String: (authorization: String, expires: Date?)] = [:]

    public init() {}

    /// A session that starts with another one's values and responses.
    public init(copying other: Session) async {
        variables = await other.variables
        responses = await other.responses
    }

    func token(for key: String) -> String? {
        guard let token = tokens[key] else { return nil }
        if let expires = token.expires, expires <= Date() {
            tokens[key] = nil
            return nil
        }
        return token.authorization
    }

    func store(token authorization: String, expiresIn seconds: Double?, for key: String) {
        // Renew a little early so a token doesn't expire mid-flight.
        tokens[key] = (authorization, seconds.map { Date().addingTimeInterval(max($0 - 30, 0)) })
    }

    public func set(_ name: String, _ value: Value) {
        variables[name] = value
    }

    public func remove(_ name: String) {
        variables[name] = nil
    }

    public func record(response: Value, for name: String) {
        responses[name] = response
    }

    public func reset() {
        variables.removeAll()
        responses.removeAll()
        tokens.removeAll()
    }

    /// Named responses first, so a `set` with the same name wins.
    public var bindings: [String: Value] {
        responses.merging(variables) { _, variable in variable }
    }
}

public struct Runner: Sendable {
    public var workspace: Workspace
    public var selection: DimensionSelection
    public var overrides: [String: Value]
    public var defaultTimeout: TimeInterval
    public let session: Session
    public let transport: any HTTPTransport
    public let webSockets: any WebSocketTransport
    public let ice: any ICETransport
    public let mcp: any MCPConnector

    public init(
        workspace: Workspace, selection: DimensionSelection = [:], overrides: [String: Value] = [:],
        defaultTimeout: TimeInterval = 30, session: Session = Session(), transport: any HTTPTransport,
        webSockets: any WebSocketTransport = PlatformWebSocketTransport(), ice: any ICETransport = NetworkICETransport(),
        mcp: any MCPConnector = PlatformMCPConnector()
    ) {
        self.workspace = workspace
        self.selection = selection
        self.overrides = overrides
        self.defaultTimeout = defaultTimeout
        self.session = session
        self.transport = transport
        self.webSockets = webSockets
        self.ice = ice
        self.mcp = mcp
    }

    /// Runs a request, first running any `@needs` dependency that has no
    /// response in the session yet. Results come back in the order they ran.
    public func run(
        _ reference: RequestReference, onResult: (@Sendable (RunResult) -> Void)? = nil
    ) async -> [RunResult] {
        var results: [RunResult] = []
        var visiting: [String] = []
        await run(reference, isDependency: false, visiting: &visiting, results: &results, onResult: onResult)
        return results
    }

    /// Runs every request of a file from top to bottom.
    public func runFile(_ path: String, onResult: (@Sendable (RunResult) -> Void)? = nil) async -> [RunResult] {
        guard let file = workspace.file(at: path) else { return [] }
        var results: [RunResult] = []
        for request in file.document.requests {
            if Task.isCancelled { break }
            results += await run(RequestReference(path: path, name: request.name), onResult: onResult)
        }
        return results
    }

    private func run(
        _ reference: RequestReference, isDependency: Bool, visiting: inout [String],
        results: inout [RunResult], onResult: (@Sendable (RunResult) -> Void)?
    ) async {
        var result = RunResult(reference: reference, startedAt: Date(), isDependency: isDependency)
        func finish() {
            results.append(result)
            onResult?(result)
        }

        guard let (file, request) = workspace.request(reference) else {
            result.error = "no request named '\(reference.name)' in \(reference.path)"
            return finish()
        }

        let key = reference.path + "#" + reference.name
        if let start = visiting.firstIndex(of: key) {
            let cycle = visiting[start...].map { $0.components(separatedBy: "#").last! } + [reference.name]
            result.error = "dependency cycle: " + cycle.joined(separator: " → ")
            return finish()
        }
        visiting.append(key)
        defer { visiting.removeLast() }

        for dependency in request.dependencies {
            guard await session.responses[dependency] == nil else { continue }
            guard let target = workspace.request(named: dependency, near: file) else {
                result.error = "'@needs \(dependency)': no request has that name"
                return finish()
            }
            await run(target, isDependency: true, visiting: &visiting, results: &results, onResult: onResult)
            if let failed = results.last, failed.reference == target, failed.error != nil {
                result.error = "needs '\(dependency)', which failed"
                return finish()
            }
        }

        let input = ResolutionInput(
            selection: selection, session: await session.bindings, overrides: overrides, defaultTimeout: defaultTimeout
        )
        let context = RequestResolver.scope(for: request, in: file, workspace: workspace, input: input)

        let resolved: ResolvedRequest
        do {
            resolved = try RequestResolver.resolve(request, in: file, scope: context, defaultTimeout: defaultTimeout)
        } catch {
            result.error = error.description
            return finish()
        }
        var outgoing = resolved
        do {
            outgoing = try await authorized(resolved)
        } catch {
            result.request = outgoing
            result.error = error.localizedDescription
            return finish()
        }
        result.request = outgoing

        guard !Task.isCancelled else {
            result.error = "cancelled"
            return finish()
        }

        if request.isWebSocket {
            await runWebSocket(request, outgoing, context: context, result: &result)
            return finish()
        }
        if request.isICE {
            await runICE(request, outgoing, context: context, result: &result)
            return finish()
        }
        if request.isMCP {
            await runMCP(request, outgoing, file: file, context: context, result: &result)
            return finish()
        }

        let response: HTTPResponse
        do {
            response = try await transport.send(outgoing)
        } catch {
            result.error = error.localizedDescription
            return finish()
        }
        result.response = response

        let responseValue = Self.value(of: response)
        await session.record(response: responseValue, for: request.name)
        await runScript(request.script, context: context, response: responseValue, result: &result)
        finish()
    }

    /// Opens the socket, sends the body if there is one, then plays the script
    /// against the live connection. The transcript becomes the response body.
    private func runWebSocket(_ request: RequestBlock, _ outgoing: ResolvedRequest, context: Scope, result: inout RunResult) async {
        let clock = ContinuousClock()
        let start = clock.now
        let connection: any WebSocketConnection
        do {
            connection = try await webSockets.connect(outgoing)
        } catch {
            result.error = error.localizedDescription
            return
        }
        func elapsed() -> TimeInterval {
            let duration = clock.now - start
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }

        var socket = SocketContext(connection: connection, elapsed: elapsed)
        if let body = outgoing.bodyText, !body.isEmpty {
            do {
                try await connection.send(body)
                socket.messages.append(SocketMessage(direction: .sent, text: body, offset: elapsed()))
            } catch {
                result.error = error.localizedDescription
            }
        }

        let opening: Value = ["status": 101, "headers": [:], "body": .null, "text": "", "time": 0, "size": 0, "url": .string(outgoing.url.absoluteString)]
        await runScript(request.script, context: context, response: opening, result: &result, socket: &socket)
        await connection.close()
        socket.messages.append(SocketMessage(direction: .event, text: "closed", offset: elapsed()))
        result.messages = socket.messages

        let transcript: Value = .array(socket.messages.map { message in
            ["direction": .string(message.direction.rawValue), "text": .string(message.text), "at": .number((message.offset * 1000).rounded())]
        })
        let response = HTTPResponse(
            url: outgoing.url, statusCode: 101, headers: [HTTPField("Content-Type", "application/json")],
            body: Data(transcript.jsonString(pretty: true).utf8), duration: elapsed()
        )
        result.response = response
        await session.record(response: Self.value(of: response), for: request.name)
    }

    /// Checks a STUN or TURN server. The report becomes a JSON body, and the
    /// status is 200 or the server's STUN error code (401, 438, 486…).
    private func runICE(_ request: RequestBlock, _ outgoing: ResolvedRequest, context: Scope, result: inout RunResult) async {
        guard let server = ICEServer(outgoing.url.absoluteString, kind: request.method == "TURN" ? .turn : .stun) else {
            result.error = "'\(outgoing.url.absoluteString)' is not a STUN or TURN server"
            return
        }
        // TURN credentials come from `@auth basic`, like `username` and `credential` in RTCIceServer.
        var credentials: (username: String, password: String)?
        if let authorization = outgoing.header("Authorization"), authorization.hasPrefix("Basic "),
           let decoded = Data(base64Encoded: String(authorization.dropFirst(6))).map({ String(decoding: $0, as: UTF8.self) }),
           let colon = decoded.firstIndex(of: ":")
        {
            credentials = (String(decoded[..<colon]), String(decoded[decoded.index(after: colon)...]))
        }

        let started = Date()
        do {
            let outcome = try await ICEProbe.run(
                server, credentials: credentials, transport: ice, timeout: request.timeout ?? min(defaultTimeout, 10),
                allowsInsecureConnections: outgoing.allowsInsecureConnections
            )
            let response = HTTPResponse(
                url: outgoing.url, statusCode: outcome.statusCode, headers: [HTTPField("Content-Type", "application/json")],
                body: Data(outcome.report.jsonString(pretty: true).utf8), duration: Date().timeIntervalSince(started)
            )
            result.response = response
            let value = Self.value(of: response)
            await session.record(response: value, for: request.name)
            await runScript(request.script, context: context, response: value, result: &result)
        } catch {
            result.error = error.localizedDescription
        }
    }

    /// Connects to an MCP server and lists its tools, resources and prompts,
    /// then plays the script against the session. The lists are the body, and
    /// every message in either direction is the timeline.
    private func runMCP(_ request: RequestBlock, _ outgoing: ResolvedRequest, file: WorkspaceFile, context: Scope, result: inout RunResult) async {
        guard let address = MCPServerAddress(url: outgoing.url) else {
            result.error = "'\(outgoing.target)' is not an MCP server"
            return
        }

        let replies: MCPClientReplies
        do {
            replies = try Self.mcpReplies(for: request, in: context)
        } catch {
            result.error = error.description
            return
        }

        let relay = MCPLogRelay()
        let client: MCPClient
        do {
            let transport = try mcp.transport(
                for: address, request: outgoing, directory: file.url.deletingLastPathComponent(), onLog: { relay.log($0) }
            )
            client = MCPClient(transport: transport, replies: replies, timeout: outgoing.timeout)
            relay.attach(client)
        } catch {
            result.error = error.localizedDescription
            return
        }

        let started = Date()
        var overview: ObjectValue
        do {
            try await client.connect()
            overview = await client.overview().bindings
        } catch {
            result.error = "the MCP handshake failed: \(error.localizedDescription)"
            await client.close()
            result.messages = await Self.messages(of: client)
            return
        }

        func response(_ body: ObjectValue) -> HTTPResponse {
            HTTPResponse(
                url: outgoing.url, statusCode: 200, headers: [HTTPField("Content-Type", "application/json")],
                body: Data(Value.object(body).jsonString(pretty: true).utf8), duration: Date().timeIntervalSince(started)
            )
        }

        var bindings = MCPScriptSession.bindings
        for (name, value) in overview { bindings[name] = .value(value) }
        bindings["notifications"] = .value([])
        let session = MCPScriptSession(client: client)
        var noSocket: SocketContext?
        await runScript(
            request.script, context: context, response: Self.value(of: response(overview)), result: &result,
            socket: &noSocket, mcp: session, bindings: bindings
        )
        await client.close()

        overview["notifications"] = .array(await client.notifications)
        result.messages = await Self.messages(of: client)
        let final = response(overview)
        result.response = final
        await self.session.record(response: Self.value(of: final), for: request.name)
    }

    private static func messages(of client: MCPClient) async -> [SocketMessage] {
        await client.records.map(SocketMessage.init)
    }

    /// How the client answers the server's own requests, from `@sampling`,
    /// `@elicitation` and `@roots`.
    public static func mcpReplies(for request: RequestBlock, in context: Scope) throws(ResolutionError) -> MCPClientReplies {
        var replies = MCPClientReplies()
        let line = request.requestLine
        if let reply = request.samplingReply {
            replies.sampling = try RequestResolver.render(reply, line: line, in: context)
        }
        switch request.elicitationReply {
        case .accept(let template)?:
            let text = try RequestResolver.render(template, line: line, in: context)
            guard let content = try? Value(json: text), case .object = content else {
                throw ResolutionError("'@elicitation accept' needs a JSON object, such as { \"name\": \"Ada\" }", line: line)
            }
            replies.elicitation = .accept(content)
        case .decline?: replies.elicitation = .decline
        case .cancel?: replies.elicitation = .cancel
        case nil: break
        }
        if let roots = request.roots {
            replies.roots = try roots.map { template throws(ResolutionError) in try RequestResolver.render(template, line: line, in: context) }
        }
        return replies
    }

    /// The request with an OAuth 2 token added, when it needs one; tokens are
    /// cached in the session until they expire.
    public func authorized(_ resolved: ResolvedRequest) async throws -> ResolvedRequest {
        guard let tokenRequest = resolved.tokenRequest else { return resolved }
        var outgoing = resolved
        do {
            let authorization = try await token(for: tokenRequest)
            outgoing.headers.append(HTTPField("Authorization", authorization))
            outgoing.secrets.insert(String(authorization.split(separator: " ").last ?? ""))
            outgoing.tokenRequest = nil
        } catch {
            throw TransportError(message: "could not get an OAuth 2 token: \(error.localizedDescription)")
        }
        return outgoing
    }

    struct SocketContext {
        var connection: any WebSocketConnection
        var elapsed: () -> TimeInterval
        var messages: [SocketMessage] = []
    }

    private func token(for tokenRequest: OAuth2TokenRequest) async throws -> String {
        if let cached = await session.token(for: tokenRequest.cacheKey) { return cached }

        let response = try await transport.send(tokenRequest.request)
        let value = try? Value(json: response.body)
        guard (200..<300).contains(response.statusCode), case .object(let object)? = value,
              case .string(let accessToken)? = object["access_token"]
        else {
            let detail = value.flatMap { v -> String? in
                guard case .object(let o) = v else { return nil }
                return (o["error_description"] ?? o["error"])?.interpolated
            }
            throw TransportError(message: "\(response.statusCode) \(response.reason)" + (detail.map { ": " + $0 } ?? ""))
        }

        var type = object["token_type"]?.stringValue ?? "Bearer"
        if type.lowercased() == "bearer" { type = "Bearer" }
        let authorization = type + " " + accessToken
        await session.store(token: authorization, expiresIn: object["expires_in"]?.numberValue, for: tokenRequest.cacheKey)
        return authorization
    }

    private func runScript(_ script: [ScriptStatement], context: Scope, response: Value, result: inout RunResult) async {
        var noSocket: SocketContext?
        await runScript(script, context: context, response: response, result: &result, socket: &noSocket)
    }

    private func runScript(_ script: [ScriptStatement], context: Scope, response: Value, result: inout RunResult, socket: inout SocketContext) async {
        var optional: SocketContext? = socket
        await runScript(script, context: context, response: response, result: &result, socket: &optional)
        if let optional { socket = optional }
    }

    private func runScript(
        _ script: [ScriptStatement], context: Scope, response: Value, result: inout RunResult, socket: inout SocketContext?,
        mcp: MCPScriptSession? = nil, bindings extra: [String: ScopeBinding] = [:]
    ) async {
        guard !script.isEmpty, case .object(let fields) = response else { return }
        var bindings: [String: ScopeBinding] = ["response": .value(response)]
        for (key, value) in fields { bindings[key] = .value(value) }
        bindings.merge(extra) { _, new in new }
        context.push(Scope.Layer("response", bindings))

        for statement in script {
            do throws(EvaluationError) {
                var kind = statement.kind
                if let mcp {
                    kind = try await mcp.prepare(kind, in: context)
                    context.assign("notifications", .array(await mcp.client.notifications))
                }
                switch kind {
                case .assert(let condition, let message):
                    let passed = try context.evaluate(condition).isTruthy
                    var detail: String?
                    if !passed, let message {
                        detail = try context.evaluate(message).interpolated
                    } else if !passed, case .assert(let written, _) = statement.kind {
                        detail = Self.explain(condition, written: written, in: context)
                    }
                    result.assertions.append(AssertionResult(source: statement.source, line: statement.line, passed: passed, message: detail))
                case .set(let name, let expr):
                    let value = try context.evaluate(expr)
                    await session.set(name, value)
                    context.assign(name, value)
                case .save(let name, let expr):
                    let value = try context.evaluate(expr)
                    await session.set(name, value)
                    context.assign(name, value)
                    result.savedVariables.removeAll { $0.name == name }
                    result.savedVariables.append((name, value))
                case .let(let name, let expr):
                    context.assign(name, try context.evaluate(expr))
                case .print(let expr):
                    result.logs.append(try context.evaluate(expr).interpolated)
                case .wait(let seconds):
                    try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                case .send(let expr) where mcp != nil:
                    var message = try context.evaluate(expr)
                    if case .string(let text) = message {
                        guard let parsed = try? Value(json: text) else { throw EvaluationError("'send' in an MCP request needs a JSON-RPC message") }
                        message = parsed
                    }
                    do {
                        try await mcp!.client.send(raw: message)
                    } catch {
                        result.logs.append("line \(statement.line): \(error.localizedDescription)")
                    }
                case .receive(let timeout) where mcp != nil:
                    if let message = await mcp!.client.nextMessage(timeout: timeout ?? 10) {
                        context.assign("message", .string(message.jsonString()))
                        context.assign("data", message)
                    } else {
                        context.assign("message", .null)
                        context.assign("data", .null)
                        result.logs.append("line \(statement.line): no message within \(formatSeconds(timeout ?? 10))")
                    }
                    context.assign("notifications", .array(await mcp!.client.notifications))
                case .close where mcp != nil:
                    await mcp!.client.close()
                case .send(let expr):
                    guard let current = socket else { throw EvaluationError("'send' only works in WS and MCP requests") }
                    let value = try context.evaluate(expr)
                    let text = switch value { case .array, .object: value.jsonString(); default: value.interpolated }
                    do {
                        try await current.connection.send(text)
                        socket?.messages.append(SocketMessage(direction: .sent, text: text, offset: current.elapsed()))
                    } catch {
                        result.logs.append("line \(statement.line): \(error.localizedDescription)")
                    }
                case .receive(let timeout):
                    guard let current = socket else { throw EvaluationError("'receive' only works in WS and MCP requests") }
                    let text = try? await current.connection.receive(timeout: timeout ?? 10)
                    if let text {
                        socket?.messages.append(SocketMessage(direction: .received, text: text, offset: current.elapsed()))
                        context.assign("message", .string(text))
                        context.assign("data", (try? Value(json: text)) ?? .null)
                    } else {
                        context.assign("message", .null)
                        context.assign("data", .null)
                        result.logs.append("line \(statement.line): no message within \(formatSeconds(timeout ?? 10))")
                    }
                case .close:
                    guard let current = socket else { throw EvaluationError("'close' only works in WS and MCP requests") }
                    await current.connection.close()
                case .evaluate(let expr):
                    _ = try context.evaluate(expr)
                }
            } catch {
                if case .assert = statement.kind {
                    result.assertions.append(AssertionResult(source: statement.source, line: statement.line, passed: false, message: error.message))
                } else {
                    result.logs.append("line \(statement.line): \(error.message)")
                }
            }
        }
    }

    /// For a failed comparison, says what the left side actually was. `written`
    /// is the condition as it appears in the file, before server calls were made.
    private static func explain(_ condition: Expr, written: Expr, in context: Scope) -> String? {
        guard case .binary(let op, let lhs, _) = condition, case .binary(_, let writtenLHS, _) = written else { return nil }
        switch op {
        case .equal, .notEqual, .less, .lessOrEqual, .greater, .greaterOrEqual, .contains, .matches:
            guard let actual = try? context.evaluate(lhs) else { return nil }
            let text = actual.debugText
            return "\(writtenLHS) is \(text.count > 120 ? String(text.prefix(120)) + "…" : text)"
        default:
            return nil
        }
    }

    /// The `response` object scripts and later requests see.
    public static func value(of response: HTTPResponse) -> Value {
        var headers = ObjectValue()
        for field in response.headers { headers[field.name.lowercased()] = .string(field.value) }

        let text = response.bodyText
        var body: Value = .string(text)
        if response.isJSON || text.first.map({ $0 == "{" || $0 == "[" }) == true, let json = try? Value(json: response.body) {
            body = json
        }

        return [
            "status": .number(Double(response.statusCode)),
            "headers": .object(headers),
            "body": body,
            "text": .string(text),
            "time": .number((response.duration * 1000).rounded()),
            "size": .number(Double(response.body.count)),
            "url": .string(response.url.absoluteString),
        ]
    }
}

private func formatSeconds(_ seconds: Double) -> String {
    seconds < 1 ? "\(Int(seconds * 1000)) ms" : "\(formatNumberText(seconds)) s"
}

private func formatNumberText(_ number: Double) -> String {
    number == number.rounded() ? String(Int(number)) : String(number)
}
