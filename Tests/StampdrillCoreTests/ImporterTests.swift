import Foundation
import Testing
@testable import StampdrillCore
@testable import Stamp

/// Writes fixtures to a temporary folder and imports them.
private struct Fixture {
    let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("importer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func file(_ name: String, _ text: String) -> URL {
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
        return url
    }

    /// The files an import wrote, as a workspace with its environment, checked for errors.
    func workspace(_ output: Importer.Output) throws -> Workspace {
        let root = directory.appendingPathComponent("workspace-\(UUID().uuidString)")
        for (path, text) in output.files { _ = writeFile(root.appendingPathComponent(path), text) }
        let shared = output.environment.apply(to: "", local: false).text
        let local = output.environment.apply(to: "", local: true).text
        _ = writeFile(root.appendingPathComponent("environment.stamp"), shared)
        if !local.isEmpty { _ = writeFile(root.appendingPathComponent("environment.local.stamp"), local) }
        let workspace = try Workspace.load(from: root)
        for file in workspace.files {
            let errors = file.document.diagnostics.filter { $0.severity == .error }
            #expect(errors.isEmpty, "\(file.relativePath): \(errors.map(\.message)) in\n\(file.text)")
        }
        return workspace
    }

    private func writeFile(_ url: URL, _ text: String) -> URL {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
        return url
    }
}

