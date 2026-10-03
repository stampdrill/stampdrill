import Testing
@testable import Stamp

struct ExprParserTests {
    private func parse(_ text: String) throws -> String {
        try ExprParser.parse(text).description
    }

    @Test func respectsPrecedence() throws {
        #expect(try ExprParser.parse("1 + 2 * 3") == .binary(.add, .literal(.number(1)), .binary(.multiply, .literal(.number(2)), .literal(.number(3)))))
        #expect(try ExprParser.parse("a || b && c") == .binary(.or, .identifier("a"), .binary(.and, .identifier("b"), .identifier("c"))))
        #expect(try ExprParser.parse("a ?? b == c") == .binary(.coalesce, .identifier("a"), .binary(.equal, .identifier("b"), .identifier("c"))))
    }

    @Test func parsesPostfixChains() throws {
        #expect(try parse("body.items[0].name") == "body.items[0].name")
        #expect(try parse("bearer(env.token)") == "bearer(env.token)")
        #expect(try parse("headers[\"content-type\"]") == "headers[\"content-type\"]")
    }

    @Test func parsesWordOperators() throws {
        #expect(try ExprParser.parse("not a and b or c") ==
            .binary(.or, .binary(.and, .unary(.not, .identifier("a")), .identifier("b")), .identifier("c")))
        #expect(try ExprParser.parse("text contains \"ok\"") == .binary(.contains, .identifier("text"), .literal(.string("ok"))))
    }

    @Test func parsesCollections() throws {
        #expect(try parse("json({ username: env.user, \"pass word\": 'x', tags: [1, 2,] })")
            == "json({username: env.user, \"pass word\": \"x\", tags: [1, 2]})")
    }

    @Test func parsesConditional() throws {
        #expect(try parse("status == 200 ? \"ok\" : \"failed\"") == "status == 200 ? \"ok\" : \"failed\"")
    }

    @Test func decodesStringEscapes() throws {
        #expect(try ExprParser.parse(#""a\"b\n\u{1F4EE}""#) == .literal(.string("a\"b\n📮")))
    }

    @Test func reportsPositions() {
        #expect(throws: Diagnostic.error("expected ')', found end of line", at: SourceRange(line: 3, column: 17, length: 1))) {
            try ExprParser.parse("upper(name", line: 3, column: 7)
        }
        #expect(throws: Diagnostic.error("unexpected character '#'", at: SourceRange(line: 1, column: 2, length: 1))) {
            try ExprParser.parse("a #")
        }
    }
}
