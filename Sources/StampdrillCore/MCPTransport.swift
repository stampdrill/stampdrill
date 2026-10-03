import Foundation
import Stamp
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Carries JSON-RPC messages between an MCP client and a server.
public protocol MCPTransport: Sendable {
    /// Starts delivering incoming messages. Called once, before anything is sent.
    /// `ended` is called with a reason if the server goes away by itself.
    func start(receive: @escaping @Sendable (Value) async -> Void, ended: @escaping @Sendable (String) async -> Void) async throws
    func send(_ message: Value) async throws
    func close() async
}

public struct MCPServerAddress: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case http(URL)
        case stdio(command: [String])
    }

    public var kind: Kind
    /// An `http(s)` URL, or `stdio:` followed by the command line, percent-encoded.
    public var url: URL

    /// `https://…/mcp`, or `stdio: node server.js --flag "quoted arg"`.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("stdio:") {
            let line = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
            let command = Self.split(line)
            var components = URLComponents()
            components.scheme = "stdio"
            components.path = line
            guard !command.isEmpty, let url = components.url else { return nil }
            kind = .stdio(command: command)
            self.url = url
        } else if let url = URL(string: trimmed.contains("://") ? trimmed : "http://" + trimmed),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
        {
            kind = .http(url)
            self.url = url
        } else {
            return nil
        }
    }

    public init?(url: URL) {
        if let command = Self.command(in: url) {
            self.init("stdio: " + command)
        } else {
            self.init(url.absoluteString)
        }
    }

    /// The command line of a `stdio:` URL.
    static func command(in url: URL) -> String? {
        guard url.scheme == "stdio" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.path
    }

    /// Shell-style words: spaces separate, quotes group, backslashes escape.
    static func split(_ text: String) -> [String] {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        var inWord = false
        for character in text {
            if escaped {
                word.append(character)
                escaped = false
            } else if character == "\\" && quote != "'" {
                escaped = true
                inWord = true
            } else if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                inWord = true
            } else if character == " " || character == "\t" {
                if inWord { words.append(word) }
                word = ""
                inWord = false
            } else {
                word.append(character)
                inWord = true
            }
        }
        if inWord { words.append(word) }
        return words
    }
}

/// Opens the transport an MCP request asks for; tests replace it with an in-memory server.
public protocol MCPConnector: Sendable {
    func transport(for address: MCPServerAddress, request: ResolvedRequest, directory: URL, onLog: @escaping @Sendable (String) -> Void) throws -> any MCPTransport
}

public struct PlatformMCPConnector: MCPConnector {
    public init() {}

    public func transport(for address: MCPServerAddress, request: ResolvedRequest, directory: URL, onLog: @escaping @Sendable (String) -> Void) throws -> any MCPTransport {
        switch address.kind {
        case .http(let url):
            return MCPHTTPTransport(url: url, headers: request.headers, timeout: request.timeout)
        case .stdio(let command):
            #if os(macOS) || os(Linux)
            return MCPStdioTransport(command: command, directory: directory, onLog: onLog)
            #else
            throw TransportError(message: "stdio MCP servers can only be started on a Mac")
            #endif
        }
    }
}

// MARK: Streamable HTTP

/// The Streamable HTTP transport: each message is POSTed, and replies come
/// back as JSON or as an event stream that can carry requests from the server.
public final class MCPHTTPTransport: MCPTransport, @unchecked Sendable {
    private let url: URL
    private let headers: [HTTPField]
    private let timeout: TimeInterval
    private let http: any StreamingHTTPTransport
    private let lock = NSLock()
    private var receive: (@Sendable (Value) async -> Void)?
    private var sessionID: String?
    private var protocolVersion: String?

    public init(url: URL, headers: [HTTPField], timeout: TimeInterval, http: any StreamingHTTPTransport = PlatformStreamingTransport()) {
        self.url = url
        self.headers = headers
        self.timeout = timeout
        self.http = http
    }

    public func start(receive: @escaping @Sendable (Value) async -> Void, ended: @escaping @Sendable (String) async -> Void) async throws {
        lock.withLock { self.receive = receive }
    }

    /// Sent with every request once the handshake has agreed on a version.
    public func setProtocolVersion(_ version: String) {
        lock.withLock { protocolVersion = version }
    }

