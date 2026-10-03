import Foundation
import Testing
@testable import StampdrillCore
import Stamp

struct RunnerTests {
    private let workspace = makeWorkspace([
        "auth.stamp": """
        ### Login
        POST https://example.com/login

        { "user": "rojin" }

        > assert status == 200
        > set token = body.token
        > print "logged in as " + body.user
        """,
        "me.stamp": """
        ### Me
        @needs login
        GET https://example.com/me
        Authorization: Bearer {{token}}

        > assert status == 200
        > assert body.name == "Rojîn"
        > assert headers["x-request-id"] matches "^[a-f0-9]+$", "missing request id"
        > assert login.status == 200
        """,
        "loop.stamp": """
        ### A
        @needs b
        GET https://example.com/a

        ### B
        @needs a
        GET https://example.com/b
        """,
    ])

    private let transport = StubTransport { request in
        switch request.url.path {
        case "/login": (200, ["Content-Type": "application/json"], #"{"token":"t0k3n","user":"rojin"}"#)
        case "/me": (200, ["Content-Type": "application/json", "X-Request-Id": "abc123"], #"{"name":"Rojin"}"#)
        default: (404, [:], "not found")
        }
    }

    @Test func runsDependenciesFirstAndSharesState() async throws {
        let runner = Runner(workspace: workspace, transport: transport)
        let results = await runner.run(RequestReference(path: "me.stamp", name: "me"))

        #expect(results.map(\.reference.name) == ["login", "me"])
        #expect(results.map(\.isDependency) == [true, false])
        #expect(results[0].logs == ["logged in as rojin"])
        #expect(transport.sent.last?.header("Authorization") == "Bearer t0k3n")

        let me = results[1]
        #expect(me.assertions.map(\.passed) == [true, false, true, true])
        #expect(me.assertions[1].message == #"body.name is "Rojin""#)
        #expect(!me.passed)
        #expect(await runner.session.variables["token"] == "t0k3n")
    }

    @Test func skipsDependenciesThatAlreadyRan() async {
        let runner = Runner(workspace: workspace, transport: transport)
        _ = await runner.run(RequestReference(path: "auth.stamp", name: "login"))
        let results = await runner.run(RequestReference(path: "me.stamp", name: "me"))
        #expect(results.map(\.reference.name) == ["me"])
    }

    @Test func detectsDependencyCycles() async {
        let runner = Runner(workspace: workspace, transport: transport)
        let results = await runner.run(RequestReference(path: "loop.stamp", name: "a"))
        #expect(results.map(\.error) == ["dependency cycle: a → b → a", "needs 'a', which failed", "needs 'b', which failed"])
    }

    @Test func runsWholeFiles() async {
        let runner = Runner(workspace: workspace, transport: transport)
        let results = await runner.runFile("auth.stamp")
        #expect(results.count == 1)
        #expect(results[0].passed)
    }

    @Test func reportsTransportErrors() async {
        let failing = StubTransport { _ in throw TransportError(message: "could not connect to example.com") }
        let results = await Runner(workspace: workspace, transport: failing).run(RequestReference(path: "auth.stamp", name: "login"))
        #expect(results.first?.error == "could not connect to example.com")
    }

    @Test func exposesResponseToScripts() {
        let response = HTTPResponse(
            url: URL(string: "https://example.com")!, statusCode: 201,
            headers: [HTTPField("Content-Type", "text/plain")], body: Data("[1,2]".utf8), duration: 0.25
        )
        let value = Runner.value(of: response)
        guard case .object(let object) = value else { Issue.record("expected an object"); return }
        #expect(object["status"] == 201)
        #expect(object["body"] == [1, 2])
        #expect(object["time"] == 250)
        #expect(object["headers"] == ["content-type": "text/plain"])
    }
}

/// Answers requests from a closure and remembers what was sent.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [ResolvedRequest] = []
    private let respond: @Sendable (ResolvedRequest) throws -> (Int, [String: String], String)

    init(_ respond: @escaping @Sendable (ResolvedRequest) throws -> (Int, [String: String], String)) {
        self.respond = respond
    }

    var sent: [ResolvedRequest] {
        lock.withLock { _sent }
    }

    func send(_ request: ResolvedRequest) async throws -> HTTPResponse {
        lock.withLock { _sent.append(request) }
        let (status, headers, body) = try respond(request)
        return HTTPResponse(
            url: request.url,
            statusCode: status,
            headers: headers.map { HTTPField($0.key, $0.value) },
            body: Data(body.utf8),
            duration: 0.012
        )
    }
}

struct OAuth2Tests {
    private let workspace = makeWorkspace([
        "api.stamp": """
        @auth oauth2 client_credentials token_url=https://idp.example.com/token client_id=stampdrill client_secret={{secret("s3cr3t")}} scope="read write"

        ### One
        GET https://api.example.com/one

        ### Two
        GET https://api.example.com/two
        """,
    ])

