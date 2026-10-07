import Foundation
import Testing
@testable import StampdrillCore
@testable import Stamp

/// Cases found by reviewing the importers: each one sent the wrong request,
/// lost data, or wrote a file that doesn't parse.
private struct Sandbox {
    let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("import-fixes-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ name: String, _ text: String) -> URL {
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
        return url
    }

    var url: URL { directory }

    /// Parses every generated file and fails on a parse error.
    func parsed(_ output: Importer.Output) -> [String: Document] {
        var documents: [String: Document] = [:]
        for (path, text) in output.files {
            let document = Document.parse(text, fileName: (path as NSString).lastPathComponent)
            let errors = document.diagnostics.filter { $0.severity == .error }
            #expect(errors.isEmpty, "\(path): \(errors.map(\.message))\n\(text)")
            documents[path] = document
        }
        return documents
    }
}

struct CurlImportFixTests {
    @Test func keepsABodyThatSpansSeveralLines() throws {
        let command = """
        curl --location 'https://api.example.com/users' \\
        --header 'Content-Type: application/json' \\
        --data-raw '{
            "name": "Ada",
            "role": "admin"
        }'
        """
        let result = try Importer.requests(fromCurl: command)
        #expect(result.text.contains("""
        {
            "name": "Ada",
            "role": "admin"
        }
        """))
    }

    @Test func readsCombinedFlagsAndUnknownOptions() throws {
        let both = try Importer.requests(fromCurl: "curl -sX POST https://api.example.com/v1/jobs\ncurl --unix-socket /var/run/d.sock https://api.example.com/info")
        #expect(both.text.contains("POST https://api.example.com/v1/jobs"))
        #expect(both.text.contains("GET https://api.example.com/info"))
    }

    @Test func decodesBrowserEscapes() throws {
        // Firefox and Safari write non-ASCII characters as \xHH, and Safari escapes URL brackets.
        let command = #"curl 'https://api.example.com/items?filter\[status\]=new' --data-binary $'{"city":"M\xfcnchen","tab":"a\tb"}' -H 'content-type: application/json'"#
        let result = try Importer.requests(fromCurl: command)
        #expect(result.text.contains("https://api.example.com/items?filter[status]=new"))
        #expect(result.text.contains("{\"city\":\"München\",\"tab\":\"a\tb\"}"))
    }

    @Test func turnsARawMultipartBodyIntoFields() throws {
        let body = "------WebKitFormBoundaryABC\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nHello\r\n------WebKitFormBoundaryABC\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"me.png\"\r\nContent-Type: image/png\r\n\r\nPNGDATA\r\n------WebKitFormBoundaryABC--\r\n"
        let command = "curl 'https://example.com/upload' -H $'content-type: multipart/form-data; boundary=----WebKitFormBoundaryABC' --data-raw $'\(body.replacingOccurrences(of: "\r\n", with: "\\r\\n"))'"
        let result = try Importer.requests(fromCurl: command)
        #expect(result.text.contains("Content-Type: multipart/form-data\n\ntitle = Hello\nphoto = < ./me.png"))
    }

    @Test func keepsBracesLiteralEverywhere() throws {
        let result = try Importer.requests(fromCurl: "curl -u 'user:{{pass}}' https://example.com/x --data-urlencode 'client_id={{clientId}}'")
        #expect(result.text.contains(#"client_id = \{{clientId}}"#))
        #expect(result.text.contains(#"\{{pass}}"#))
        #expect(Document.parse(result.text).diagnostics.isEmpty)
    }
}

struct HARImportFixTests {
    @Test func readsFormBodiesTheWayEachBrowserWritesThem() throws {
        let sandbox = Sandbox()
        let har = #"""
        { "log": { "entries": [
          { "_resourceType": "xhr", "request": { "method": "POST", "url": "https://api.example.com/search",
              "headers": [{ "name": "content-type", "value": "application/x-www-form-urlencoded" }],
              "postData": { "mimeType": "application/x-www-form-urlencoded", "text": "q=hello+world&note=50%25+off",
                            "params": [{ "name": "q", "value": "hello+world" }] } },
            "response": { "status": 200 } }
        ] } }
        """#
        let output = try Importer.convert([sandbox.file("session.har", har)])
        let text = output.files[0].text
        #expect(text.contains("q = hello world"))
        #expect(text.contains("note = 50% off"))
        _ = sandbox.parsed(output)
    }

    @Test func readsABareRequestWithItsQueryAndCookies() throws {
        let sandbox = Sandbox()
        let request = #"""
        { "method": "GET", "httpVersion": "HTTP/1.1", "url": "https://api.example.com/items",
          "headers": [{ "name": "accept", "value": "application/json" }],
          "queryString": [{ "name": "page", "value": "2" }],
          "cookies": [{ "name": "session", "value": "abc" }] }
        """#
        let output = try Importer.convert([sandbox.file("one.json", request)])
        let text = output.files[0].text
        #expect(text.contains("?page=2"))
        #expect(text.contains("Cookie: {{cookie}}"))
        #expect(output.environment.local.contains { $0.source == #"secret("session=abc")"# })
    }
}

struct BrunoImportFixTests {
    /// A collection that uses the things Bruno's own docs recommend.
    private func collection(_ sandbox: Sandbox) -> URL {
        sandbox.file("bruno/bruno.json", #"{ "version": "1", "name": "Shop", "type": "collection" }"#)
        sandbox.file("bruno/collection.bru", """
        auth {
          mode: bearer
        }

        auth:bearer {
          token: {{process.env.API_TOKEN}}
        }

        headers {
          X-Api-Version: 2
        }
        """)
        sandbox.file("bruno/Users/folder.bru", """
        meta {
          name: Users
        }

        vars:pre-request {
          resource: users
        }
        """)
        sandbox.file("bruno/Users/List.bru", """
        meta {
          name: List
          seq: 1
        }

        get {
          url: {{baseUrl}}/{{resource}}
          body: none
          auth: inherit
        }

        headers {
          ~X-Api-Version: 3
        }

        assert {
          res.body.id: eq {{expectedId}}
          res.status: eq 200
        }
        """)
        sandbox.file("bruno/Orders/folder.bru", """
        meta {
          name: Orders
        }

        vars:pre-request {
          resource: orders
        }
        """)
        sandbox.file("bruno/Orders/Upload.bru", """
        meta {
          name: Upload
          seq: 1
        }

        post {
          url: {{baseUrl}}/{{resource}}
          body: multipartForm
          auth: inherit
        }

        body:multipart-form {
          photo: @file(files/photo.png) @contentType(image/png)
          note: text value
        }
        """)
        sandbox.file("bruno/Orders/Replace.bru", """
        meta {
          name: Replace
          seq: 2
        }

        put {
          url: {{baseUrl}}/blob
          body: file
          auth: none
        }

        body:file {
          file: @file(files/photo.png) @contentType(image/png)
        }
        """)
        sandbox.file("bruno/environments/Local.bru", """
        vars {
          baseUrl: http://localhost:4000
          expectedId: 7
          certificate: '''
            -----BEGIN CERTIFICATE-----
            MIIB: not a variable
            -----END CERTIFICATE-----
          '''
        }
        """)
        return sandbox.url.appendingPathComponent("bruno")
    }

    @Test func importsWhatBrunoRecommends() throws {
        let sandbox = Sandbox()
        let output = try Importer.convert([collection(sandbox)])
        let files = sandbox.parsed(output)
        let users = try #require(output.files.first { $0.path == "Users.stamp" }?.text)
        let orders = try #require(output.files.first { $0.path == "Orders.stamp" }?.text)

        // An environment token stays an expression the auth directive can parse.
        #expect(users.contains(#"@auth bearer {{getenv("API_TOKEN")}}"#))
        // Each folder keeps its own variable.
        #expect(users.contains("@resource = users"))
        #expect(orders.contains("@resource = orders"))
        // A disabled header doesn't remove the one the collection sets.
        #expect(users.contains("X-Api-Version: 2"))
        #expect(users.contains("# X-Api-Version: 3"))
        // An assertion against a variable compares values, not text.
        #expect(users.contains("> assert body.id == expectedId"))
        // Uploads and file bodies survive, with their paths resolved.
        #expect(orders.contains("photo = < \(sandbox.url.path)/bruno/files/photo.png"))
        #expect(orders.contains("note = text value"))
        #expect(orders.contains("Content-Type: image/png"))
        #expect(orders.contains("< \(sandbox.url.path)/bruno/files/photo.png"))

        // A multi-line environment value keeps its lines and invents no variables.
        let certificate = try #require(output.environment.shared.first { $0.name == "certificate" })
        #expect(certificate.source.contains("BEGIN CERTIFICATE"))
        #expect(certificate.source.contains("\\n"))
        #expect(!output.environment.shared.contains { $0.name == "MIIB" })
        #expect(files["Users.stamp"]?.requests.count == 1)
    }

    @Test func doesNotInheritAuthWhereBrunoSendsNone() throws {
        let sandbox = Sandbox()
        let yaml = """
        opencollection: "1.0.0"
        info:
          name: Public
        request:
          auth:
            type: bearer
            token: "{{token}}"
        items:
          - info:
              name: Open
              type: http
            http:
              method: GET
              url: https://example.com/public
          - info:
              name: Private
              type: http
            http:
              method: GET
              url: https://example.com/private
              auth: inherit
        """
        let output = try Importer.convert([sandbox.file("public.yml", yaml)])
        let text = output.files[0].text
        #expect(text.contains("### Open\nGET https://example.com/public"))
        #expect(text.contains("### Private\n@auth bearer {{token}}\nGET https://example.com/private"))
    }
}

struct ImportSafetyFixTests {
    @Test func neverTakesOverAVariableTheWorkspaceUses() throws {
        let sandbox = Sandbox()
        let first = try Importer.requests(fromCurl: "curl https://a.example.com/me -H 'Authorization: Bearer token-for-a'")
        #expect(first.environment.local.map(\.name) == ["authorization"])

        // A second import into the same workspace must not reuse the first one's variable.
        let existing = first.environment.apply(to: "", local: true).text
        let second = try Importer.requests(
            fromCurl: "curl https://b.example.com/me -H 'Authorization: Bearer token-for-b'",
            existingNames: ImportedEnvironmentChanges.declaredNames(in: [existing])
        )
        #expect(second.environment.local.map(\.name) == ["authorization2"])
        #expect(second.text.contains("Authorization: {{authorization2}}"))
        let merged = second.environment.apply(to: existing, local: true).text
        #expect(merged.contains(#"authorization = secret("Bearer token-for-a")"#))
        #expect(merged.contains(#"authorization2 = secret("Bearer token-for-b")"#))
        _ = sandbox
    }

    @Test func keepsTwoCollectionsApart() throws {
        let sandbox = Sandbox()
        func collection(_ name: String, _ host: String) -> String {
            """
            { "info": { "_postman_id": "\(name)", "name": "\(name)", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json" },
              "variable": [{ "key": "baseUrl", "value": "\(host)" }],
              "item": [{ "name": "Ping", "request": { "method": "GET", "url": "{{baseUrl}}/ping" } }] }
            """
        }
        let output = try Importer.convert([
            sandbox.file("shop.json", collection("Shop", "https://shop.example.com")),
            sandbox.file("billing.json", collection("Billing", "https://billing.example.com")),
        ])
        let billing = try #require(output.files.first { $0.path == "Billing.stamp" }?.text)
        #expect(billing.contains("GET {{baseUrl2}}/ping"))
        #expect(output.environment.shared.contains { $0.name == "baseUrl2" && $0.source == #""https://billing.example.com""# })
        #expect(output.warnings.contains { $0.contains("baseUrl") })
    }

    @Test func movesLiteralCredentialsOutOfRequestFiles() throws {
        let result = try Importer.requests(
            fromCurl: "curl 'https://api.example.com/token?access_token=abc123' -d 'username=ada&password=hunter2&client_secret=s3cr3t'"
        )
        #expect(result.text.contains("username = ada"))
        #expect(result.text.contains("password = {{password}}"))
        #expect(result.text.contains("client_secret = {{client_secret}}"))
        #expect(result.text.contains("?access_token={{access_token}}"))
        #expect(result.environment.local.map(\.source).sorted() == [#"secret("abc123")"#, #"secret("hunter2")"#, #"secret("s3cr3t")"#])
    }

    @Test func writesBodiesAndDescriptionsThatStayInTheirRequest() throws {
        let sandbox = Sandbox()
        let collection = #"""
        { "info": { "_postman_id": "1", "name": "Edge", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json" },
          "item": [
            { "name": "Notes", "request": { "method": "POST", "url": "https://example.com/notes",
              "description": "First line\r\nGET second line\r\nthird",
              "body": { "mode": "raw", "raw": "intro\n### Heading\n> quoted\nend" } } },
            { "name": "Address", "request": { "method": "POST", "url": "https://example.com/address",
              "body": { "mode": "urlencoded", "urlencoded": [{ "key": "note", "value": "line1\nline2" }] } } }
          ] }
        """#
        let output = try Importer.convert([sandbox.file("edge.postman_collection.json", collection)])
        let documents = sandbox.parsed(output)
        let requests = try #require(documents["Requests.stamp"]).requests
        #expect(requests.count == 2)
        let text = output.files[0].text
        #expect(text.contains("# First line\n# GET second line\n# third"))
        #expect(text.contains("{{\"###\"}} Heading"))
        #expect(text.contains(" > quoted"))
        #expect(text.contains("note = {{\"line1\\nline2\"}}"))
    }

    @Test func recognisesFilesByWhatTheyAre() throws {
        let sandbox = Sandbox()
        let openAPI = """
        openapi: 3.0.0
        info:
          title: Pets
        paths:
          /pets:
            get:
              summary: List pets
              description: |
                Try it:
                curl https://api.pets.example.com/v1/pets -H "Authorization: Bearer $TOKEN"
              responses:
                '200':
                  description: ok
        """
        #expect(try Importer.detect(sandbox.file("pets.yaml", openAPI)) == .openAPI)

        // A byte-order mark, as some Windows tools write.
        let har = "\u{FEFF}{ \"log\": { \"entries\": [] } }"
        #expect(try Importer.detect(sandbox.file("bom.har", har)) == .har)
    }
}

struct PostmanImportFixTests {
    @Test func keepsEveryValueOfASecretInOnePlace() throws {
        let sandbox = Sandbox()
        let collection = #"""
        { "info": { "_postman_id": "1", "name": "Tokens", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json" },
          "variable": [{ "key": "token", "value": "dev-token-literal" }],
          "item": [{ "name": "Me", "request": { "method": "GET", "url": "https://api.example.com/me" } }] }
        """#
        let production = #"""
        { "name": "Production", "values": [{ "key": "token", "value": "prod-token", "enabled": true }], "_postman_variable_scope": "environment" }
        """#
        let output = try Importer.convert([
            sandbox.file("tokens.postman_collection.json", collection),
            sandbox.file("production.json", production),
        ])
        // The local file outranks the shared one, so both values live there.
        #expect(output.environment.shared.isEmpty)
        #expect(output.environment.local.map(\.source) == [#"secret("dev-token-literal")"#, #"secret("prod-token")"#])
        #expect(output.environment.local[1].conditions.first?.values == ["production"])
    }

    @Test func readsFormBodiesAndTokenPlacement() throws {
        let sandbox = Sandbox()
        let collection = #"""
        { "info": { "_postman_id": "1", "name": "Auth", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json" },
          "item": [
            { "name": "Token", "request": { "method": "POST", "url": "https://api.example.com/token",
              "header": [{ "key": "Content-Type", "value": "application/x-www-form-urlencoded" }],
              "body": { "mode": "raw", "raw": "grant_type=password&username=bob&scope=read+write" } } },
            { "name": "Query token", "request": { "method": "GET", "url": "https://api.example.com/me",
              "auth": { "type": "oauth2", "oauth2": [{ "key": "accessToken", "value": "tok123" }, { "key": "addTokenTo", "value": "queryParams" }] } } },
            { "name": "Ok test", "event": [{ "listen": "test", "script": { "exec": ["pm.response.to.be.ok;"] } }],
              "request": { "method": "GET", "url": "https://api.example.com/ping" } }
          ] }
        """#
        let output = try Importer.convert([sandbox.file("auth.postman_collection.json", collection)])
        let text = output.files[0].text
        #expect(text.contains("grant_type = password\nusername = bob\nscope = read write"))
        #expect(text.contains("@auth apikey access_token {{access_token}} query"))
        #expect(text.contains("> assert status == 200"))
        _ = sandbox.parsed(output)
    }

    @Test func doesNotLetAFolderTakeTheEnvironmentFileName() throws {
        let sandbox = Sandbox()
        let collection = #"""
        { "info": { "_postman_id": "1", "name": "Ops", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json" },
          "item": [{ "name": "Environment", "item": [{ "name": "Ping", "request": { "method": "GET", "url": "https://example.com/ping" } }] }] }
        """#
        let output = try Importer.convert([sandbox.file("ops.json", collection)])
        #expect(output.files.map(\.path) == ["Environment 2.stamp"])
    }
}

struct InsomniaImportFixTests {
    @Test func encodesParametersAndFollowsFolderDependencies() throws {
        let sandbox = Sandbox()
        let export = #"""
        {
          "_type": "export", "__export_format": 4,
          "resources": [
            { "_id": "wrk_1", "_type": "workspace", "name": "Mail" },
            { "_id": "req_login", "_type": "request", "parentId": "wrk_1", "name": "Log in", "method": "POST", "url": "https://api.example.com/session", "metaSortKey": 1 },
            { "_id": "fld_1", "_type": "request_group", "parentId": "wrk_1", "name": "Messages", "preRequestScript": "console.log(1)",
              "authentication": { "type": "bearer", "token": "{% response 'body', 'req_login', 'b64::JC50b2tlbg==::46b', 'never', 60 %}" } },
            { "_id": "req_2", "_type": "request", "parentId": "fld_1", "name": "Search", "method": "GET", "url": "https://api.example.com/search",
              "parameters": [{ "name": "q", "value": "rock & roll" }, { "name": "to", "value": "ana+test@example.com" }] },
            { "_id": "req_3", "_type": "request", "parentId": "fld_1", "name": "Odd filter", "method": "GET", "url": "https://api.example.com/odd",
              "headers": [{ "name": "X-Host", "value": "{% response 'body', 'req_login', '$..Host', 'never', 60 %}" }] }
          ]
        }
        """#
        let output = try Importer.convert([sandbox.file("mail.json", export)])
        let messages = try #require(output.files.first { $0.path == "Messages.stamp" }?.text)
        #expect(messages.contains("?q=rock%20%26%20roll&to=ana%2Btest%40example.com"))
        // The folder's token comes from another request, so every request below needs it.
        #expect(messages.contains("### Search\n@needs logIn\n@auth bearer {{logIn.body.token}}"))
        // A filter with no equivalent is left as text, not turned into the whole body.
        #expect(messages.contains("X-Host: {%response 'body', 'req_login', '$..Host', 'never', 60%}"))
        #expect(output.warnings.contains { $0.contains("scripts on the folder 'Messages'") })
        #expect(output.warnings.contains { $0.contains("has no equivalent") })
        _ = sandbox.parsed(output)
    }
}

@Suite("Curl separators")
struct CurlSeparatorTests {
    @Test func backgroundedCommandIsNotLost() throws {
        let text = "curl https://a.example/one & curl https://b.example/two"
        let output = try Importer.requests(fromCurl: text)
        #expect(output.text.contains("https://a.example/one"))
        #expect(output.text.contains("https://b.example/two"))
        #expect(output.names.count == 2)
    }

    @Test func everySeparatorSplits() throws {
        let text = "curl https://a.example/1; curl https://b.example/2 && curl https://c.example/3 | jq . ; curl https://d.example/4"
        let output = try Importer.requests(fromCurl: text)
        #expect(output.names.count == 4)
    }
}
