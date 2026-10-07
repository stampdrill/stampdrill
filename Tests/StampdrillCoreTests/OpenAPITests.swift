import Foundation
import Testing
@testable import StampdrillCore
@testable import Stamp

struct YAMLTests {
    @Test func readsBlocksFlowsAndScalars() throws {
        let value = try YAML.parse("""
        # comment
        openapi: 3.0.3
        info:
          title: "Pet Store"   # trailing comment
          version: '1.0.0'
          description: |
            Line one
            Line two
        tags: [pets, "store: front"]
        servers:
          - url: https://{region}.example.com/v1
            variables:
              region:
                default: eu
          - url: http://localhost:8080
        limits: { maxItems: 100, strict: true, ratio: 0.5, nothing: ~ }
        folded: >
          one
          two
        base: &base
          type: object
        derived:
          <<: *base
          title: Derived
        list:
        - a
        - b
        """)
        guard case .object(let root) = value else {
            Issue.record("expected an object")
            return
        }
        #expect(root.keys == ["openapi", "info", "tags", "servers", "limits", "folded", "base", "derived", "list"])
        #expect(root["openapi"] == "3.0.3")
        #expect(root["info"] == ["title": "Pet Store", "version": "1.0.0", "description": "Line one\nLine two\n"])
        #expect(root["tags"] == ["pets", "store: front"])
        #expect(root["limits"] == ["maxItems": 100, "strict": true, "ratio": 0.5, "nothing": .null])
        #expect(root["folded"] == "one two\n")
        #expect(root["derived"] == ["type": "object", "title": "Derived"])
        #expect(root["list"] == ["a", "b"])
        guard case .array(let servers)? = root["servers"] else {
            Issue.record("expected servers")
            return
        }
        #expect(servers.count == 2)
        #expect(servers[0].objectValue?["variables"]?.objectValue?["region"] == ["default": "eu"])
    }
}

struct OpenAPIImporterTests {
    private let petstore = """
    openapi: 3.0.3
    info:
      title: Swagger Petstore
      version: 1.0.27
    servers:
      - url: https://petstore3.example.com/api/v3
    security:
      - api_key: []
    tags:
      - name: pet
    paths:
      /pet:
        post:
          tags: [pet]
          summary: Add a new pet to the store
          operationId: addPet
          requestBody:
            required: true
            content:
              application/json:
                schema:
                  $ref: '#/components/schemas/Pet'
          responses:
            '200':
              description: Successful operation
              content:
                application/json:
                  schema:
                    $ref: '#/components/schemas/Pet'
      /pet/{petId}:
        parameters:
          - name: petId
            in: path
            required: true
            schema: { type: integer, format: int64, example: 10 }
        get:
          tags: [pet]
          summary: Find pet by ID
          operationId: getPetById
          responses:
            '200': { description: ok }
        delete:
          tags: [pet]
          operationId: deletePet
          security:
            - petstore_auth: []
          parameters:
            - name: X-Request-Id
              in: header
              schema: { type: string, format: uuid }
          responses:
            '204': { description: gone }
      /store/inventory:
        get:
          tags: [store]
          operationId: getInventory
          parameters:
            - name: status
              in: query
              required: true
              schema:
                type: string
                enum: [available, pending]
          responses:
            '200': { description: ok }
    components:
      schemas:
        Pet:
          type: object
          required: [name]
          properties:
            id: { type: integer, example: 10 }
            name: { type: string, example: doggie }
            status: { type: string, enum: [available, sold] }
            category:
              $ref: '#/components/schemas/Category'
        Category:
          type: object
          properties:
            name: { type: string, example: Dogs }
      securitySchemes:
        api_key:
          type: apiKey
          name: api_key
          in: header
        petstore_auth:
          type: oauth2
          flows:
            clientCredentials:
              tokenUrl: https://petstore3.example.com/oauth/token
              scopes: {}
    """

    @Test func createsAFilePerTag() throws {
        let output = try OpenAPIImporter.convert(Data(petstore.utf8))
        #expect(output.title == "Swagger Petstore")
        #expect(output.operationCount == 4)
        #expect(output.files.map(\.path) == ["Pet.stamp", "Store.stamp"])

        let pets = Document.parse(output.files[0].text, fileName: "Pet.stamp")
        #expect(pets.diagnostics.isEmpty)
        #expect(pets.declarations.first?.name == "baseUrl")
        #expect(pets.requests.map(\.name) == ["addPet", "getPetById", "deletePet"])

        let add = pets.requests[0]
        #expect(add.method == "POST")
        #expect(add.rawTarget == "{{baseUrl}}/pet")
        #expect(add.auth?.kindName == "apikey")
        #expect(add.headers.map(\.name) == ["Content-Type", "Accept"])
        let body = try Value(json: try #require(add.body?.rawText))
        #expect(body.objectValue?["name"] == "doggie")
        #expect(body.objectValue?["category"] == ["name": "Dogs"])
        #expect(add.script.first?.source == "assert status == 200")

        let get = pets.requests[1]
        #expect(get.rawTarget == "{{baseUrl}}/pet/{{petId}}")
        #expect(get.declarations.map(\.name) == ["petId"])

        let delete = pets.requests[2]
        #expect(delete.auth?.kindName == "oauth2")
        #expect(delete.headers.map(\.name).contains("X-Request-Id"))

        let store = Document.parse(output.files[1].text, fileName: "Store.stamp")
        #expect(store.requests[0].rawTarget == "{{baseUrl}}/store/inventory?status={{status}}")
    }

    @Test func importedRequestsResolve() throws {
        let output = try OpenAPIImporter.convert(Data(petstore.utf8))
        let workspace = makeWorkspace(Dictionary(uniqueKeysWithValues: output.files.map { ($0.path, $0.text) }))
        let file = try #require(workspace.file(at: "Pet.stamp"))
        let request = try #require(file.document.request(named: "getPetById"))
        let scope = RequestResolver.scope(for: request, in: file, workspace: workspace, input: ResolutionInput(overrides: ["apiKey": "k"]))
        let resolved = try RequestResolver.resolve(request, in: file, scope: scope)
        #expect(resolved.url.absoluteString == "https://petstore3.example.com/api/v3/pet/10")
        #expect(resolved.header("api_key") == "k")
    }

    @Test func readsSwagger2() throws {
        let spec = #"""
        {
          "swagger": "2.0",
          "info": { "title": "Legacy", "version": "1" },
          "host": "legacy.example.com",
          "basePath": "/v1",
          "schemes": ["https"],
          "paths": {
            "/users": {
              "post": {
                "operationId": "createUser",
                "parameters": [{ "in": "body", "name": "body", "schema": { "type": "object", "properties": { "email": { "type": "string", "format": "email" } } } }],
                "responses": { "201": { "description": "created" } }
              }
            }
          }
        }
        """#
        let output = try OpenAPIImporter.convert(Data(spec.utf8))
        let document = Document.parse(output.files[0].text)
        #expect(output.files[0].text.contains("@baseUrl = https://legacy.example.com/v1"))
        #expect(document.requests[0].body?.rawText.contains("@") == true)
        #expect(document.requests[0].script.first?.source == "assert status == 201")
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: OpenAPIImporter.Failure.self) { try OpenAPIImporter.convert(Data("name: not a spec".utf8)) }
    }
}
