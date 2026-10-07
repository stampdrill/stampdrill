/// Parses expressions with precedence climbing.
///
/// Precedence, loosest first:
///
///     ?:   ??   || or   && and   == != contains matches
///     < <= > >=   + -   * / %   ! - not   call . []
public struct ExprParser {
    private var tokens: [Token]
    private var position = 0
    private let line: Int
    private let column: Int

    /// Parses `text`, reporting positions relative to `line` and `column`.
    public static func parse(_ text: String, line: Int = 1, column: Int = 0) throws(Diagnostic) -> Expr {
        var parser = try ExprParser(text, line: line, column: column)
        let expr = try parser.expression()
        try parser.expectEnd()
        return expr
    }

    init(_ text: String, line: Int, column: Int) throws(Diagnostic) {
        self.line = line
        self.column = column
        var lexer = Lexer(text)
        do {
            tokens = try lexer.tokenize()
        } catch {
            throw Diagnostic.error(error.message, at: SourceRange(line: line, column: column + error.offset, length: 1))
        }
    }

    // MARK: Entry points used by statement parsers

    var isAtEnd: Bool { current.kind == .end }

    /// Offset just past the last consumed token, relative to the parsed text.
    var consumedOffset: Int { position > 0 ? tokens[position - 1].end : 0 }

    mutating func expectEnd() throws(Diagnostic) {
        guard isAtEnd else { throw unexpected("end of expression") }
    }

    mutating func consume(_ punctuation: Punctuation) -> Bool {
        guard current.kind == .punctuation(punctuation) else { return false }
        position += 1
        return true
    }

    mutating func identifier() throws(Diagnostic) -> String {
        guard case .identifier(let name) = current.kind else { throw unexpected("a name") }
        position += 1
        return name
    }

    // MARK: Grammar

    mutating func expression() throws(Diagnostic) -> Expr {
        let condition = try binary(0)
        guard consume(.question) else { return condition }
        let then = try expression()
        guard consume(.colon) else { throw unexpected("':'") }
        let otherwise = try expression()
        return .conditional(condition, then, otherwise)
    }

    private mutating func binary(_ minimum: Int) throws(Diagnostic) -> Expr {
        var lhs = try unary()
        while let (op, precedence) = binaryOperator(), precedence >= minimum {
            position += 1
            let rhs = try binary(precedence + 1)
            lhs = .binary(op, lhs, rhs)
        }
        return lhs
    }

    private func binaryOperator() -> (BinaryOperator, Int)? {
        switch current.kind {
        case .punctuation(.questionQuestion): (.coalesce, 1)
        case .punctuation(.pipePipe): (.or, 2)
        case .identifier("or"): (.or, 2)
        case .punctuation(.ampAmp): (.and, 3)
        case .identifier("and"): (.and, 3)
        case .punctuation(.equalEqual): (.equal, 4)
        case .punctuation(.bangEqual): (.notEqual, 4)
        case .identifier("contains"): (.contains, 4)
        case .identifier("matches"): (.matches, 4)
        case .punctuation(.less): (.less, 5)
        case .punctuation(.lessEqual): (.lessOrEqual, 5)
        case .punctuation(.greater): (.greater, 5)
        case .punctuation(.greaterEqual): (.greaterOrEqual, 5)
        case .punctuation(.plus): (.add, 6)
        case .punctuation(.minus): (.subtract, 6)
        case .punctuation(.star): (.multiply, 7)
        case .punctuation(.slash): (.divide, 7)
        case .punctuation(.percent): (.remainder, 7)
        default: nil
        }
    }

    private mutating func unary() throws(Diagnostic) -> Expr {
        switch current.kind {
        case .punctuation(.bang), .identifier("not"):
            position += 1
            return .unary(.not, try unary())
        case .punctuation(.minus):
            position += 1
            return .unary(.negate, try unary())
        default:
            return try postfix()
        }
    }

