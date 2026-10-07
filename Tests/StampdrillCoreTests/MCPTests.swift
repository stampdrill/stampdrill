import Foundation
import Testing
@testable import StampdrillCore
@testable import Stamp

struct MCPPartsTests {
    @Test func parsesEventStreams() {
        var parser = ServerSentEventParser()
        var events: [ServerSentEvent] = []
        for line in [": comment", "event: message", "id: 7", "data: {\"a\":", "data: 1}", "", "data: tail"] {
            if let event = parser.feed(line) { events.append(event) }
        }
        if let event = parser.finish() { events.append(event) }
        #expect(events == [
            ServerSentEvent(event: "message", data: "{\"a\":\n1}", id: "7"),
            ServerSentEvent(event: "message", data: "tail", id: "7"),
        ])
    }

    @Test func readsServerAddresses() throws {
        let http = try #require(MCPServerAddress("localhost:3001/mcp"))
        #expect(http.kind == .http(URL(string: "http://localhost:3001/mcp")!))

        let stdio = try #require(MCPServerAddress(#"stdio: node "my server.js" --name 'a b' plain\ word"#))
        #expect(stdio.kind == .stdio(command: ["node", "my server.js", "--name", "a b", "plain word"]))
        #expect(MCPServerAddress(url: stdio.url) == stdio)

        let resolved = ResolvedRequest(name: "s", method: "MCP", url: stdio.url)
        #expect(resolved.target == #"stdio: node "my server.js" --name 'a b' plain\ word"#)
        #expect(MCPServerAddress("ftp://example.com") == nil)
        #expect(MCPServerAddress("stdio:   ") == nil)
    }

    @Test func parsesClientReplies() {
        let document = Document.parse("""
        ### Weather
        @sampling reply Sunny, {{temperature}}°C
        @elicitation accept { "name": "Ada" }
        @roots file:///work/app, file:///work/lib
        MCP stdio: node server.js

        > notify("notifications/roots/list_changed")
        """)
        #expect(document.diagnostics.isEmpty)
        let request = document.requests[0]
        #expect(request.isMCP)
        #expect(request.rawTarget == "stdio: node server.js")
        #expect(request.samplingReply != nil)
        guard case .accept? = request.elicitationReply else {
            Issue.record("expected an accept reply")
            return
        }
        #expect(request.roots?.count == 2)
        guard case .evaluate(.call(.identifier("notify"), _)) = request.script.first?.kind else {
            Issue.record("expected a call statement")
            return
        }

        let declining = Document.parse("###\n@elicitation decline\nMCP http://localhost/mcp")
        guard case .decline? = declining.requests[0].elicitationReply else {
            Issue.record("expected decline")
            return
        }
        let broken = Document.parse("###\n@sampling Sunny\n@elicitation maybe\nMCP http://localhost/mcp")
        #expect(broken.diagnostics.map(\.message) == [
            "'@sampling' needs a reply, like '@sampling reply Sunny, 24°C'",
            "'@elicitation' takes 'accept { … }', 'decline' or 'cancel'",
        ])
    }
}

