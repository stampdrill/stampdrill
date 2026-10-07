import Testing
@testable import Stamp

struct EvaluatorTests {
    private func eval(_ text: String, _ context: Scope = Scope()) throws -> Value {
        try context.evaluate(ExprParser.parse(text))
    }

    @Test func evaluatesArithmeticAndStrings() throws {
        #expect(try eval("1 + 2 * 3 - 4 / 2") == 5)
        #expect(try eval("7 % 3") == 1)
        #expect(try eval("\"page-\" + 2") == "page-2")
        #expect(try eval("[1] + [2, 3]") == [1, 2, 3])
    }

    @Test func comparesAndShortCircuits() throws {
        #expect(try eval("2 >= 2 and \"a\" < \"b\"") == true)
        #expect(try eval("false && missing") == false)
        #expect(try eval("true || missing") == true)
        #expect(try eval("{ a: 1 } == { a: 1 }") == true)
        #expect(try eval("200 == \"200\"") == false)
    }

    @Test func readsMembersAndIndexes() throws {
        let context = Scope(layers: [
            .init("response", ["body": .value(["items": [["name": "first"], ["name": "last"]], "total": 2])]),
        ])
        #expect(try eval("body.items[0].name", context) == "first")
        #expect(try eval("body.items[-1].name", context) == "last")
        #expect(try eval("body.items.length", context) == 2)
        #expect(try eval("body[\"total\"]", context) == 2)
        #expect(try eval("body.missing.deeper", context) == .null)
    }

    @Test func containsAndMatches() throws {
        #expect(try eval("\"application/json; charset=utf-8\" contains \"json\"") == true)
        #expect(try eval("[1, 2] contains 3") == false)
        #expect(try eval("\"2025-09-20\" matches \"^\\\\d{4}-\"") == true)
    }

    @Test func coalesceFallsBackForUnknownNames() throws {
        #expect(try eval("token ?? \"anonymous\"") == "anonymous")
        #expect(throws: EvaluationError("unknown variable 'token'", undefinedName: "token")) {
            try eval("token + 1")
        }
    }

    @Test func laterLayersShadowEarlierOnes() throws {
        let context = Scope(layers: [
            .init("environment", ["host": .value("localhost"), "port": .value(8080)]),
            .init("file", ["host": .expression(try ExprParser.parse("\"api.\" + host"))]),
        ])
        #expect(try eval("host + \":\" + port", context) == "api.localhost:8080")
        #expect(context.source(of: "host") == "file")
    }

    @Test func reportsSelfReference() throws {
        let context = Scope(layers: [
            .init("file", [
                "a": .expression(try ExprParser.parse("b")),
                "b": .expression(try ExprParser.parse("a")),
            ]),
        ])
        #expect(throws: EvaluationError("in 'b': 'a' refers to itself")) { try eval("a", context) }
    }

    @Test func exposesVariablesThroughEnv() throws {
        let context = Scope(layers: [.init("environment", ["host": .value("localhost")])])
        #expect(try eval("env.host", context) == "localhost")
        #expect(try eval("env.nothing", context) == .null)
    }

    @Test func recordsSecrets() throws {
        let context = Scope()
        #expect(try eval("secret(\"hunter2\")", context) == "hunter2")
        #expect(context.secrets == ["hunter2"])
    }
}