    private mutating func postfix() throws(Diagnostic) -> Expr {
        var expr = try primary()
        while true {
            if consume(.dot) {
                expr = .member(expr, try identifier())
            } else if consume(.leftBracket) {
                let index = try expression()
                guard consume(.rightBracket) else { throw unexpected("']'") }
                expr = .index(expr, index)
            } else if consume(.leftParen) {
                let arguments = try list(until: .rightParen)
                expr = .call(expr, arguments)
            } else {
                return expr
            }
        }
    }

    private mutating func primary() throws(Diagnostic) -> Expr {
        let token = current
        switch token.kind {
        case .number(let n):
            position += 1
            return .literal(.number(n))
        case .string(let s):
            position += 1
            return .literal(.string(s))
        case .identifier("true"):
            position += 1
            return .literal(.bool(true))
        case .identifier("false"):
            position += 1
            return .literal(.bool(false))
        case .identifier("null"):
            position += 1
            return .literal(.null)
        case .identifier(let name):
            position += 1
            if consume(.arrow) {
                return .lambda([name], try expression())
            }
            return .identifier(name)
        case .punctuation(.leftParen):
            if let parameters = lambdaParameters() {
                return .lambda(parameters, try expression())
            }
            position += 1
            let inner = try expression()
            guard consume(.rightParen) else { throw unexpected("')'") }
            return inner
        case .punctuation(.leftBracket):
            position += 1
            return .array(try list(until: .rightBracket))
        case .punctuation(.leftBrace):
            position += 1
            return .object(try objectEntries())
        default:
            throw unexpected("a value")
        }
    }

    /// Consumes `(a, b) =>` and returns the names, or leaves the position alone.
    private mutating func lambdaParameters() -> [String]? {
        var index = position + 1
        var names: [String] = []
        while index < tokens.count {
            switch tokens[index].kind {
            case .punctuation(.rightParen):
                guard index + 1 < tokens.count, tokens[index + 1].kind == .punctuation(.arrow) else { return nil }
                position = index + 2
                return names
            case .identifier(let name) where names.count == 0 || tokens[index - 1].kind == .punctuation(.comma):
                names.append(name)
            case .punctuation(.comma) where !names.isEmpty:
                break
            default:
                return nil
            }
            index += 1
        }
        return nil
    }

    private mutating func list(until closing: Punctuation) throws(Diagnostic) -> [Expr] {
        var items: [Expr] = []
        if consume(closing) { return items }
        repeat {
            if current.kind == .punctuation(closing) { break } // trailing comma
            items.append(try expression())
        } while consume(.comma)
        guard consume(closing) else { throw unexpected("'\(closing.rawValue)'") }
        return items
    }

    private mutating func objectEntries() throws(Diagnostic) -> [ObjectEntry] {
        var entries: [ObjectEntry] = []
        if consume(.rightBrace) { return entries }
        repeat {
            if current.kind == .punctuation(.rightBrace) { break }
            let key: String
            switch current.kind {
            case .identifier(let name): key = name
            case .string(let s): key = s
            default: throw unexpected("a property name")
            }
            position += 1
            guard consume(.colon) else { throw unexpected("':'") }
            entries.append(ObjectEntry(key: key, value: try expression()))
        } while consume(.comma)
        guard consume(.rightBrace) else { throw unexpected("'}'") }
        return entries
    }

    // MARK: Helpers

    private var current: Token { tokens[position] }

    private func unexpected(_ expected: String) -> Diagnostic {
        let token = current
        let found = switch token.kind {
        case .end: "end of line"
        case .identifier(let name): "'\(name)'"
        case .number(let n): formatNumber(n)
        case .string: "a string"
        case .punctuation(let p): "'\(p.rawValue)'"
        }
        let range = SourceRange(line: line, column: column + token.start, length: max(token.end - token.start, 1))
        return .error("expected \(expected), found \(found)", at: range)
    }
}