struct MCPHTTPTransportTests {
    @Test func postsMessagesAndReadsEventStreams() async throws {
        let http = StreamStub { request in
            if request.method == "DELETE" { return (200, [:], []) }
            let message = try Value(json: request.body ?? Data())
            let id = message.objectValue?["id"] ?? .null
            let reply = Value.object(ObjectValue([("jsonrpc", "2.0"), ("id", id), ("result", ["ok": true])]))
            return (200, ["Content-Type": "text/event-stream", "Mcp-Session-Id": "abc"], [
                "event: message", "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\"}", "",
                "data: " + reply.jsonString(), "",
            ])
        }
        let transport = MCPHTTPTransport(url: URL(string: "https://example.com/mcp")!, headers: [HTTPField("Authorization", "Bearer t")], timeout: 5, http: http)
        let received = Collected()
        try await transport.start(receive: { await received.add($0) }, ended: { _ in })

        try await transport.send(["jsonrpc": "2.0", "id": 1, "method": "initialize"])
        transport.setProtocolVersion("2025-06-18")
        try await transport.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        await transport.close()

        #expect(await received.values.count == 4)
        let requests = http.requests
        #expect(requests.map(\.method) == ["POST", "POST", "DELETE"])
        #expect(requests[0].header("Accept") == "application/json, text/event-stream")
        #expect(requests[0].header("Authorization") == "Bearer t")
        #expect(requests[0].header("Mcp-Session-Id") == nil)
        #expect(requests[1].header("Mcp-Session-Id") == "abc")
        #expect(requests[1].header("MCP-Protocol-Version") == "2025-06-18")
        #expect(requests[2].header("Mcp-Session-Id") == "abc")
    }

    @Test func reportsHTTPErrors() async throws {
        let http = StreamStub { _ in (401, ["Content-Type": "application/json"], ["{\"error\":\"unauthorized\"}"]) }
        let transport = MCPHTTPTransport(url: URL(string: "https://example.com/mcp")!, headers: [], timeout: 5, http: http)
        try await transport.start(receive: { _ in }, ended: { _ in })
        await #expect(throws: TransportError.self) {
            try await transport.send(["jsonrpc": "2.0", "id": 1, "method": "ping"])
        }
    }
}

struct MCPRunnerTests {
    private func run(_ source: String, server: FakeMCPServer = FakeMCPServer()) async -> RunResult? {
        let workspace = makeWorkspace(["mcp.stamp": source])
        let runner = Runner(workspace: workspace, transport: StubTransport { _ in (500, [:], "") }, mcp: FakeConnector(server: server))
        return await runner.runFile("mcp.stamp").last
    }