struct PostmanImportTests {
    private let collection = #"""
    {
      "info": { "_postman_id": "1", "name": "Shop API", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json" },
      "auth": { "type": "bearer", "bearer": [{ "key": "token", "value": "{{access-token}}", "type": "string" }] },
      "variable": [{ "key": "base_url", "value": "https://shop.example.com" }],
      "item": [
        {
          "name": "Log in",
          "event": [{ "listen": "test", "script": { "exec": [
            "pm.test(\"Status code is 200\", function () {",
            "    pm.response.to.have.status(200);",
            "});",
            "var jsonData = pm.response.json();",
            "pm.environment.set(\"access-token\", jsonData.data.token);",
            "console.log('logged in');"
          ] } }],
          "request": {
            "auth": { "type": "noauth" },
            "method": "POST",
            "header": [{ "key": "Content-Type", "value": "application/json" }, { "key": "X-Debug", "value": "1", "disabled": true }],
            "body": { "mode": "raw", "raw": "{\n  \"email\": \"{{$randomEmail}}\",\n  \"id\": \"{{$guid}}\"\n}", "options": { "raw": { "language": "json" } } },
            "url": { "raw": "{{base_url}}/login", "host": ["{{base_url}}"], "path": ["login"] }
          }
        },
        {
          "name": "Orders",
          "item": [
            {
              "name": "Get order",
              "request": {
                "method": "GET",
                "url": { "raw": "{{base_url}}/orders/:orderId?expand=items", "variable": [{ "key": "orderId", "value": "42" }] }
              }
            },
            {
              "name": "Upload receipt",
              "request": {
                "method": "POST",
                "auth": { "type": "apikey", "apikey": [{ "key": "key", "value": "X-Api-Key" }, { "key": "value", "value": "sk_live_123" }, { "key": "in", "value": "header" }] },
                "body": { "mode": "formdata", "formdata": [{ "key": "note", "value": "paid", "type": "text" }, { "key": "file", "type": "file", "src": "/tmp/receipt.pdf" }] },
                "url": "{{base_url}}/receipts"
              }
            }
          ]
        }
      ]
    }
    """#

    private let environment = #"""
    { "name": "Staging EU", "values": [
      { "key": "base_url", "value": "https://staging.shop.example.com", "enabled": true },
      { "key": "access-token", "value": "abc", "type": "secret", "enabled": true }
    ], "_postman_variable_scope": "environment" }
    """#

    @Test func importsACollectionWithItsEnvironment() throws {
        let fixture = Fixture()
        let output = try Importer.convert([fixture.file("shop.postman_collection.json", collection), fixture.file("staging.json", environment)])
        #expect(output.title == "Shop API")
        #expect(output.requestCount == 3)
        #expect(output.files.map(\.path) == ["Requests.stamp", "Orders.stamp"])

        let login = output.files[0].text
        #expect(login.contains("### Log in\n# Postman test script lines that weren't converted:\n#   console.log('logged in');\nPOST {{base_url}}/login\nContent-Type: application/json\n# X-Debug: 1\n"))
        #expect(login.contains(#""email": "{{fake.email}}""#))
        #expect(login.contains(#""id": "{{uuid()}}""#))
        #expect(login.contains("> assert status == 200\n> set accessToken = body.data.token"))
        #expect(!login.contains("@auth"))

        let orders = output.files[1].text
        #expect(orders.contains("### Get order\n@orderId = 42\n@auth bearer {{accessToken}}\nGET {{base_url}}/orders/{{orderId}}?expand=items"))
        #expect(orders.contains("@auth apikey X-Api-Key {{xApiKey}} header"))
        #expect(orders.contains("Content-Type: multipart/form-data\n\nnote = paid\nfile = < /tmp/receipt.pdf"))

        #expect(output.environment.dimension?.name == "environment")
        #expect(output.environment.dimension?.values == ["staging-eu"])
        #expect(output.environment.shared.map(\.name) == ["base_url", "base_url"])
        #expect(output.environment.local.map(\.source).contains(#"secret("sk_live_123")"#))
        #expect(output.environment.local.contains { $0.name == "accessToken" && $0.source == #"secret("abc")"# })

        let workspace = try fixture.workspace(output)
        #expect(workspace.requestFiles.flatMap(\.document.requests).count == 3)
        let shared = try #require(workspace.environmentFile).text
        #expect(shared.contains("dimension environment = staging-eu"))
        #expect(shared.contains(#"base_url = "https://staging.shop.example.com""#))
    }
}

struct CurlImportTests {
    @Test func readsBrowserCopies() throws {
        let command = #"""
        curl 'https://api.example.com/v1/items?page=2' \
          -H 'accept: application/json' \
          -H 'authorization: Bearer eyJhbGciOiJIUzI1NiJ9.e30.abc' \
          -H $'x-note: it\'s fine' \
          --data-raw '{"name":"Lamp","tags":["a"]}' \
          --compressed -k
        """#
        let result = try Importer.requests(fromCurl: command)
        #expect(result.names == ["postV1Items"])
        #expect(result.text == """
        ### POST /v1/items
        @insecure
        POST https://api.example.com/v1/items?page=2
        accept: application/json
        authorization: {{authorization}}
        x-note: it's fine
        Content-Type: application/json

        {"name":"Lamp","tags":["a"]}
        """)
        #expect(result.environment.local == [.init(conditions: [], name: "authorization", source: #"secret("Bearer eyJhbGciOiJIUzI1NiJ9.e30.abc")"#)])
    }

    @Test func readsFormsUsersAndSeveralCommands() throws {
        let text = """
        $ curl -X PUT https://example.com/profile -u ada:lovelace -d name=Ada%20L -d city=London
        curl -F 'avatar=@me.png;type=image/png' -F title=Me https://example.com/upload
        curl -G https://example.com/search --data-urlencode 'q=two words'
        """
        let result = try Importer.requests(fromCurl: text)
        #expect(result.names == ["putProfile", "postUpload", "getSearch"])
        #expect(result.text.contains("@auth basic ada {{password}}\nPUT https://example.com/profile\nContent-Type: application/x-www-form-urlencoded\n\nname = Ada L\ncity = London"))
        #expect(result.text.contains("POST https://example.com/upload\nContent-Type: multipart/form-data\n\navatar = < me.png\ntitle = Me"))
        #expect(result.text.contains("GET https://example.com/search?q=two%20words"))
        #expect(Importer.looksLikeCurl("curl https://example.com"))
        #expect(!Importer.looksLikeCurl("GET https://example.com"))
    }

    @Test func keepsBracesLiteral() throws {
        let result = try Importer.requests(fromCurl: #"curl https://example.com -d '{"template":"{{name}}"}'"#)
        #expect(result.text.contains(#"{"template":"\{{name}}"}"#))
        let document = Document.parse(result.text)
        #expect(document.diagnostics.isEmpty)
    }
}

struct InsomniaImportTests {
    @Test func importsFormat4() throws {
        let export = #"""
        {
          "_type": "export", "__export_format": 4,
          "resources": [
            { "_id": "wrk_1", "_type": "workspace", "name": "Weather" },
            { "_id": "fld_1", "_type": "request_group", "parentId": "wrk_1", "name": "Forecasts",
              "authentication": { "type": "bearer", "token": "{{ _.token }}" } },
            { "_id": "req_login", "_type": "request", "parentId": "wrk_1", "name": "Sign in", "method": "POST",
              "url": "{{ _.base_url }}/session", "metaSortKey": 1,
              "body": { "mimeType": "application/x-www-form-urlencoded", "params": [{ "name": "user", "value": "{{ _['user-name'] }}" }] },
              "headers": [{ "name": "X-Request-Id", "value": "{% uuid 'v4' %}" }] },
            { "_id": "req_2", "_type": "request", "parentId": "fld_1", "name": "Today", "method": "GET",
              "url": "{{ _.base_url }}/today", "parameters": [{ "name": "city", "value": "Paris" }, { "name": "debug", "value": "1", "disabled": true }],
              "headers": [{ "name": "X-Session", "value": "{% response 'body', 'req_login', 'b64::JC5zZXNzaW9uLmlk::46b', 'never', 60 %}" }] },
            { "_id": "req_3", "_type": "request", "parentId": "fld_1", "name": "Query", "method": "POST", "url": "{{ _.base_url }}/graphql",
              "body": { "mimeType": "application/graphql", "text": "{\"query\":\"{ forecast { high } }\",\"variables\":{\"days\":3}}" } },
            { "_id": "env_base", "_type": "environment", "parentId": "wrk_1", "name": "Base Environment",
              "data": { "base_url": "http://localhost:8080", "user-name": "ada", "api": { "version": "v2" } } },
            { "_id": "env_prod", "_type": "environment", "parentId": "env_base", "name": "Production", "data": { "base_url": "https://weather.example.com" } }
          ]
        }
        """#
        let fixture = Fixture()
        let output = try Importer.convert([fixture.file("insomnia.json", export)])
        #expect(output.title == "Weather")
        #expect(output.files.map(\.path) == ["Requests.stamp", "Forecasts.stamp"])
        #expect(output.files[0].text.contains("### Sign in\nPOST {{base_url}}/session\nX-Request-Id: {{uuid()}}\nContent-Type: application/x-www-form-urlencoded\n\nuser = {{userName}}"))

        let forecasts = output.files[1].text
        #expect(forecasts.contains("### Today\n@needs signIn\n@auth bearer {{token}}\nGET {{base_url}}/today?city=Paris\nX-Session: {{signIn.body.session.id}}"))
        #expect(forecasts.contains("### Query\n@auth bearer {{token}}\nGRAPHQL {{base_url}}/graphql\n\n{ forecast { high } }\n\n{\n  \"days\": 3\n}"))
        #expect(output.environment.shared.map(\.name) == ["base_url", "userName", "apiVersion", "base_url"])
        #expect(output.environment.dimension?.values == ["production"])
        _ = try fixture.workspace(output)
    }

    @Test func importsFormat5() throws {
        let yaml = """
        type: collection.insomnia.rest/5.0
        name: Pets
        meta:
          id: wrk_9
        collection:
          - name: Cats
            meta:
              id: fld_9
            children:
              - url: "{{ _.host }}/cats"
                name: List cats
                meta:
                  id: req_9
                method: GET
                authentication:
                  type: basic
                  username: admin
                  password: hunter 2
        environments:
          name: Base Environment
          data:
            host: https://pets.example.com
          subEnvironments:
            - name: Local
              data:
                host: http://localhost:3000
        """
        let fixture = Fixture()
        let output = try Importer.convert([fixture.file("pets.yaml", yaml)])
        #expect(output.files.map(\.path) == ["Cats.stamp"])
        #expect(output.files[0].text.contains("### List cats\n@auth basic admin {{password}}\nGET {{host}}/cats"))
        #expect(output.environment.local == [.init(conditions: [], name: "password", source: #"secret("hunter 2")"#)])
        #expect(output.environment.dimension?.values == ["local"])
        _ = try fixture.workspace(output)
    }
}

struct BrunoImportTests {
    @Test func importsACollectionFolder() throws {
        let fixture = Fixture()
        let root = fixture.directory.appendingPathComponent("bruno-shop")
        _ = fixture.file("bruno-shop/bruno.json", #"{ "version": "1", "name": "Shop", "type": "collection" }"#)
        _ = fixture.file("bruno-shop/collection.bru", """
        headers {
          X-Client: stampdrill
        }

        auth {
          mode: bearer
        }

        auth:bearer {
          token: {{token}}
        }
        """)
        _ = fixture.file("bruno-shop/Users/folder.bru", """
        meta {
          name: People
        }
        """)
        _ = fixture.file("bruno-shop/Users/Create user.bru", """
        meta {
          name: Create user
          type: http
          seq: 2
        }

        post {
          url: {{baseUrl}}/users/:team
          body: json
          auth: inherit
        }

        params:path {
          team: blue
        }

        headers {
          Content-Type: application/json
          ~X-Trace: on
        }

        body:json {
          {
            "name": "{{$randomFullName}}",
            "tags": ["new"]
          }
        }

        vars:post-response {
          userId: res.body.id
        }

        assert {
          res.status: eq 201
          res.body.name: isDefined
        }

        tests {
          test("has an id", function() {
            expect(res.body.id).to.equal(7);
          });
          console.log(res.body);
        }
        """)
        _ = fixture.file("bruno-shop/Users/List users.bru", """
        meta {
          name: List users
          seq: 1
        }

        get {
          url: {{baseUrl}}/users?limit=10
          body: none
          auth: none
        }
        """)
        _ = fixture.file("bruno-shop/environments/Local.bru", """
        vars {
          baseUrl: http://localhost:4000
          ~unused: x
        }
        vars:secret [
          token
        ]
        """)

        let output = try Importer.convert([root])
        #expect(output.title == "Shop")
        #expect(output.files.map(\.path) == ["People.stamp"])
        let text = output.files[0].text
        #expect(text.contains("### List users\nGET {{baseUrl}}/users?limit=10\nX-Client: stampdrill"))
        #expect(text.contains("""
        ### Create user
        # Bruno test script lines that weren't converted:
        #   console.log(res.body);
        @team = blue
        @auth bearer {{token}}
        POST {{baseUrl}}/users/{{team}}
        X-Client: stampdrill
        Content-Type: application/json
        # X-Trace: on

        {
          "name": "{{fake.name}}",
          "tags": ["new"]
        }

        > assert status == 201
        > assert body.name != null
        > set userId = body.id
        > assert body.id == 7
        """))
        #expect(output.environment.dimension?.values == ["local"])
        #expect(output.environment.local.contains { $0.name == "token" && $0.source == #"secret("")"# })
        #expect(output.warnings.contains { $0.contains("secret values") })
        _ = try fixture.workspace(output)
    }
}

struct HARImportTests {
    @Test func keepsAPICallsAndMovesCredentials() throws {
        let har = #"""
        { "log": { "creator": { "name": "WebInspector" }, "entries": [
          { "_resourceType": "document", "request": { "method": "GET", "url": "https://app.example.com/", "headers": [] }, "response": { "status": 200 } },
          { "_resourceType": "script", "request": { "method": "GET", "url": "https://app.example.com/main.js", "headers": [] }, "response": { "status": 200 } },
          { "_resourceType": "fetch", "request": { "method": "GET", "url": "https://api.example.com/me?fields=name",
              "headers": [{ "name": ":authority", "value": "api.example.com" }, { "name": "accept", "value": "application/json" },
                          { "name": "cookie", "value": "session=s3cr3t" }, { "name": "sec-fetch-mode", "value": "cors" }] },
            "response": { "status": 200 } },
          { "_resourceType": "xhr", "request": { "method": "POST", "url": "https://api.example.com/orders",
              "headers": [{ "name": "cookie", "value": "session=s3cr3t" }, { "name": "content-type", "value": "application/json" }],
              "postData": { "mimeType": "application/json", "text": "{\"sku\":\"A1\"}" } },
            "response": { "status": 201 } },
          { "_resourceType": "fetch", "request": { "method": "OPTIONS", "url": "https://api.example.com/orders", "headers": [] }, "response": { "status": 204 } },
          { "_resourceType": "fetch", "request": { "method": "GET", "url": "https://cdn.example.com/config.json", "headers": [] }, "response": { "status": 404 } }
        ] } }
        """#
        let fixture = Fixture()
        let output = try Importer.convert([fixture.file("session.har", har)])
        #expect(output.requestCount == 3)
        #expect(output.files.map(\.path) == ["api.example.com.stamp", "cdn.example.com.stamp"])
        #expect(output.files[0].text.contains("### GET /me\nGET {{baseUrl}}/me?fields=name\naccept: application/json\ncookie: {{cookie}}\n\n> assert status == 200"))
        #expect(output.files[0].text.contains("### POST /orders\nPOST {{baseUrl}}/orders\ncookie: {{cookie}}\ncontent-type: application/json\n\n{\"sku\":\"A1\"}\n\n> assert status == 201"))
        #expect(!output.files[1].text.contains("assert"))
        #expect(output.environment.local == [.init(conditions: [], name: "cookie", source: #"secret("session=s3cr3t")"#)])
        #expect(output.environment.shared.map(\.source) == [#""https://api.example.com""#, #""https://cdn.example.com""#])
        #expect(output.warnings == ["3 requests for pages, scripts, stylesheets, images and fonts were left out"])
        _ = try fixture.workspace(output)
    }
}

struct ImportEnvironmentTests {
    @Test func mergesIntoAnExistingEnvironment() {
        var changes = ImportedEnvironmentChanges()
        changes.dimension = ("environment", ["qa", "prod"])
        changes.shared = [
            .init(conditions: [.init(dimension: "environment", values: ["qa"])], name: "host", source: #""qa.example.com""#),
            .init(conditions: [], name: "timeout", source: "30"),
        ]
        let existing = "dimension environment = local, qa\n\nvars {\n  timeout = 10\n}\n"
        let (text, kept) = changes.apply(to: existing, local: false)
        #expect(kept == ["timeout"])
        #expect(text.contains("dimension environment = local, qa, prod"))
        #expect(text.contains("timeout = 10"))
        #expect(text.contains("vars environment=qa {\n  host = \"qa.example.com\"\n}"))
    }

    @Test func detectsFormats() throws {
        let fixture = Fixture()
        #expect(try Importer.detect(fixture.file("a.txt", "curl https://example.com")) == .curl)
        #expect(try Importer.detect(fixture.file("b.yaml", "openapi: 3.0.0\npaths: {}")) == .openAPI)
        #expect(throws: Importer.Failure.self) { try Importer.detect(fixture.file("c.json", #"{"hello": 1}"#)) }
    }
}

struct OpenCollectionImportTests {
    @Test func importsABundledCollection() throws {
        let yaml = """
        opencollection: "1.0.0"
        info:
          name: Billing
        request:
          headers:
            - name: X-Team
              value: billing
          auth:
            type: bearer
            token: "{{token}}"
        config:
          environments:
            - name: Staging
              variables:
                - name: host
                  value: https://billing.staging.example.com
                - name: token
                  secret: true
        items:
          - info:
              name: Invoices
              type: folder
            items:
              - info:
                  name: Get invoice
                  type: http
                  seq: 1
                http:
                  method: GET
                  url: "{{host}}/invoices/:id"
                  params:
                    - name: id
                      value: "17"
                      type: path
                  headers:
                    - name: X-Debug
                      value: "1"
                      disabled: true
                  auth: inherit
                runtime:
                  assertions:
                    - expression: res.status
                      operator: eq
                      value: "200"
                  actions:
                    - type: set-variable
                      phase: after-response
                      selector:
                        expression: $.data.number
                        method: jsonq
                      variable:
                        name: invoiceNumber
                        scope: runtime
              - info:
                  name: Pay
                  type: http
                http:
                  method: POST
                  url: "{{host}}/payments"
                  body:
                    type: form-urlencoded
                    data:
                      - name: amount
                        value: "10"
                  auth:
                    type: basic
                    username: cashier
                    password: "{{cashierPassword}}"
        """
        let fixture = Fixture()
        let output = try Importer.convert([fixture.file("billing.yml", yaml)])
        #expect(output.title == "Billing")
        #expect(output.files.map(\.path) == ["Invoices.stamp"])
        let text = output.files[0].text
        #expect(text.contains("### Get invoice\n@id = 17\n@auth bearer {{token}}\nGET {{host}}/invoices/{{id}}\nX-Team: billing\n# X-Debug: 1\n\n> assert status == 200\n> set invoiceNumber = body.data.number"))
        #expect(text.contains("### Pay\n@auth basic cashier {{cashierPassword}}\nPOST {{host}}/payments\nX-Team: billing\nContent-Type: application/x-www-form-urlencoded\n\namount = 10"))
        #expect(output.environment.dimension?.values == ["staging"])
        #expect(output.environment.local.contains { $0.name == "token" })
        _ = try fixture.workspace(output)
    }

    @Test func splitsChainedCurlCommands() throws {
        let result = try Importer.requests(fromCurl: "curl https://a.example.com/one; echo done && curl -XPOST -did=1 https://a.example.com/two")
        #expect(result.names == ["getOne", "postTwo"])
        #expect(result.text.contains("GET https://a.example.com/one\n"))
        #expect(result.text.contains("POST https://a.example.com/two\nContent-Type: application/x-www-form-urlencoded\n\nid = 1"))
    }
}
