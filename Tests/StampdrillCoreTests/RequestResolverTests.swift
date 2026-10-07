import Foundation
import Testing
@testable import StampdrillCore
import Stamp

struct RequestResolverTests {
    private let workspace = makeWorkspace([
        "environment.stamp": """
        dimension environment = local, prod

        vars {
          token = secret("dev-token")
        }

        vars environment=local {
          host = localhost(TOMCAT)
        }

        vars environment=prod {
          host = "api.example.com"
        }
        """,
        "Chat/chat.stamp": """
        @base = {{host}}/api

        ### Start a chat
        @timeout 5s
        @no-redirect
        @title = New Chat
        POST {{base}}/conversations/$id
        Authorization: {{bearer(token)}}
        # X-Debug: 1

        { "title": "{{title}}", "at": {{ id * 2 }} }
        """,
    ])

    private func resolve(_ input: ResolutionInput) throws -> ResolvedRequest {
        let file = try #require(workspace.file(at: "Chat/chat.stamp"))
        let request = try #require(file.document.requests.first)
        let context = RequestResolver.scope(for: request, in: file, workspace: workspace, input: input)
        return try RequestResolver.resolve(request, in: file, scope: context)
    }

    @Test func fillsInEverything() throws {
        let request = try resolve(ResolutionInput(selection: ["environment": "local"], session: ["id": 21]))

        #expect(request.name == "startAChat")
        #expect(request.url.absoluteString == "http://localhost:8080/api/conversations/21")
        #expect(request.headers == [
            HTTPField("Authorization", "Bearer dev-token"),
            HTTPField("Content-Type", "application/json"),
        ])
        #expect(request.bodyText == #"{ "title": "New Chat", "at": 42 }"#)
        #expect(request.timeout == 5)
        #expect(request.followsRedirects == false)
        #expect(request.secrets == ["dev-token"])
        #expect(request.masked("Bearer dev-token") == "Bearer ••••••")
    }

    @Test func switchesEnvironments() throws {
        let request = try resolve(ResolutionInput(selection: ["environment": "prod"], session: ["id": 1]))
        #expect(request.url.absoluteString == "http://api.example.com/api/conversations/1")
    }

    @Test func overridesWinOverEverything() throws {
        let request = try resolve(ResolutionInput(session: ["id": 1], overrides: ["host": "https://staging.example.com"]))
        #expect(request.url.absoluteString == "https://staging.example.com/api/conversations/1")
    }

    @Test func leavesUnknownDollarNamesAlone() throws {
        let workspace = makeWorkspace(["a.stamp": "GET https://example.com/$id/items?price=$top"])
        let file = workspace.files[0]
        let request = try #require(file.document.requests.first)
        let context = RequestResolver.scope(for: request, in: file, workspace: workspace, input: ResolutionInput(session: ["id": 7]))
        let resolved = try RequestResolver.resolve(request, in: file, scope: context)
        #expect(resolved.url.absoluteString == "https://example.com/7/items?price=$top")
    }

    @Test func reportsTheLineOfAFailingValue() {
        #expect(throws: ResolutionError("unknown variable 'id'", line: 11)) {
            _ = try resolve(ResolutionInput())
        }
    }

    @Test func rejectsUnsupportedSchemes() {
        #expect(throws: ResolutionError("unsupported scheme 'ftp'", line: 1)) {
            try RequestResolver.makeURL("ftp://example.com", line: 1)
        }
    }
}

struct AuthResolutionTests {
    private func resolve(_ text: String, session: [String: Value] = [:]) throws -> ResolvedRequest {
        let workspace = makeWorkspace(["a.stamp": text])
        let file = workspace.files[0]
        let request = try #require(file.document.requests.first)
        let context = RequestResolver.scope(for: request, in: file, workspace: workspace, input: ResolutionInput(session: session))
        return try RequestResolver.resolve(request, in: file, scope: context)
    }

    @Test func appliesFileWideBearer() throws {
        let request = try resolve("""
        @auth bearer {{token}}
        GET https://example.com
        """, session: ["token": "abc"])
        #expect(request.header("Authorization") == "Bearer abc")
    }

    @Test func explicitHeaderWins() throws {
        let request = try resolve("""
        @auth basic user pass
        GET https://example.com
        Authorization: Custom 1
        """)
        #expect(request.headers == [HTTPField("Authorization", "Custom 1")])
    }

    @Test func encodesBasicCredentials() throws {
        let request = try resolve("""
        @auth basic aladdin opensesame
        GET https://example.com
        """)
        #expect(request.header("Authorization") == "Basic YWxhZGRpbjpvcGVuc2VzYW1l")
    }

    @Test func addsApiKeyToQuery() throws {
        let request = try resolve("""
        @auth apikey api_key {{ "s3cr3t" }} query
        GET https://example.com/items?page=2
        """)
        #expect(request.url.absoluteString == "https://example.com/items?page=2&api_key=s3cr3t")
    }
}

struct BodyEncodingTests {
    @Test func buildsGraphQLPayloads() throws {
        let workspace = makeWorkspace(["q.stamp": """
        @code = IQ
        GRAPHQL https://countries.example/graphql

        query Country($code: ID!) {
          country(code: $code) { name }
        }

        { "code": "{{code}}" }
        """])
        let file = workspace.files[0]
        let request = try #require(file.document.requests.first)
        let resolved = try RequestResolver.resolve(request, in: file, scope: RequestResolver.scope(for: request, in: file, workspace: workspace, input: ResolutionInput()))
        #expect(resolved.method == "POST")
        #expect(resolved.header("Content-Type") == "application/json")
        let payload = try Value(json: try #require(resolved.body))
        #expect(payload == [
            "query": "query Country($code: ID!) {\n  country(code: $code) { name }\n}",
            "variables": ["code": "IQ"],
            "operationName": "Country",
        ])
    }

    @Test func encodesForms() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "hello".write(to: directory.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let fields = try #require(BodyEncoding.formFields("name = Rojîn Maroufi\n# comment\nnote = < ./note.txt", relativeTo: directory))
        #expect(fields.map(\.name) == ["name", "note"])
        #expect(String(decoding: BodyEncoding.urlEncoded([fields[0]]), as: UTF8.self) == "name=Roj%C3%AEn%20Maroufi")

        let multipart = String(decoding: try BodyEncoding.multipart(fields, boundary: "b", line: 1), as: UTF8.self)
        #expect(multipart == "--b\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nRojîn Maroufi\r\n--b\r\nContent-Disposition: form-data; name=\"note\"; filename=\"note.txt\"\r\nContent-Type: text/plain\r\n\r\nhello\r\n--b--\r\n")
        #expect(BodyEncoding.formFields("{ \"not\": \"a form\" }", relativeTo: directory) == nil)
    }
}
