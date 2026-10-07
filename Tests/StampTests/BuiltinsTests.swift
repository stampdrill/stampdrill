import Testing
@testable import Stamp

struct BuiltinsTests {
    private func eval(_ text: String) throws -> Value {
        try Scope(builtins: Builtins.standard).evaluate(ExprParser.parse(text))
    }

    @Test func buildsAuthorizationValues() throws {
        #expect(try eval("bearer(\"abc\")") == "Bearer abc")
        #expect(try eval("bearer(\"Bearer abc\")") == "Bearer abc")
        #expect(try eval("basic(\"aladdin\", \"opensesame\")") == "Basic YWxhZGRpbjpvcGVuc2VzYW1l")
    }

    @Test func buildsHosts() throws {
        #expect(try eval("localhost(TOMCAT)") == "localhost:8080")
        #expect(try eval("localhost(WEB)") == "localhost")
        #expect(try eval("onPort(\"db\", POSTGRES)") == "db:5432")
    }

    @Test func encodes() throws {
        #expect(try eval("json({ id: 1, tags: [\"a\"] })") == #"{"id":1,"tags":["a"]}"#)
        #expect(try eval("parseJson(\"[1,2]\")[1]") == 2)
        #expect(try eval("urlencode(\"a b&c\")") == "a%20b%26c")
        #expect(try eval("base64decode(base64(\"posteçî\"))") == "posteçî")
        #expect(try eval("sha256(\"abc\")") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func manipulatesStrings() throws {
        #expect(try eval("upper(trim(\"  mail \"))") == "MAIL")
        #expect(try eval("join(split(\"a,b\", \",\"), \" | \")") == "a | b")
        #expect(try eval("length({ a: 1, b: 2 })") == 2)
        #expect(try eval("number(\" 42 \") + 1") == 43)
    }

    @Test func producesFakeData() throws {
        guard case .number(let id) = try eval("fake.id") else { Issue.record("fake.id is not a number"); return }
        #expect(id >= 1)
        #expect(try eval("fake.email").stringValue?.contains("@") == true)
        #expect(try eval("contentType.json") == "application/json")
    }

    @Test func reportsBadArguments() {
        #expect(throws: EvaluationError("basic() takes 2 arguments, got 1")) { try eval("basic(\"x\")") }
        #expect(throws: EvaluationError("'contentType' is not a function")) { try eval("contentType()") }
    }
}
