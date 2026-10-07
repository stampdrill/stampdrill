import Testing
@testable import Stamp

struct TemplateTests {
    private let context = Scope(layers: [
        .init("environment", [
            "host": .value("localhost:8080"),
            "id": .value(41),
            "user": .value(["name": "Rojîn"]),
        ]),
    ])

    @Test func interpolatesExpressions() throws {
        let template = try Template.parse("http://{{host}}/users/{{ id + 1 }}?name={{user.name}}")
        #expect(try context.render(template) == "http://localhost:8080/users/42?name=Rojîn")
    }

    @Test func keepsBracesThatBelongToTheExpression() throws {
        let template = try Template.parse(#"<{{ { user: { name: "}}" } }.user.name }}>"#)
        #expect(try context.render(template) == "<}}>")
    }

    @Test func replacesKnownDollarVariablesOnly() throws {
        let template = try Template.parse("/conversations/$id/status?filter=$top", dollarVariables: true)
        #expect(try context.render(template) == "/conversations/41/status?filter=$top")
        #expect(try Template.parse("$id", dollarVariables: false).isConstant)
    }

    @Test func escapesOpeningBraces() throws {
        #expect(try context.render(Template.parse(#"\{{host}}"#)) == "{{host}}")
    }

    @Test func reportsUnclosedInterpolation() {
        #expect(throws: Diagnostic.error("missing '}}'", at: SourceRange(line: 4, column: 13, length: 2))) {
            try Template.parse("Bearer {{token", line: 4, column: 6)
        }
    }
}
