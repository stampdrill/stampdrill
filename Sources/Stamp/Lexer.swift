import Foundation

public enum Punctuation: String, Sendable, CaseIterable {
    case leftParen = "("
    case rightParen = ")"
    case leftBracket = "["
    case rightBracket = "]"
    case leftBrace = "{"
    case rightBrace = "}"
    case comma = ","
    case dot = "."
    case colon = ":"
    case question = "?"
    case questionQuestion = "??"
    case bang = "!"
    case equal = "="
    case equalEqual = "=="
    case bangEqual = "!="
    case less = "<"
    case lessEqual = "<="
    case greater = ">"
    case greaterEqual = ">="
    case plus = "+"
    case minus = "-"
    case star = "*"
    case slash = "/"
    case percent = "%"
    case ampAmp = "&&"
    case pipePipe = "||"
    case arrow = "=>"
}

public enum TokenKind: Hashable, Sendable {
    case identifier(String)
    case number(Double)
    case string(String)
    case punctuation(Punctuation)
    case end
}

public struct Token: Hashable, Sendable {
    public var kind: TokenKind
    /// UTF-16 offsets relative to the start of the lexed text.
    public var start: Int
    public var end: Int
}

/// Splits a single-line expression into tokens.
///
/// Expressions always live on one line of a file, so the lexer works on UTF-16
/// units and reports plain offsets; callers add the column the text starts at.
struct Lexer {
    private let units: [UInt16]
    private var index = 0

    init(_ text: String) {
        units = Array(text.utf16)
    }

    struct Failure: Error {
        var message: String
        var offset: Int
    }

    mutating func tokenize() throws(Failure) -> [Token] {
        var tokens: [Token] = []
        while true {
            let token = try next()
            tokens.append(token)
            if token.kind == .end { return tokens }
        }
    }

    private mutating func next() throws(Failure) -> Token {
        skipWhitespace()
        let start = index
        guard let unit = peek() else {
            return Token(kind: .end, start: start, end: start)
        }

        if isIdentifierStart(unit) {
            while let u = peek(), isIdentifierPart(u) { index += 1 }
            return Token(kind: .identifier(text(start, index)), start: start, end: index)
        }
        if isDigit(unit) {
            return try number(from: start)
        }
        if unit == quote || unit == apostrophe {
            return try string(from: start, delimiter: unit)
        }
        return try punctuation(from: start)
    }

    private mutating func number(from start: Int) throws(Failure) -> Token {
        while let u = peek(), isDigit(u) || u == underscore { index += 1 }
        if peek() == dotUnit, let after = peek(1), isDigit(after) {
            index += 1
            while let u = peek(), isDigit(u) || u == underscore { index += 1 }
        }
        if let e = peek(), e == 0x65 || e == 0x45 { // e E
            var lookahead = 1
            if let sign = peek(1), sign == 0x2B || sign == 0x2D { lookahead = 2 }
            if let digit = peek(lookahead), isDigit(digit) {
                index += lookahead
                while let u = peek(), isDigit(u) { index += 1 }
            }
        }
        let literal = text(start, index).replacingOccurrences(of: "_", with: "")
        guard let value = Double(literal) else {
            throw Failure(message: "invalid number '\(literal)'", offset: start)
        }
        return Token(kind: .number(value), start: start, end: index)
    }

    private mutating func string(from start: Int, delimiter: UInt16) throws(Failure) -> Token {
        index += 1
        var value: [UInt16] = []
        while let unit = peek() {
            index += 1
            if unit == delimiter {
                return Token(kind: .string(String(decoding: value, as: UTF16.self)), start: start, end: index)
            }
            guard unit == backslash else {
                value.append(unit)
                continue
            }
            guard let escaped = peek() else { break }
            index += 1
            switch escaped {
            case 0x6E: value.append(0x0A)          // \n
            case 0x74: value.append(0x09)          // \t
            case 0x72: value.append(0x0D)          // \r
            case 0x30: value.append(0x00)          // \0
            case 0x75:                             // \u{XXXX}
                value.append(contentsOf: try unicodeEscape())
            default: value.append(escaped)         // \" \' \\ and anything else
            }
        }
        throw Failure(message: "unterminated string", offset: start)
    }

    private mutating func unicodeEscape() throws(Failure) -> [UInt16] {
        let start = index
        guard peek() == leftBraceUnit else {
            throw Failure(message: "expected '{' after \\u", offset: start)
        }
        index += 1
        let digitsStart = index
        while let u = peek(), u != rightBraceUnit { index += 1 }
        let digits = text(digitsStart, index)
        index += 1
        guard let scalarValue = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(scalarValue) else {
            throw Failure(message: "invalid unicode escape '\(digits)'", offset: start)
        }
        return Array(String(Character(scalar)).utf16)
    }

    private mutating func punctuation(from start: Int) throws(Failure) -> Token {
        let two = index + 1 < units.count ? text(index, index + 2) : ""
        if let p = Punctuation(rawValue: two), two.count == 2 {
            index += 2
            return Token(kind: .punctuation(p), start: start, end: index)
        }
        let one = text(index, index + 1)
        if let p = Punctuation(rawValue: one) {
            index += 1
            return Token(kind: .punctuation(p), start: start, end: index)
        }
        throw Failure(message: "unexpected character '\(one)'", offset: start)
    }

    private mutating func skipWhitespace() {
        while let u = peek(), u == 0x20 || u == 0x09 { index += 1 }
    }

    private func peek(_ ahead: Int = 0) -> UInt16? {
        index + ahead < units.count ? units[index + ahead] : nil
    }

    private func text(_ from: Int, _ to: Int) -> String {
        String(decoding: units[from..<min(to, units.count)], as: UTF16.self)
    }

    private let quote: UInt16 = 0x22
    private let apostrophe: UInt16 = 0x27
    private let backslash: UInt16 = 0x5C
    private let underscore: UInt16 = 0x5F
    private let dotUnit: UInt16 = 0x2E
    private let leftBraceUnit: UInt16 = 0x7B
    private let rightBraceUnit: UInt16 = 0x7D
}

func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }

func isIdentifierStart(_ u: UInt16) -> Bool {
    (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u == 0x5F || u == 0x24
}

func isIdentifierPart(_ u: UInt16) -> Bool {
    isIdentifierStart(u) || isDigit(u)
}
