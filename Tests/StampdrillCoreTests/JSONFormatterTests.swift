import Testing
@testable import StampdrillCore

struct JSONFormatterTests {
    @Test func indentsNestedValues() {
        let text = #"{"id":12345678901234567890,"tags":["a","b"],"empty":{},"none":[],"nested":{"ok":true}}"#
        #expect(JSONFormatter.prettyPrinted(text) == """
        {
          "id": 12345678901234567890,
          "tags": [
            "a",
            "b"
          ],
          "empty": {},
          "none": [],
          "nested": {
            "ok": true
          }
        }
        """)
    }

    @Test func keepsStringsIntact() {
        let text = #"  [ "a, b: {c}", "quote \" and \\" ]  "#
        #expect(JSONFormatter.minified(text) == #"["a, b: {c}","quote \" and \\"]"#)
    }

    @Test func rejectsNonJSON() {
        #expect(JSONFormatter.prettyPrinted("hello") == nil)
        #expect(JSONFormatter.prettyPrinted("{\"a\": [1, 2}") == nil)
        #expect(JSONFormatter.prettyPrinted("{} {}") == nil)
        #expect(JSONFormatter.prettyPrinted("\"unterminated") == nil)
    }
}
