import Testing
@testable import Stamp

struct FunctionTests {
    private func eval(_ text: String, _ scope: Scope = Scope(builtins: Builtins.standard)) throws -> Value {
        try scope.evaluate(ExprParser.parse(text))
    }

    private let items: Scope = {
        Scope(layers: [.init("response", ["items": .value([
            ["id": 3, "name": "pug", "price": 12.5],
            ["id": 1, "name": "husky", "price": 30],
            ["id": 2, "name": "beagle", "price": 7.5],
        ])])], builtins: Builtins.standard)
    }()

    @Test func parsesLambdas() throws {
        #expect(try ExprParser.parse("map(items, x => x.id)").description == "map(items, x => x.id)")
        #expect(try ExprParser.parse("reduce(items, (sum, x) => sum + x.price, 0)").description == "reduce(items, (sum, x) => sum + x.price, 0)")
        #expect(try ExprParser.parse("(1 + 2) * 3") == .binary(.multiply, .binary(.add, .literal(.number(1)), .literal(.number(2))), .literal(.number(3))))
    }

    @Test func callsHigherOrderFunctions() throws {
        #expect(try eval("map(items, x => x.id)", items) == [3, 1, 2])
        #expect(try eval("filter(items, x => x.price > 10).length", items) == 2)
        #expect(try eval("find(items, x => x.name == \"husky\").id", items) == 1)
        #expect(try eval("all(items, x => x.id > 0) and not any(items, x => x.price > 100)", items) == true)
        #expect(try eval("sum(items, x => x.price)", items) == 50)
        #expect(try eval("map(sortBy(items, x => x.id), x => x.name)", items) == ["husky", "beagle", "pug"])
        #expect(try eval("max(items, x => x.price).name", items) == "husky")
        #expect(try eval("reduce(range(5), (total, n) => total + n, 0)") == 10)
        #expect(try eval("keys(groupBy([1, 2, 3, 4], n => n % 2 == 0 ? \"even\" : \"odd\"))") == ["odd", "even"])
        #expect(try eval("count(items, x => x.price < 20)", items) == 2)
        #expect(try eval("unique([1, 1, 2])") == [1, 2])
    }

    @Test func declaresFunctionsInFiles() throws {
        let document = Document.parse("""
        fn bearerFor(user) = "Bearer " + user.token
        fn page(n, size) = "?page=" + n + "&size=" + (size ?? 20)
        fn factorial(n) = n <= 1 ? 1 : n * factorial(n - 1)

        GET https://example.com/items{{page(2, null)}}
        """)
        #expect(document.diagnostics.isEmpty)
        let bindings = Dictionary(uniqueKeysWithValues: document.declarations.map { ($0.name, $0.binding) })
        let scope = Scope(layers: [.init("file", bindings)], builtins: Builtins.standard)
        #expect(try eval("bearerFor({ token: \"abc\" })", scope) == "Bearer abc")
        #expect(try eval("page(2, null)", scope) == "?page=2&size=20")
        #expect(try eval("factorial(5)", scope) == 120)
    }

    @Test func stopsRunawayRecursion() {
        let document = Document.parse("fn loop(n) = loop(n + 1)")
        let scope = Scope(layers: [.init("file", Dictionary(uniqueKeysWithValues: document.declarations.map { ($0.name, $0.binding) }))])
        #expect(throws: EvaluationError("loop calls itself too deeply")) { try scope.evaluate(ExprParser.parse("loop(0)")) }
    }

    @Test func parsesSaveStatements() {
        let document = Document.parse("""
        GET https://example.com

        > save token = body.token
        """)
        #expect(document.diagnostics.isEmpty)
        #expect(document.requests[0].script.first?.kind == .save("token", .member(.identifier("body"), "token")))
    }
}

struct MockTests {
    private func seeded(_ seed: String) -> Scope {
        Scope(layers: [.init("environment", ["seed": .value(.string(seed))])], builtins: Builtins.standard)
    }

    @Test func seedsMakeFakeDataRepeatable() throws {
        let expression = try ExprParser.parse("[fake.name, fake.email, uuid(), randomInt(1, 1000)]")
        let first = try seeded("42").evaluate(expression)
        let second = try seeded("42").evaluate(expression)
        let other = try seeded("43").evaluate(expression)
        #expect(first == second)
        #expect(first != other)
    }

    @Test func keyedRecordsAreConsistentAcrossScopes() throws {
        let a = try Scope(builtins: Builtins.standard).evaluate(ExprParser.parse("person(7)"))
        let b = try Scope(builtins: Builtins.standard).evaluate(ExprParser.parse("person(7)"))
        #expect(a == b)
        guard case .object(let person) = a, case .string(let email)? = person["email"], case .string(let first)? = person["firstName"] else {
            Issue.record("expected a person")
            return
        }
        let folded = first.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter(\.isLetter)
        #expect(email.hasPrefix(folded + "."))
    }

    @Test func mocksFromJSONSchema() throws {
        let schema: Value = [
            "type": "object",
            "required": ["id", "email"],
            "properties": [
                "id": ["type": "integer", "minimum": 1, "maximum": 10],
                "email": ["type": "string", "format": "email"],
                "status": ["type": "string", "enum": ["active", "blocked"]],
                "tags": ["type": "array", "items": ["type": "string"], "minItems": 2, "maxItems": 2],
                "city": ["type": "string"],
                "nickname": ["type": "string", "example": "rojo"],
            ],
        ]
        var random = SeededRandom(seed: "schema")
        guard case .object(let object) = Mock.value(for: schema, using: &random) else {
            Issue.record("expected an object")
            return
        }
        #expect((1...10).contains(Int(object["id"]?.numberValue ?? 0)))
        #expect(object["email"]?.stringValue?.contains("@") == true)
        #expect(["active", "blocked"].contains(object["status"]?.stringValue ?? ""))
        if case .array(let tags)? = object["tags"] { #expect(tags.count == 2) } else { Issue.record("tags missing") }
        #expect(Faker.cities.map(\.0).contains(object["city"]?.stringValue ?? ""))
        #expect(object["nickname"] == "rojo")
    }

    @Test func unknownFakeMembersExplainThemselves() {
        #expect(throws: EvaluationError.self) { try Scope().evaluate(ExprParser.parse("fake.nothing")) }
    }

    @Test func writesValuesBackAsSource() throws {
        let value: Value = ["name": "Rojîn", "tags": ["a"], "n": 2]
        #expect(try Scope().evaluate(ExprParser.parse(value.sourceLiteral)) == value)
        #expect(Value.string("say \"hi\"").sourceLiteral == #""say \"hi\"""#)
    }
}
