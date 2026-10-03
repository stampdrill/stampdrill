import Testing
@testable import Stamp

struct JSONTests {
    @Test func keepsKeyOrder() throws {
        let value = try Value(json: #"{"zeta": 1, "alpha": [true, null, 2.5], "mid": {"b": "x", "a": "y"}}"#)
        #expect(value.jsonString() == #"{"zeta":1,"alpha":[true,null,2.5],"mid":{"b":"x","a":"y"}}"#)
    }

    @Test func prettyPrints() throws {
        let value: Value = ["name": "Stampdrill", "tags": ["mail"], "empty": [:]]
        #expect(value.jsonString(pretty: true) == """
        {
          "name": "Stampdrill",
          "tags": [
            "mail"
          ],
          "empty": {}
        }
        """)
    }

    @Test func decodesEscapes() throws {
        #expect(try Value(json: #""line\nbreak ç 📮""#) == "line\nbreak ç 📮")
        #expect(Value.string("quote\"back\\slash").jsonString() == #""quote\"back\\slash""#)
    }

    @Test func rejectsInvalidDocuments() {
        #expect(throws: EvaluationError.self) { try Value(json: "{\"a\": }") }
        #expect(throws: EvaluationError.self) { try Value(json: "[1, 2] extra") }
    }
}