    public func send(_ message: Value) async throws {
        let (session, version, receive) = lock.withLock { (sessionID, protocolVersion, self.receive) }
        var fields = headers.filter { !["content-type", "accept", "mcp-session-id", "mcp-protocol-version"].contains($0.name.lowercased()) }
        fields.append(HTTPField("Content-Type", "application/json"))
        fields.append(HTTPField("Accept", "application/json, text/event-stream"))
        if let session { fields.append(HTTPField("Mcp-Session-Id", session)) }
        if let version { fields.append(HTTPField("MCP-Protocol-Version", version)) }

        let request = ResolvedRequest(
            name: "mcp", method: "POST", url: url, headers: fields, body: Data(message.jsonString().utf8), timeout: timeout
        )
        let response = try await http.open(request)
        if let id = response.header("Mcp-Session-Id") { lock.withLock { sessionID = id } }

        guard (200..<300).contains(response.statusCode) else {
            var text = ""
            for try await line in response.lines { text += line + "\n"; if text.count > 2000 { break } }
            let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if response.statusCode == 404, session != nil {
                throw TransportError(message: "the server ended the session (404)")
            }
            throw TransportError(message: "the server answered \(response.statusCode)" + (detail.isEmpty ? "" : ": \(detail.prefix(300))"))
        }

        let type = response.header("Content-Type")?.lowercased() ?? ""
        if type.contains("text/event-stream") {
            var parser = ServerSentEventParser()
            for try await line in response.lines {
                if let event = parser.feed(line) { await deliver(event.data, to: receive) }
            }
            if let event = parser.finish() { await deliver(event.data, to: receive) }
        } else {
            var body = ""
            for try await line in response.lines { body += line + "\n" }
            await deliver(body, to: receive)
        }
    }

    private func deliver(_ text: String, to receive: (@Sendable (Value) async -> Void)?) async {
        guard let receive, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let value = try? Value(json: text) else { return }
        if case .array(let batch) = value {
            for message in batch { await receive(message) }
        } else {
            await receive(value)
        }
    }

    /// Ends the session on the server, when it gave one.
    public func close() async {
        guard let session = lock.withLock({ sessionID }) else { return }
        let request = ResolvedRequest(name: "mcp", method: "DELETE", url: url, headers: headers + [HTTPField("Mcp-Session-Id", session)], timeout: 5)
        if let response = try? await http.open(request) {
            do {
                for try await _ in response.lines {}
            } catch {}
        }
    }
}

// MARK: stdio

#if os(macOS) || os(Linux)
/// Runs the server as a child process and exchanges newline-delimited JSON over
/// its standard input and output. What it writes to standard error is kept as log lines.
public final class MCPStdioTransport: MCPTransport, @unchecked Sendable {
    private let command: [String]
    private let directory: URL?
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var outputSplitter = LineSplitter()
    private var errorSplitter = LineSplitter()
    private var lastErrors: [String] = []
    private var isClosing = false
    private let onLog: @Sendable (String) -> Void

    public init(command: [String], directory: URL?, onLog: @escaping @Sendable (String) -> Void) {
        self.command = command
        self.directory = directory
        self.onLog = onLog
    }

    public func start(receive: @escaping @Sendable (Value) async -> Void, ended: @escaping @Sendable (String) async -> Void) async throws {
        guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil else {
            throw TransportError(message: "stdio MCP servers can't be started from the sandboxed app; run this request with the stampdrill command-line tool")
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        if let directory { process.currentDirectoryURL = directory }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let (messages, continuation) = AsyncStream<Value>.makeStream()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            self.lock.withLock {
                self.outputSplitter.append(data) { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty, let value = try? Value(json: trimmed) { continuation.yield(value) }
                }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.lock.withLock {
                self.errorSplitter.append(data) { line in
                    guard !line.isEmpty else { return }
                    self.lastErrors = Array((self.lastErrors + [line]).suffix(3))
                    self.onLog(line)
                }
            }
        }
        let (exits, exited) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { process in
            exited.yield(process.terminationStatus)
            exited.finish()
        }
        Task {
            for await message in messages { await receive(message) }
        }
        Task { [weak self] in
            var status: Int32?
            for await code in exits { status = code }
            // Give standard error a moment to arrive before quoting it.
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, let status else { return }
            let (closing, errors) = self.lock.withLock { (self.isClosing, self.lastErrors) }
            guard !closing else { return }
            await ended("the server exited with status \(status)" + (errors.isEmpty ? "" : ": " + errors.joined(separator: " / ")))
        }

        do {
            try process.run()
        } catch {
            throw TransportError(message: "could not start '\(command.joined(separator: " "))': \(error.localizedDescription)")
        }
    }

    public func send(_ message: Value) async throws {
        guard process.isRunning else { throw TransportError(message: "the server process has exited") }
        try input.fileHandleForWriting.write(contentsOf: Data((message.jsonString() + "\n").utf8))
    }

    public func close() async {
        lock.withLock { isClosing = true }
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
    }
}
#endif
