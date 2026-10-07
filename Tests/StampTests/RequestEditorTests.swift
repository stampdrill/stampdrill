import Testing
@testable import Stamp

struct RequestEditorTests {
    private let original = """
    @base = https://example.com

    ### Create
    # creates a post
    POST {{base}}/posts HTTP/1.1
    Content-Type: application/json
    # X-Debug: 1

    { "title": "hi" }

    > assert status == 201

    ### List
    GET {{base}}/posts

    """

    @Test func changesTheRequestLineKeepingTheVersion() {
        var editor = RequestEditor(text: original)
        editor.setRequestLine(method: "put", target: "{{base}}/posts/1", of: "create")
        #expect(editor.text.contains("PUT {{base}}/posts/1 HTTP/1.1"))
        #expect(editor.document.requests[0].method == "PUT")
    }

    @Test func rewritesHeaders() {
        var editor = RequestEditor(text: original)
        editor.setHeaders([
            HeaderDraft(name: "Content-Type", value: "application/json"),
            HeaderDraft(name: "X-Debug", value: "1", isEnabled: false),
            HeaderDraft(name: "Accept", value: "*/*"),
        ], of: "create")
        let request = editor.document.requests[0]
        #expect(request.headers.map(\.name) == ["Content-Type", "X-Debug", "Accept"])
        #expect(request.headers.map(\.isEnabled) == [true, false, true])
        #expect(request.body?.rawText == #"{ "title": "hi" }"#)

        editor.setHeaders([HeaderDraft(name: "Accept", value: "text/plain")], of: "list")
        #expect(editor.document.requests[1].headers.map(\.value.parts) == [[.text("text/plain")]])
    }

    @Test func setsAndRemovesBodies() {
        var editor = RequestEditor(text: original)
        editor.setBody("{\n  \"title\": \"changed\"\n}", of: "create")
        #expect(editor.document.requests[0].body?.rawText == "{\n  \"title\": \"changed\"\n}")
        #expect(editor.document.requests[0].script.count == 1)

        editor.setBody("{ \"page\": 2 }", of: "list")
        #expect(editor.document.requests[1].body?.rawText == "{ \"page\": 2 }")

        editor.setBody(nil, of: "create")
        #expect(editor.document.requests[0].body == nil)
        #expect(editor.document.requests[0].script.count == 1)
        #expect(editor.document.diagnostics.isEmpty)
    }

    @Test func editsAuthAndScript() {
        var editor = RequestEditor(text: original)
        editor.setAuth("bearer {{token}}", of: "list")
        editor.setScript(["assert status == 200", "set first = body[0]"], of: "list")
        editor.setScript(["assert status == 201", "print body.id"], of: "create")
        let document = editor.document
        #expect(document.diagnostics.isEmpty)
        #expect(document.requests[1].auth?.kindName == "bearer")
        #expect(document.requests[1].script.map(\.source) == ["assert status == 200", "set first = body[0]"])
        #expect(document.requests[0].script.map(\.source) == ["assert status == 201", "print body.id"])

        editor.setAuth(nil, of: "list")
        editor.setScript([], of: "create")
        #expect(editor.document.requests[1].auth == nil)
        #expect(editor.document.requests[0].script.isEmpty)
    }

    @Test func managesSections() {
        var editor = RequestEditor(text: original)
        let added = editor.appendRequest(title: "Delete", method: "DELETE", target: "{{base}}/posts/1")
        #expect(added == "delete")
        let copy = editor.duplicateRequest(named: "create")
        #expect(copy == "createCopy")
        editor.setTitle("Create a post", of: "create")
        editor.removeRequest(named: "list")
        #expect(editor.document.requests.map(\.name) == ["createAPost", "createCopy", "delete"])
        #expect(editor.document.diagnostics.isEmpty)
    }

    @Test func titlesAnUntitledRequest() {
        var editor = RequestEditor(text: "GET https://example.com\n", fileName: "ping.stamp")
        editor.setTitle("Ping", of: "ping")
        #expect(editor.text == "### Ping\nGET https://example.com\n")
    }

    @Test func appendsToTheScriptWithoutRewritingIt() {
        var editor = RequestEditor(text: "MCP http://localhost/mcp\n\n> assert toolNames contains \"a\"\n# keep this\n> print tools", fileName: "mcp.stamp")
        let name = editor.document.requests[0].name
        editor.appendScript(["let a = call(\"a\")", "assert !a.isError"], of: name)
        #expect(editor.text == "MCP http://localhost/mcp\n\n> assert toolNames contains \"a\"\n# keep this\n> print tools\n> let a = call(\"a\")\n> assert !a.isError")

        var empty = RequestEditor(text: "MCP http://localhost/mcp", fileName: "mcp.stamp")
        empty.appendScript(["ping()"], of: empty.document.requests[0].name)
        #expect(empty.text == "MCP http://localhost/mcp\n\n> ping()")
    }
}