    @Test func connectsListsAndCallsTools() async throws {
        let server = FakeMCPServer()
        let result = try #require(await run("""
        ### Tools
        MCP http://localhost:3001/mcp

        > assert server.serverInfo.name == "fake"
        > assert toolNames contains "add"
        > assert resources.length == 3
        > assert promptNames == ["greet"]
        > assert call("add", { a: 2, b: 3 }).text == "5"
        > let sum = call("add", { a: call("add", { a: 1, b: 1 }).structuredContent.sum, b: 40 })
        > assert sum.structuredContent.sum == 42
        > assert read("memo://one").text == "hello"
        > assert getPrompt("greet", { name: "Ada", times: 2 }).messages[0].content.text == "Hi Ada ×2"
        > assert ping() == {}
        """, server: server))

        #expect(result.error == nil)
        #expect(result.logs == [])
        #expect(result.assertions.filter { !$0.passed }.map(\.message) == [])
        #expect(result.assertions.count == 9)
        #expect(result.assertions.filter { !$0.passed }.map(\.source) == [])
        #expect(result.response?.statusCode == 200)
        #expect(result.messages.contains { $0.direction == .event && $0.text.contains("resources/templates/list failed") })
        #expect(await server.closed)

        let body = try #require(result.response.map { try Value(json: $0.body) })
        #expect(body.objectValue?["toolNames"] == ["add", "boom", "ask", "confirm", "progress"])
    }

    @Test func turnsErrorsIntoValues() async throws {
        let result = try #require(await run("""
        MCP http://localhost:3001/mcp

        > let broken = call("boom")
        > assert broken.isError
        > assert broken.text == "it broke"
        > let missing = call("nope", {})
        > assert missing.isError && missing.error.code == -32602
        > assert request("unknown/method").error.code == -32601
        > assert call("add", { a: 1, b: 1 }).text == "3"
        """))
        #expect(result.error == nil)
        let failed = result.assertions.filter { !$0.passed }
        #expect(failed.map(\.message) == [#"call("add", {a: 1, b: 1}).text is "2""#])
    }

    @Test func answersSamplingAndElicitation() async throws {
        let result = try #require(await run("""
        let city = "Paris"
        ###
        @sampling reply Sunny in {{city}}
        @elicitation accept { "confirmed": true }
        @roots file:///work
        MCP http://localhost:3001/mcp

        > assert call("ask").text == "model said: Sunny in Paris"
        > assert call("confirm").text == "accept {\\"confirmed\\":true}"
        > assert request("roots/check").roots[0].uri == "file:///work"
        """))
        #expect(result.error == nil)
        #expect(result.assertions.filter { !$0.passed }.map(\.message) == [])
        #expect(result.messages.contains { $0.direction == .received && $0.text.contains("sampling/createMessage") })
    }

    @Test func refusesServerRequestsWithoutAReply() async throws {
        let result = try #require(await run("""
        MCP http://localhost:3001/mcp

        > assert call("ask").text == "model said: this request has no @sampling reply"
        """))
        #expect(result.assertions.first?.passed == true)
    }

    @Test func collectsNotificationsAndRawMessages() async throws {
        let result = try #require(await run("""
        MCP http://localhost:3001/mcp

        > assert call("progress", {}, { progressToken: "p1" }).text == "done"
        > assert notifications.length == 1
        > assert notifications[0].params.progressToken == "p1"
        > receive 1s
        > assert data.method == "notifications/progress"
        > send { jsonrpc: "2.0", id: "raw", method: "ping" }
        > receive 1s
        > assert data.id == "raw"
        > notify("notifications/cancelled", { requestId: 99 })
        > receive 50ms
        > assert data == null
        """))
        #expect(result.error == nil)
        #expect(result.assertions.filter { !$0.passed }.map(\.source) == [])
        #expect(result.logs == ["line 12: no message within 50 ms"])
    }

    @Test func refusesServerCallsInsideFunctions() async throws {
        let result = try #require(await run("""
        MCP http://localhost:3001/mcp

        > let texts = map(toolNames, name => call(name).text)
        > let call = x => x + 1
        > assert call(1) == 2
        """))
        #expect(result.logs.first?.contains("inside a function") == true)
        #expect(result.assertions.first?.passed == true)
    }

    @Test func reportsAFailedHandshake() async throws {
        let result = try #require(await run("""
        MCP http://localhost:3001/mcp
        """, server: FakeMCPServer(refusesHandshake: true)))
        #expect(result.error == "the MCP handshake failed: unsupported protocol version (-32602)")
        #expect(result.messages.count == 2)
    }
}

// MARK: Fakes

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Value] = []
    func add(_ value: Value) { lock.withLock { items.append(value) } }
    var values: [Value] { lock.withLock { items } }
}

private final class StreamStub: StreamingHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [ResolvedRequest] = []
    private let respond: @Sendable (ResolvedRequest) throws -> (Int, [String: String], [String])

    init(_ respond: @escaping @Sendable (ResolvedRequest) throws -> (Int, [String: String], [String])) {
        self.respond = respond
    }

    var requests: [ResolvedRequest] { lock.withLock { sent } }

    func open(_ request: ResolvedRequest) async throws -> StreamingResponse {
        lock.withLock { sent.append(request) }
        let (status, headers, lines) = try respond(request)
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
        return StreamingResponse(statusCode: status, headers: headers.map { HTTPField($0.key, $0.value) }, lines: stream)
    }
}

struct FakeConnector: MCPConnector {
    let server: FakeMCPServer

    func transport(for address: MCPServerAddress, request: ResolvedRequest, directory: URL, onLog: @escaping @Sendable (String) -> Void) throws -> any MCPTransport {
        server
    }
}

/// A small MCP server that answers in-process, including requests of its own to the client.
actor FakeMCPServer: MCPTransport {
    private let refusesHandshake: Bool
    private var receive: (@Sendable (Value) async -> Void)?
    private var waiting: [String: CheckedContinuation<Value, Never>] = [:]
    private var nextID = 0
    private(set) var closed = false

    init(refusesHandshake: Bool = false) {
        self.refusesHandshake = refusesHandshake
    }

    func start(receive: @escaping @Sendable (Value) async -> Void, ended: @escaping @Sendable (String) async -> Void) async throws {
        self.receive = receive
    }

    func close() async {
        closed = true
    }

    func send(_ message: Value) async throws {
        guard case .object(let object) = message else { return }
        let id = object["id"]
        guard let method = object["method"]?.stringValue else {
            // The client answering one of our requests.
            if let key = id?.stringValue, let continuation = waiting.removeValue(forKey: key) {
                continuation.resume(returning: message)
            }
            return
        }
        guard let id else { return }
        let params = object["params"]?.objectValue ?? ObjectValue()
        Task { await self.handle(method, params, id: id) }
    }

    private func reply(_ id: Value, result: Value? = nil, error: (Int, String)? = nil) async {
        var message = ObjectValue([("jsonrpc", "2.0"), ("id", id)])
        if let error {
            message["error"] = ["code": .number(Double(error.0)), "message": .string(error.1)]
        } else {
            message["result"] = result ?? [:]
        }
        await receive?(.object(message))
    }

    private func ask(_ method: String, _ params: Value) async -> Value {
        nextID += 1
        let id = "s\(nextID)"
        let receive = receive
        return await withCheckedContinuation { continuation in
            waiting[id] = continuation
            Task { await receive?(["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": params]) }
        }
    }

    private func text(_ text: String, structured: Value? = nil) -> Value {
        var result = ObjectValue([("content", [["type": "text", "text": .string(text)]])])
        if let structured { result["structuredContent"] = structured }
        return .object(result)
    }

    private func handle(_ method: String, _ params: ObjectValue, id: Value) async {
        switch method {
        case "initialize":
            if refusesHandshake { return await reply(id, error: (-32602, "unsupported protocol version")) }
            await reply(id, result: [
                "protocolVersion": "2025-06-18",
                "capabilities": ["tools": [:], "resources": [:], "prompts": [:]],
                "serverInfo": ["name": "fake", "version": "0.1"],
            ])
        case "tools/list":
            await reply(id, result: ["tools": .array(["add", "boom", "ask", "confirm", "progress"].map { ["name": .string($0), "inputSchema": ["type": "object"]] })])
        case "resources/list":
            if params["cursor"] == nil {
                await reply(id, result: ["resources": [["uri": "memo://one"], ["uri": "memo://two"]], "nextCursor": "page2"])
            } else {
                await reply(id, result: ["resources": [["uri": "memo://three"]]])
            }
        case "resources/read":
            await reply(id, result: ["contents": [["uri": params["uri"] ?? .null, "text": "hello"]]])
        case "prompts/list":
            await reply(id, result: ["prompts": [["name": "greet"]]])
        case "prompts/get":
            let arguments = params["arguments"]?.objectValue
            let greeting = "Hi \(arguments?["name"]?.stringValue ?? "?") ×\(arguments?["times"]?.stringValue ?? "?")"
            await reply(id, result: ["messages": [["role": "user", "content": ["type": "text", "text": .string(greeting)]]]])
        case "ping":
            await reply(id)
        case "roots/check":
            let answer = await ask("roots/list", [:])
            await reply(id, result: answer.objectValue?["result"])
        case "tools/call":
            let arguments = params["arguments"]?.objectValue ?? ObjectValue()
            switch params["name"]?.stringValue {
            case "add":
                let sum = (arguments["a"]?.numberValue ?? 0) + (arguments["b"]?.numberValue ?? 0)
                await reply(id, result: text(Value.number(sum).interpolated, structured: ["sum": .number(sum)]))
            case "boom":
                await reply(id, result: ["content": [["type": "text", "text": "it broke"]], "isError": true])
            case "ask":
                let answer = await ask("sampling/createMessage", ["messages": [], "maxTokens": 10])
                let said = answer.objectValue?["result"]?.objectValue?["content"]?.objectValue?["text"]?.stringValue
                    ?? answer.objectValue?["error"]?.objectValue?["message"]?.stringValue ?? "?"
                await reply(id, result: text("model said: " + said))
            case "confirm":
                let answer = await ask("elicitation/create", ["message": "Sure?", "requestedSchema": ["type": "object"]])
                let result = answer.objectValue?["result"]?.objectValue
                await reply(id, result: text("\(result?["action"]?.stringValue ?? "?") \(result?["content"]?.jsonString() ?? "")"))
            case "progress":
                let token = params["_meta"]?.objectValue?["progressToken"] ?? .null
                await receive?(["jsonrpc": "2.0", "method": "notifications/progress", "params": ["progressToken": token, "progress": 1]])
                await reply(id, result: text("done"))
            default:
                await reply(id, error: (-32602, "Unknown tool"))
            }
        default:
            await reply(id, error: (-32601, "Method not found"))
        }
    }
}

struct MCPTestSnippetTests {
    @Test func writesACallWithAssertions() {
        let result: Value = ["content": [["type": "text", "text": "Echo: hi"]]]
        let lines = MCPTestSnippet.lines(for: .call(tool: "echo", arguments: ObjectValue([("message", "hi"), ("repeat-count", 2)])), result: result, existing: [])
        #expect(lines == [
            #"let echo = call("echo", { message: "hi", "repeat-count": 2 })"#,
            "assert !echo.isError",
            #"assert echo.text == "Echo: hi""#,
        ])
    }

    @Test func avoidsTakenNamesAndChecksStructuredContent() {
        let existing = Document.parse("MCP http://localhost/mcp\n\n> let getSum = 1\n> let getSum2 = 2").requests[0].script
        let result: Value = ["content": [], "structuredContent": ["sum": 42, "detail": ["a": 1], "unit": "none", "report": "Line one\nLine two"]]
        let lines = MCPTestSnippet.lines(for: .call(tool: "get-sum", arguments: ObjectValue()), result: result, existing: existing)
        #expect(lines == [
            #"let getSum3 = call("get-sum", {})"#,
            "assert !getSum3.isError",
            "assert getSum3.structuredContent.sum == 42",
            #"assert getSum3.structuredContent.unit == "none""#,
            #"assert getSum3.structuredContent.report contains "Line one""#,
        ])
    }

    @Test func recordsErrorsAndLongText() {
        let failed = MCPTestSnippet.lines(for: .getPrompt(name: "map", arguments: ObjectValue()), result: ["error": ["code": -32602, "message": "bad"]], existing: [])
        #expect(failed == [#"let mapResult = getPrompt("map")"#, "assert mapResult.error.code == -32602"])

        let long = String(repeating: "word ", count: 40) + "\nsecond line"
        let read = MCPTestSnippet.lines(for: .read(uri: "docs://guide/intro.md"), result: ["contents": [["uri": "docs://guide/intro.md", "text": .string(long)]]], existing: [])
        #expect(read == [
            #"let introMd = read("docs://guide/intro.md")"#,
            "assert introMd.contents.length == 1",
            #"assert introMd.text contains "word word word word word word word word""#,
        ])
        #expect(MCPTestSnippet.identifier(from: "2fa-code") == "result2faCode")
    }

    @Test func snippetsParseAndPass() async throws {
        let lines = MCPTestSnippet.lines(for: .call(tool: "add", arguments: ObjectValue([("a", 2), ("b", 3)])), result: ["content": [["type": "text", "text": "5"]], "structuredContent": ["sum": 5]], existing: [])
        let source = "MCP http://localhost/mcp\n\n" + lines.map { "> " + $0 }.joined(separator: "\n")
        let workspace = makeWorkspace(["mcp.stamp": source])
        let runner = Runner(workspace: workspace, transport: StubTransport { _ in (500, [:], "") }, mcp: FakeConnector(server: FakeMCPServer()))
        let result = try #require(await runner.runFile("mcp.stamp").last)
        #expect(Document.parse(source).diagnostics.isEmpty)
        #expect(result.assertions.count == 2)
        #expect(result.assertions.filter { !$0.passed }.isEmpty)
    }
}

struct MCPArgumentFormTests {
    private let schema = try! Value(json: """
    {
      "type": "object",
      "properties": {
        "city": { "type": "string", "description": "Where" },
        "days": { "type": "integer", "default": 3 },
        "units": { "type": "string", "enum": ["metric", "imperial"] },
        "detailed": { "type": "boolean" },
        "tags": { "type": "array", "items": { "type": "string" } },
        "note": { "anyOf": [{ "type": "string" }, { "type": "null" }], "default": null },
        "ratio": { "type": ["number", "null"] }
      },
      "required": ["city", "tags"]
    }
    """)

    @Test func readsFieldsFromTheSchema() {
        let form = MCPArgumentForm(schema: schema)
        #expect(form.fields.map(\.name) == ["city", "days", "units", "detailed", "tags", "note", "ratio"])
        #expect(form.fields.map(\.kind) == [.string, .integer, .choice(["metric", "imperial"]), .boolean, .json, .string, .number])
        #expect(form.fields.map(\.isRequired) == [true, false, false, false, true, false, false])
        #expect(form.fields[1].initialText == "3")
        #expect(form.fields[4].typeHint == "array of string")
    }

    @Test func buildsArguments() throws {
        let form = MCPArgumentForm(schema: schema)
        let arguments = try form.arguments(texts: ["city": "Paris", "days": "5", "tags": #"["a"]"#, "ratio": " "], flags: ["detailed": true])
        #expect(Value.object(arguments) == ["city": "Paris", "days": 5, "detailed": true, "tags": ["a"]])

        let repos = MCPArgumentForm(schema: try Value(json: #"{"properties": {"repo": {"anyOf": [{"type": "string"}, {"type": "array", "items": {"type": "string"}}]}}}"#))
        #expect(repos.fields[0].kind == .textOrJSON)
        #expect(try Value.object(repos.arguments(texts: ["repo": "a/b"], flags: [:])) == ["repo": "a/b"])
        #expect(try Value.object(repos.arguments(texts: ["repo": #"["a/b", "c/d"]"#], flags: [:])) == ["repo": ["a/b", "c/d"]])

        #expect(throws: MCPArgumentForm.Problem(field: "days", message: "must be a whole number")) {
            try form.arguments(texts: ["city": "Paris", "days": "2.5", "tags": "[]"], flags: [:])
        }
        #expect(throws: MCPArgumentForm.Problem(field: "tags", message: "is required")) {
            try form.arguments(texts: ["city": "Paris"], flags: [:])
        }

        let back = form.texts(from: arguments)
        #expect(back.texts == ["city": "Paris", "days": "5", "tags": #"["a"]"#])
        #expect(back.flags == ["detailed": true])
    }

    @Test func expandsResourceTemplates() {
        #expect(MCPURITemplate.variables(in: "repo://{owner}/{repo}/tree/{+path}{?ref}") == ["owner", "repo", "path", "ref"])
        #expect(MCPURITemplate.expand("repo://{owner}/{repo}/tree/{+path}{?ref}", with: ["owner": "sam al", "repo": "stampdrill", "path": "a/b.md", "ref": "main"])
            == "repo://sam%20al/stampdrill/tree/a/b.md?ref=main")
        #expect(MCPURITemplate.expand("demo://resource/{id}", with: [:]) == "demo://resource/")
    }
}