    @Test func fetchesAndReusesTokens() async throws {
        let transport = StubTransport { request in
            if request.url.host == "idp.example.com" {
                return (200, ["Content-Type": "application/json"], #"{"access_token":"abc","token_type":"bearer","expires_in":3600}"#)
            }
            return (200, [:], request.header("Authorization") ?? "none")
        }
        let runner = Runner(workspace: workspace, transport: transport)
        let results = await runner.runFile("api.stamp")

        #expect(results.map(\.response?.bodyText) == ["Bearer abc", "Bearer abc"])
        #expect(transport.sent.map(\.url.host) == ["idp.example.com", "api.example.com", "api.example.com"])
        #expect(transport.sent[0].bodyText == "grant_type=client_credentials&client_id=stampdrill&client_secret=s3cr3t&scope=read%20write")
        #expect(results[0].request?.masked("Bearer abc") == "Bearer ••••••")
    }

    @Test func reportsTokenErrors() async {
        let transport = StubTransport { _ in
            (401, ["Content-Type": "application/json"], #"{"error":"invalid_client","error_description":"unknown client"}"#)
        }
        let results = await Runner(workspace: workspace, transport: transport).runFile("api.stamp")
        #expect(results.first?.error == "could not get an OAuth 2 token: 401 Unauthorized: unknown client")
    }
}

struct WebSocketRunnerTests {
    /// Echoes every message, after a greeting.
    final class EchoSockets: WebSocketTransport, @unchecked Sendable {
        final class Connection: WebSocketConnection, @unchecked Sendable {
            private let lock = NSLock()
            private var queue = ["welcome"]
            private(set) var closed = false

            func send(_ text: String) async throws {
                lock.withLock { queue.append("echo: " + text) }
            }

            func receive(timeout: TimeInterval) async throws -> String? {
                lock.withLock { queue.isEmpty ? nil : queue.removeFirst() }
            }

            func close() async {
                lock.withLock { closed = true }
            }
        }

        let connection = Connection()
        private(set) var request: ResolvedRequest?

        func connect(_ request: ResolvedRequest) async throws -> any WebSocketConnection {
            self.request = request
            return connection
        }
    }

    @Test func playsScriptsAgainstTheSocket() async throws {
        let workspace = makeWorkspace(["ws.stamp": """
        ### Chat
        WS https://chat.example.com/socket
        Sec-WebSocket-Protocol: chat

        > receive
        > assert message == "welcome"
        > send json({ type: "hello", n: 1 })
        > receive 2s
        > assert message contains "hello"
        > set replied = message
        > receive 100ms
        > assert message == null
        > close
        """])
        let sockets = EchoSockets()
        let runner = Runner(workspace: workspace, transport: StubTransport { _ in (500, [:], "") }, webSockets: sockets)
        let result = try #require(await runner.run(RequestReference(path: "ws.stamp", name: "chat")).first)

        #expect(result.error == nil)
        #expect(sockets.request?.url.absoluteString == "wss://chat.example.com/socket")
        #expect(result.assertions.map(\.passed) == [true, true, true])
        #expect(result.messages.map(\.direction) == [.received, .sent, .received, .event])
        #expect(result.messages[1].text == #"{"type":"hello","n":1}"#)
        #expect(result.response?.statusCode == 101)
        #expect(sockets.connection.closed)
        #expect(await runner.session.variables["replied"] == #"echo: {"type":"hello","n":1}"#)
    }

    @Test func refusesSocketStatementsInHTTPRequests() async throws {
        let workspace = makeWorkspace(["a.stamp": "GET https://example.com\n\n> send \"x\""])
        let result = try #require(await Runner(workspace: workspace, transport: StubTransport { _ in (200, [:], "") }).run(RequestReference(path: "a.stamp", name: "a")).first)
        #expect(result.logs == ["line 3: 'send' only works in WS and MCP requests"])
    }
}
