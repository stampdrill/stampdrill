import Foundation

/// Text with embedded expressions: `https://{{host}}/users/{{ id + 1 }}`.
///
/// Where `$names` are enabled (request lines and headers), `$id` is replaced
/// by the variable `id` when one exists and left untouched otherwise, so
/// URLs that legitimately contain a dollar sign keep working.
public struct Template: Hashable, Sendable {
    public enum Part: Hashable, Sendable {
        case text(String)
        /// `column` is where the expression source starts on its line.
        case expression(Expr, source: String, column: Int)
        case variable(String)
    }

    public var parts: [Part]

    public init(parts: [Part]) {
        self.parts = parts
    }

    public init(text: String) {
        parts = text.isEmpty ? [] : [.text(text)]
    }

    /// The template written back out as text.
    public var sourceText: String {
        parts.map { part in
            switch part {
            case .text(let text): text
            case .expression(_, let source, _): "{{" + source + "}}"
            case .variable(let name): "$" + name
            }
        }.joined()
    }

    public var isConstant: Bool {
        parts.allSatisfy { if case .text = $0 { true } else { false } }
    }

    /// Parses `text`, which starts at `column` on `line`.
    public static func parse(
        _ text: String, line: Int = 1, column: Int = 0, dollarVariables: Bool = false
    ) throws(Diagnostic) -> Template {
        let units = Array(text.utf16)
        var parts: [Part] = []
        var literal: [UInt16] = []
        var i = 0

        func flush() {
            if !literal.isEmpty {
                parts.append(.text(String(decoding: literal, as: UTF16.self)))
                literal.removeAll()
            }
        }

        while i < units.count {
            let unit = units[i]

            // \{{ is a literal "{{"
            if unit == backslash, i + 2 < units.count, units[i + 1] == openBrace, units[i + 2] == openBrace {
                literal.append(contentsOf: [openBrace, openBrace])
                i += 3
                continue
            }

            if unit == openBrace, i + 1 < units.count, units[i + 1] == openBrace {
                let start = i + 2
                guard let end = closingBraces(in: units, from: start) else {
                    throw .error("missing '}}'", at: SourceRange(line: line, column: column + i, length: 2))
                }
                let source = String(decoding: units[start..<end], as: UTF16.self)
                let trimmed = source.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else {
                    throw .error("empty '{{ }}'", at: SourceRange(line: line, column: column + i, length: end + 2 - i))
                }
                let expr = try ExprParser.parse(source, line: line, column: column + start)
                flush()
                parts.append(.expression(expr, source: trimmed, column: column + start))
                i = end + 2
                continue
            }

            if dollarVariables, unit == dollar, i + 1 < units.count, isIdentifierStart(units[i + 1]), units[i + 1] != dollar {
                var end = i + 1
                while end < units.count, isIdentifierPart(units[end]), units[end] != dollar { end += 1 }
                flush()
                parts.append(.variable(String(decoding: units[(i + 1)..<end], as: UTF16.self)))
                i = end
                continue
            }

            literal.append(unit)
            i += 1
        }
        flush()
        return Template(parts: parts)
    }

    /// Finds the `}}` that closes an interpolation, skipping over strings and
    /// braces that belong to object literals inside the expression.
    private static func closingBraces(in units: [UInt16], from start: Int) -> Int? {
        var depth = 0
        var quote: UInt16?
        var i = start
        while i < units.count {
            let unit = units[i]
            if let q = quote {
                if unit == backslash { i += 2; continue }
                if unit == q { quote = nil }
            } else if unit == 0x22 || unit == 0x27 {
                quote = unit
            } else if unit == openBrace {
                depth += 1
            } else if unit == closeBrace {
                if depth == 0, i + 1 < units.count, units[i + 1] == closeBrace { return i }
                depth = max(depth - 1, 0)
            }
            i += 1
        }
        return nil
    }
}

private let backslash: UInt16 = 0x5C
private let openBrace: UInt16 = 0x7B
private let closeBrace: UInt16 = 0x7D
private let dollar: UInt16 = 0x24

extension Scope {
    public func render(_ template: Template) throws(EvaluationError) -> String {
        var output = ""
        for part in template.parts {
            switch part {
            case .text(let text):
                output += text
            case .expression(let expr, _, _):
                output += try evaluate(expr).interpolated
            case .variable(let name):
                output += try lookup(name)?.interpolated ?? "$" + name
            }
        }
        return output
    }
}
