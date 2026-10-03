import Foundation
import Stamp

/// A JSON-RPC error answered by an MCP server.
public struct MCPError: Error, LocalizedError, Sendable {
    public var code: Int
    public var message: String
    public var data: Value?

    public var errorDescription: String? { "\(message) (\(code))" }

    public var value: Value {
        var object = ObjectValue([("code", .number(Double(code))), ("message", .string(message))])
        if let data { object["data"] = data }
        return .object(object)
    }
}

/// How the client answers requests that come from the server.
public struct MCPClientReplies: Sendable {
    /// Text returned for `sampling/createMessage`.
    public var sampling: String?
    /// `accept` with content, `decline` or `cancel` for `elicitation/create`.
    public var elicitation: Elicitation?
    /// URIs returned for `roots/list`.
    public var roots: [String]?

    public enum Elicitation: Sendable {
        case accept(Value)
        case decline
        case cancel
    }

    public init(sampling: String? = nil, elicitation: Elicitation? = nil, roots: [String]? = nil) {
        self.sampling = sampling
        self.elicitation = elicitation
        self.roots = roots
    }
}

/// One MCP session: the handshake, requests and notifications, and answers to
/// what the server asks. Every message in either direction is kept, in order.
public actor MCPClient {
    public struct Record: Sendable {
        public enum Direction: Sendable { case sent, received, log }
        public var direction: Direction
        public var text: String
        public var offset: TimeInterval
    }

    public static let protocolVersion = "2025-06-18"
    public static let supportedVersions: Set<String> = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private let transport: any MCPTransport
    private let replies: MCPClientReplies
    private let timeout: TimeInterval
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Value, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private(set) public var records: [Record] = []
    private(set) public var notifications: [Value] = []
    private(set) public var serverInfo: Value = .null
    /// Notifications and stray responses that no one has taken with `nextMessage` yet.
    private var inbox: [Value] = []
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Value?, Never>)] = []
    private var isClosed = false
    private var didCloseTransport = false

    public init(transport: any MCPTransport, replies: MCPClientReplies = MCPClientReplies(), timeout: TimeInterval = 30) {
        self.transport = transport
        self.replies = replies
        self.timeout = timeout
        started = clock.now
    }

    private var elapsed: TimeInterval {
        let duration = clock.now - started
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    public func log(_ line: String) {
        let record = Record(direction: .log, text: line, offset: elapsed)
        records.append(record)
        observer?(record, nil)
    }

    // MARK: Session

    /// Connects and performs the handshake. Returns the server's `initialize` result.
    @discardableResult
    public func connect(clientName: String = "stampdrill", version: String = "1.0") async throws -> Value {
        try await transport.start(
            receive: { [weak self] message in await self?.handle(message) },
            ended: { [weak self] reason in await self?.end(reason) }
        )
        var capabilities = ObjectValue()
        if replies.sampling != nil { capabilities["sampling"] = [:] }
        if replies.elicitation != nil { capabilities["elicitation"] = [:] }
        if replies.roots != nil { capabilities["roots"] = ["listChanged": false] }

        let result = try await request("initialize", [
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object(capabilities),
            "clientInfo": ["name": .string(clientName), "title": "Stampdrill", "version": .string(version)],
        ])
        let negotiated = result.objectValue?["protocolVersion"]?.stringValue ?? Self.protocolVersion
        if !Self.supportedVersions.contains(negotiated) {
            log("the server chose protocol version \(negotiated), which this client doesn't know; continuing")
        }
        (transport as? MCPHTTPTransport)?.setProtocolVersion(negotiated)
        serverInfo = result
        try await notify("notifications/initialized")
        return result
    }

    public func close() async {
        guard !didCloseTransport else { return }
        didCloseTransport = true
        isClosed = true
        await transport.close()
        for (_, continuation) in pending {
            continuation.resume(throwing: TransportError(message: "the session was closed"))
        }
        pending.removeAll()
        for waiter in waiters { waiter.continuation.resume(returning: nil) }
        waiters.removeAll()
    }

    /// The server went away: whatever is waiting for it fails now instead of timing out.
    private func end(_ reason: String) {
        guard !isClosed else { return }
        log(reason)
        isClosed = true
        for (id, continuation) in pending {
            timeouts.removeValue(forKey: id)?.cancel()
            continuation.resume(throwing: TransportError(message: reason))
        }
        pending.removeAll()
        for waiter in waiters { waiter.continuation.resume(returning: nil) }
        waiters.removeAll()
    }

    /// The next notification, or response to a message sent with `send`, waiting up to `timeout` seconds.
    public func nextMessage(timeout: TimeInterval) async -> Value? {
        if !inbox.isEmpty { return inbox.removeFirst() }
        guard !isClosed else { return nil }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters.append((id, continuation))
            Task {
                try? await Task.sleep(for: .milliseconds(Int(timeout * 1000)))
                self.expire(id)
            }
        }
    }

    private func expire(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: nil)
    }

    private func enqueue(_ message: Value) {
        if waiters.isEmpty {
            inbox.append(message)
        } else {
            waiters.removeFirst().continuation.resume(returning: message)
        }
    }

    /// Sends a message exactly as given, without waiting for anything.
    public func send(raw message: Value) async throws {
        guard !isClosed else { throw TransportError(message: "the session was closed") }
        record(.sent, message)
        try await transport.send(message)
    }

    // MARK: Messages

    /// Sends a request and waits for its result; a JSON-RPC error throws `MCPError`.
    public func request(_ method: String, _ params: Value? = nil) async throws -> Value {
        guard !isClosed else { throw TransportError(message: "the session was closed") }
        let id = nextID
        nextID += 1
        var message = ObjectValue([("jsonrpc", "2.0"), ("id", .number(Double(id))), ("method", .string(method))])
        if let params { message["params"] = params }
        record(.sent, .object(message))

        let timeout = timeout
        let transport = transport
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await transport.send(.object(message))
                } catch {
                    self.fail(id, with: error)
                }
            }
            timeouts[id] = Task {
                guard (try? await Task.sleep(for: .milliseconds(Int(timeout * 1000)))) != nil else { return }
                self.fail(id, with: TransportError(message: "no answer to \(method) within \(Int(timeout)) s"))
            }
        }
    }

    public func notify(_ method: String, _ params: Value? = nil) async throws {
        var message = ObjectValue([("jsonrpc", "2.0"), ("method", .string(method))])
        if let params { message["params"] = params }
        record(.sent, .object(message))
        try await transport.send(.object(message))
    }

    private func fail(_ id: Int, with error: Error) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func record(_ direction: Record.Direction, _ message: Value) {
        let record = Record(direction: direction, text: message.jsonString(), offset: elapsed)
        records.append(record)
        observer?(record, message)
    }

    private var observer: (@Sendable (Record, Value?) -> Void)?

    /// Called for every message and log line as it happens, with the message when there is one.
    public func observe(_ observer: @escaping @Sendable (Record, Value?) -> Void) {
        self.observer = observer
    }

    private func handle(_ message: Value) async {
        guard case .object(let object) = message else { return }
        record(.received, message)

        if let method = object["method"]?.stringValue {
            if let id = object["id"] {
                let response = answer(method, params: object["params"])
                var reply = ObjectValue([("jsonrpc", "2.0"), ("id", id)])
                switch response {
                case .success(let result): reply["result"] = result
                case .failure(let error): reply["error"] = error.value
                }
                record(.sent, .object(reply))
                let transport = transport
                Task { try? await transport.send(.object(reply)) }
            } else {
                notifications.append(message)
                enqueue(message)
            }
            return
        }

        guard let id = object["id"]?.numberValue.map({ Int($0) }), let continuation = pending.removeValue(forKey: id) else {
            enqueue(message)
            return
        }
        timeouts.removeValue(forKey: id)?.cancel()
        if case .object(let error)? = object["error"] {
            continuation.resume(throwing: MCPError(
                code: Int(error["code"]?.numberValue ?? -32603),
                message: error["message"]?.stringValue ?? "unknown error",
                data: error["data"]
            ))
        } else {
            continuation.resume(returning: object["result"] ?? .null)
        }
    }

    /// The client's side of requests the server sends.
    private func answer(_ method: String, params: Value?) -> Result<Value, MCPError> {
        switch method {
        case "ping":
            return .success([:])
        case "sampling/createMessage":
            guard let text = replies.sampling else {
                return .failure(MCPError(code: -32601, message: "this request has no @sampling reply"))
            }
            return .success([
                "role": "assistant", "content": ["type": "text", "text": .string(text)],
                "model": "stampdrill-scripted", "stopReason": "endTurn",
            ])
        case "elicitation/create":
            switch replies.elicitation {
            case .accept(let content)?: return .success(["action": "accept", "content": content])
            case .decline?: return .success(["action": "decline"])
            case .cancel?: return .success(["action": "cancel"])
            case nil: return .failure(MCPError(code: -32601, message: "this request has no @elicitation reply"))
            }
        case "roots/list":
            guard let roots = replies.roots else { return .failure(MCPError(code: -32601, message: "this request has no @roots")) }
            return .success(["roots": .array(roots.map { ["uri": .string($0)] })])
        default:
            return .failure(MCPError(code: -32601, message: "method not found: \(method)"))
        }
    }

    // MARK: Conveniences

    /// Every item of a paginated list, following `nextCursor`.
    public func listAll(_ method: String, key: String) async throws -> [Value] {
        var items: [Value] = []
        var cursor: Value?
        for _ in 0..<100 {
            let result = try await request(method, cursor.map { ["cursor": $0] })
            if case .array(let page)? = result.objectValue?[key] { items += page }
            guard let next = result.objectValue?["nextCursor"], next != .null else { break }
            cursor = next
        }
        return items
    }

    public var capabilities: ObjectValue {
        serverInfo.objectValue?["capabilities"]?.objectValue ?? ObjectValue()
    }

    /// Everything the server offers, for the capabilities it declared. A list
    /// that fails is logged and left empty.
    public func overview() async -> MCPServerOverview {
        let capabilities = capabilities
        func list(_ capability: String, _ method: String, _ key: String) async -> [Value] {
            guard capabilities[capability] != nil else { return [] }
            do {
                return try await listAll(method, key: key)
            } catch {
                log("\(method) failed: \(error.localizedDescription)")
                return []
            }
        }
        return MCPServerOverview(
            server: serverInfo,
            tools: await list("tools", "tools/list", "tools"),
            resources: await list("resources", "resources/list", "resources"),
            resourceTemplates: await list("resources", "resources/templates/list", "resourceTemplates"),
            prompts: await list("prompts", "prompts/list", "prompts")
        )
    }
}

public struct MCPServerOverview: Sendable {
    public var server: Value
    public var tools: [Value]
    public var resources: [Value]
    public var resourceTemplates: [Value]
    public var prompts: [Value]

    public init(server: Value = .null, tools: [Value] = [], resources: [Value] = [], resourceTemplates: [Value] = [], prompts: [Value] = []) {
        self.server = server
        self.tools = tools
        self.resources = resources
        self.resourceTemplates = resourceTemplates
        self.prompts = prompts
    }

    /// The names scripts see: `server`, `tools`, `toolNames` and so on.
    public var bindings: ObjectValue {
        ObjectValue([
            ("server", server),
            ("tools", .array(tools)),
            ("toolNames", .array(tools.compactMap { $0.objectValue?["name"] })),
            ("resources", .array(resources)),
            ("resourceTemplates", .array(resourceTemplates)),
            ("prompts", .array(prompts)),
            ("promptNames", .array(prompts.compactMap { $0.objectValue?["name"] })),
        ])
    }
}
