import Testing
@testable import Stamp

struct DocumentParserTests {
    @Test func parsesAFileWithSeveralRequests() throws {
        let document = Document.parse("""
        # Chat API
        @base = http://localhost:8080/api
        let started = now()

        ### Start a chat
        POST {{base}}/conversations HTTP/1.1
        Authorization: Bearer {{token}}
        Content-Type: application/json

        {
          "title": "New Chat"
        }

        > assert status == 201, "chat was not created"
        > set chatId = body.id

        ### Leave
        @name leave
        @timeout 1500ms
        DELETE {{base}}/conversations/$chatId
        """)

        #expect(document.diagnostics.isEmpty)
        #expect(document.declarations.map(\.name) == ["base", "started"])
        #expect(document.requests.count == 2)

        let start = document.requests[0]
        #expect(start.title == "Start a chat")
        #expect(start.name == "startAChat")
        #expect(start.method == "POST")
        #expect(start.rawTarget == "{{base}}/conversations")
        #expect(start.httpVersion == "HTTP/1.1")
        #expect(start.headers.map(\.name) == ["Authorization", "Content-Type"])
        #expect(start.body?.rawText == "{\n  \"title\": \"New Chat\"\n}")
        #expect(start.body?.lines == 10...12)
        #expect(start.script.map(\.source) == ["assert status == 201, \"chat was not created\"", "set chatId = body.id"])
        #expect(start.lines == 5...15)

        let leave = document.requests[1]
        #expect(leave.name == "leave")
        #expect(leave.timeout == 1.5)
        #expect(leave.target.parts == [
            .expression(.identifier("base"), source: "base", column: 9),
            .text("/conversations/"),
            .variable("chatId"),
        ])
    }

    @Test func readsASingleRequestWithoutSeparator() {
        let document = Document.parse("""
        GET http://localhost:8080/api/conversations/$id/status
        Authorization: Bearer $token
        """, fileName: "Chat status.http")

        #expect(document.diagnostics.isEmpty)
        #expect(document.requests.first?.name == "chatStatus")
        #expect(document.requests.first?.body == nil)
    }

    @Test func treatsCommentedHeadersAsDisabled() {
        let document = Document.parse("""
        GET https://example.com
        Accept: application/json
        # X-Debug: 1
        // just a note
        """)
        let headers = document.requests[0].headers
        #expect(headers.map(\.name) == ["Accept", "X-Debug"])
        #expect(headers.map(\.isEnabled) == [true, false])
        #expect(document.lineKinds == [.requestLine, .header, .disabledHeader, .comment])
    }

    @Test func readsBodyFromFile() {
        let document = Document.parse("""
        POST https://example.com/upload
        Content-Type: application/json

        < ./fixtures/{{name}}.json
        """)
        guard case .file(let path, let raw)? = document.requests[0].body?.content else {
            Issue.record("expected a file body")
            return
        }
        #expect(raw == "./fixtures/{{name}}.json")
        #expect(path.parts.count == 3)
    }

    @Test func parsesDimensionsAndVariableSets() {
        let document = Document.parse("""
        dimension environment = local, qa, prod
        dimension region = eu, us

        vars {
          host = localhost(WEB)
          @greeting = Hello {{name}}
        }

        vars environment=qa|prod, region=* {
          host = "api." + environment + ".example.com"
        }
        """)

        #expect(document.diagnostics.isEmpty)
        #expect(document.dimensions.map(\.name) == ["environment", "region"])
        #expect(document.dimensions[0].values == ["local", "qa", "prod"])
        #expect(document.variableSets.count == 2)
        #expect(document.variableSets[0].conditions.isEmpty)
        #expect(document.variableSets[0].declarations.map(\.name) == ["host", "greeting"])
        #expect(document.variableSets[1].conditions == [.init(dimension: "environment", values: ["qa", "prod"])])
        #expect(document.variableSets[1].matches(["environment": "prod", "region": "us"]))
        #expect(!document.variableSets[1].matches(["environment": "local"]))
        #expect(document.variableSets[1].lines == 9...11)
    }

    @Test func keepsGoingAfterErrors() {
        let document = Document.parse("""
        let broken = (1 +
        GET https://example.com
        not a header

        > explode
        ### Fine
        GET https://example.com/ok
        """)

        #expect(document.requests.map(\.rawTarget) == ["https://example.com", "https://example.com/ok"])
        #expect(document.diagnostics.map(\.message) == [
            "expected a value, found end of line",
            "expected a header 'Name: value' or an empty line before the body",
            "expected 'assert', 'set', 'save', 'let', 'print', a function call, or for WebSockets and MCP 'send', 'receive', 'wait', 'close'",
        ])
        #expect(document.diagnostics.map(\.range.start.line) == [1, 3, 5])
    }

    @Test func warnsAboutUnknownDirectivesAndDuplicateNames() {
        let document = Document.parse("""
        ### Login
        @retry 3
        GET https://example.com/a
        ### Login
        GET https://example.com/b
        """)
        #expect(document.diagnostics.map(\.severity) == [.warning, .warning])
        #expect(document.diagnostics.last?.message.contains("'login'") == true)
    }

    @Test func rejectsScriptsOutsideRequests() {
        let document = Document.parse("> print 1")
        #expect(document.diagnostics.first?.message == "a response script must follow a request")
    }

    @Test func findsRequestByLine() {
        let document = Document.parse("""
        @a = 1
        ### One
        GET https://example.com/1

        ### Two
        GET https://example.com/2
        """)
        #expect(document.request(atLine: 1) == nil)
        #expect(document.request(atLine: 3)?.name == "one")
        #expect(document.request(atLine: 6)?.name == "two")
    }

    @Test func derivesIdentifiers() {
        #expect("Start a chat".stampIdentifier == "startAChat")
        #expect("Rojîn's inbox".stampIdentifier == "rojinSInbox")
        #expect("2FA verify".stampIdentifier == "_2faVerify")
        #expect("--".stampIdentifier == nil)
    }
}

struct AuthDirectiveTests {
    @Test func parsesSchemes() throws {
        let document = Document.parse("""
        @auth bearer {{ token ?? "anonymous" }}

        ### Basic
        @auth basic {{user}} "pass word"
        GET https://example.com/a

        ### Key
        @auth apikey api_key {{key}} query
        GET https://example.com/b

        ### Public
        @auth none
        GET https://example.com/c

        ### Inherits
        GET https://example.com/d
        """)

        #expect(document.diagnostics.isEmpty)
        #expect(document.auth == .bearer(try Template.parse(#"{{ token ?? "anonymous" }}"#, line: 1, column: 13)))
        guard case .basic(_, let password)? = document.requests[0].auth else {
            Issue.record("expected basic auth")
            return
        }
        #expect(password == Template(text: "pass word"))
        #expect(document.requests[1].auth?.kindName == "apikey")
        #expect(document.auth(for: document.requests[2]) == AuthScheme.none)
        #expect(document.auth(for: document.requests[3])?.kindName == "bearer")
    }

    @Test func reportsBadAuth() {
        let document = Document.parse("""
        @auth basic onlyuser
        @auth digest x
        @auth apikey name value cookie
        """)
        #expect(document.diagnostics.map(\.message) == [
            "expected '@auth basic <username> <password>'",
            "unknown auth scheme 'digest'",
            "an API key goes in the 'header' or the 'query'",
        ])
    }
}
