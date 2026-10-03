import Foundation
import Stamp

/// Reads the YAML found in API specifications into `Value`s, keeping key order.
///
/// It covers block mappings and sequences, flow collections, plain, quoted
/// and block (`|`, `>`) scalars, comments, documents markers, anchors and
/// aliases. Tags, complex keys and multiple documents are out of scope.
public enum YAML {
    public struct Failure: Error, LocalizedError, Sendable {
        public var line: Int
        public var message: String
        public var errorDescription: String? { "YAML line \(line): \(message)" }
    }

    public static func parse(_ text: String) throws -> Value {
        var parser = Parser(text)
        return try parser.document()
    }

    private struct Line {
        var number: Int
        var indent: Int
        /// Content without indentation or trailing comment.
        var text: String
        /// The raw line, for block scalars.
        var raw: String
    }

    private struct Parser {
        var lines: [Line] = []
        var index = 0
        var anchors: [String: Value] = [:]

        init(_ text: String) {
            for (offset, raw) in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").enumerated() {
                let content = Self.stripComment(raw)
                let trimmed = content.trimmingCharacters(in: .whitespaces)
                let indent = raw.prefix { $0 == " " }.count
                // Document markers and directives only count at the start of a line.
                if indent == 0, trimmed == "---" || trimmed == "..." || trimmed.hasPrefix("%") { continue }
                lines.append(Line(number: offset + 1, indent: indent, text: trimmed, raw: raw))
            }
        }

        mutating func document() throws -> Value {
            skipBlank()
            guard index < lines.count else { return .null }
            return try block(indent: lines[index].indent)
        }

        // MARK: Blocks

        private mutating func block(indent: Int) throws -> Value {
            skipBlank()
            guard index < lines.count else { return .null }
            let line = lines[index]
            if line.text.hasPrefix("- ") || line.text == "-" {
                return try sequence(indent: line.indent)
            }
            if Self.mappingKey(line.text) != nil {
                return try mapping(indent: line.indent)
            }
            index += 1
            return try scalarOrFlow(line.text, line: line.number, continuationIndent: line.indent)
        }

        private mutating func mapping(indent: Int) throws -> Value {
            var object = ObjectValue()
            while true {
                skipBlank()
                guard index < lines.count, lines[index].indent == indent, let (key, rest) = Self.mappingKey(lines[index].text) else { break }
                let line = lines[index]
                index += 1
                let value = try value(after: rest, parentIndent: indent, line: line.number)
                if key == "<<", case .object(let merged) = value {
                    for (mergedKey, mergedValue) in merged where object[mergedKey] == nil { object[mergedKey] = mergedValue }
                } else {
                    object[key] = value
                }
            }
            return .object(object)
        }

        private mutating func sequence(indent: Int) throws -> Value {
            var items: [Value] = []
            while true {
                skipBlank()
                guard index < lines.count, lines[index].indent == indent, lines[index].text.hasPrefix("- ") || lines[index].text == "-" else { break }
                let line = lines[index]
                let rest = line.text == "-" ? "" : String(line.text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if Self.mappingKey(rest) != nil, !rest.hasPrefix("{"), !rest.hasPrefix("\""), !rest.hasPrefix("'") {
                    // "- key: value" starts a mapping indented to where the key is.
                    let childIndent = line.indent + 2 + (line.text.dropFirst(2).prefix { $0 == " " }.count)
                    lines[index] = Line(number: line.number, indent: childIndent, text: rest, raw: line.raw)
                    items.append(try mapping(indent: childIndent))
                } else {
                    index += 1
                    items.append(try value(after: rest, parentIndent: indent, line: line.number))
                }
            }
            return .array(items)
        }

        /// The value after `key:` or `- `: inline, a block scalar, or a nested block.
        private mutating func value(after rest: String, parentIndent: Int, line: Int) throws -> Value {
            var rest = rest
            var anchor: String?
            if rest.hasPrefix("&") {
                let name = rest.dropFirst().prefix { !$0.isWhitespace }
                anchor = String(name)
                rest = rest.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
            }
            if rest.hasPrefix("!") {
                // Tags like !!str are ignored.
                rest = rest.drop { !$0.isWhitespace }.trimmingCharacters(in: .whitespaces)
            }

            let value: Value
            if rest.hasPrefix("*") {
                let name = String(rest.dropFirst())
                guard let aliased = anchors[name] else { throw Failure(line: line, message: "unknown alias '\(name)'") }
                value = aliased
            } else if rest.hasPrefix("|") || rest.hasPrefix(">") {
                value = .string(blockScalar(header: rest, parentIndent: parentIndent))
            } else if rest.isEmpty {
                skipBlank()
                if index < lines.count, lines[index].indent > parentIndent {
                    value = try block(indent: lines[index].indent)
                } else if index < lines.count, lines[index].indent == parentIndent, lines[index].text.hasPrefix("- ") {
                    // Sequences may sit at the same indentation as their key.
                    value = try sequence(indent: parentIndent)
                } else {
                    value = .null
                }
            } else {
                value = try scalarOrFlow(rest, line: line, continuationIndent: parentIndent)
            }
            if let anchor { anchors[anchor] = value }
            return value
        }

        private mutating func blockScalar(header: String, parentIndent: Int) -> String {
            let folded = header.hasPrefix(">")
            let keep = header.contains("+")
            let strip = header.contains("-")
            var collected: [String] = []
            // `|2-` says how far the content is indented, for text whose first line starts with spaces.
            var contentIndent: Int? = header.first(where: \.isNumber).flatMap { Int(String($0)) }.map { parentIndent + $0 }
            while index < lines.count {
                let line = lines[index]
                let blank = line.raw.trimmingCharacters(in: .whitespaces).isEmpty
                if !blank {
                    if contentIndent == nil { contentIndent = line.indent }
                    guard line.indent > parentIndent, line.indent >= (contentIndent ?? 0) else { break }
                }
                collected.append(blank ? "" : String(line.raw.dropFirst(contentIndent ?? 0)))
                index += 1
            }
            while !keep, collected.last == "" { collected.removeLast() }
            var text: String
            if folded {
                text = ""
                for (offset, line) in collected.enumerated() {
                    if line.isEmpty { text += "\n"; continue }
                    if offset > 0, !collected[offset - 1].isEmpty { text += " " }
                    text += line
                }
            } else {
                text = collected.joined(separator: "\n")
            }
            return strip ? text : text + "\n"
        }

        // MARK: Scalars and flow

        private mutating func scalarOrFlow(_ text: String, line: Int, continuationIndent: Int) throws -> Value {
            if text.hasPrefix("[") || text.hasPrefix("{") {
                var flowText = text
                // Flow collections may continue on following lines.
                while !Self.isBalanced(flowText), index < lines.count {
                    flowText += " " + lines[index].text
                    index += 1
                }
                var flow = FlowParser(Array(flowText.unicodeScalars), line: line)
                return try flow.value()
            }
            if text.hasPrefix("\"") || text.hasPrefix("'") {
                var quoted = text
                while !Self.isClosedQuote(quoted), index < lines.count {
                    quoted += " " + lines[index].text
                    index += 1
                }
                var flow = FlowParser(Array(quoted.unicodeScalars), line: line)
                return try flow.value()
            }
            // Plain scalars can continue on more indented lines.
            var plain = text
            while index < lines.count, lines[index].indent > continuationIndent, !lines[index].text.isEmpty,
                  Self.mappingKey(lines[index].text) == nil, !lines[index].text.hasPrefix("- ")
            {
                plain += " " + lines[index].text
                index += 1
            }
            return Self.plainScalar(plain)
        }

        static func plainScalar(_ text: String) -> Value {
            switch text {
            case "", "~", "null", "Null", "NULL": return .null
            case "true", "True", "TRUE": return .bool(true)
            case "false", "False", "FALSE": return .bool(false)
            default:
                let isNumeric = text.allSatisfy { $0.isNumber || "+-.eE".contains($0) } && text.contains(where: \.isNumber)
                // Keep things like versions ("3.0.0") and leading zeros as text.
                if isNumeric, text.filter({ $0 == "." }).count <= 1, !(text.count > 1 && text.hasPrefix("0") && !text.hasPrefix("0.")),
                   let number = Double(text)
                {
                    return .number(number)
                }
                return .string(text)
            }
        }

        /// "key: rest" with the key unquoted, or nil when the line isn't a mapping entry.
        static func mappingKey(_ text: String) -> (String, String)? {
            var scalars = Array(text.unicodeScalars)
            var key = ""
            var i = 0
            if let first = scalars.first, first == "\"" || first == "'" {
                i = 1
                while i < scalars.count, scalars[i] != first {
                    if first == "\"", scalars[i] == "\\", i + 1 < scalars.count { i += 1 }
                    key.unicodeScalars.append(scalars[i])
                    i += 1
                }
                i += 1
                guard i < scalars.count, scalars[i] == ":" else { return nil }
            } else {
                if text.hasPrefix("- ") || text.hasPrefix("[") || text.hasPrefix("{") { return nil }
                while i < scalars.count {
                    if scalars[i] == ":", i + 1 == scalars.count || scalars[i + 1] == " " { break }
                    key.unicodeScalars.append(scalars[i])
                    i += 1
                }
                guard i < scalars.count else { return nil }
            }
            scalars = Array(scalars[(i + 1)...])
            let rest = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
            return (key.trimmingCharacters(in: .whitespaces), rest)
        }

        private static func stripComment(_ line: String) -> String {
            var quote: Character?
            var previous: Character = " "
            for (offset, character) in line.enumerated() {
                if let q = quote {
                    if character == q { quote = nil }
                } else if character == "\"" || character == "'" {
                    if previous == " " || previous == ":" || previous == "[" || previous == "{" || previous == "," || offset == 0 { quote = character }
                } else if character == "#", previous == " " || offset == 0 {
                    return String(line.prefix(offset))
                }
                previous = character
            }
            return line
        }

        private static func isBalanced(_ text: String) -> Bool {
            var depth = 0
            var quote: Character?
            for character in text {
                if let q = quote {
                    if character == q { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "[" || character == "{" {
                    depth += 1
                } else if character == "]" || character == "}" {
                    depth -= 1
                }
            }
            return depth <= 0
        }

        private static func isClosedQuote(_ text: String) -> Bool {
            guard let first = text.first else { return true }
            var escaped = false
            for character in text.dropFirst() {
                if escaped { escaped = false; continue }
                if first == "\"", character == "\\" { escaped = true; continue }
                if character == first { return true }
            }
            return false
        }

        private mutating func skipBlank() {
            while index < lines.count, lines[index].text.isEmpty { index += 1 }
        }
    }

    /// `[a, "b", {c: 1}]` and quoted scalars.
    private struct FlowParser {
        let scalars: [Unicode.Scalar]
        var i = 0
        let line: Int

        init(_ scalars: [Unicode.Scalar], line: Int) {
            self.scalars = scalars
            self.line = line
        }

        mutating func value() throws -> Value {
            skipSpaces()
            guard i < scalars.count else { return .null }
            switch scalars[i] {
            case "[":
                i += 1
                var items: [Value] = []
                while true {
                    skipSpaces()
                    if i < scalars.count, scalars[i] == "]" { i += 1; return .array(items) }
                    items.append(try value())
                    skipSpaces()
                    if i < scalars.count, scalars[i] == "," { i += 1; continue }
                    if i < scalars.count, scalars[i] == "]" { i += 1; return .array(items) }
                    throw Failure(line: line, message: "expected ',' or ']'")
                }
            case "{":
                i += 1
                var object = ObjectValue()
                while true {
                    skipSpaces()
                    if i < scalars.count, scalars[i] == "}" { i += 1; return .object(object) }
                    let key = try value().interpolated
                    skipSpaces()
                    var entry: Value = .null
                    if i < scalars.count, scalars[i] == ":" {
                        i += 1
                        entry = try value()
                    }
                    object[key] = entry
                    skipSpaces()
                    if i < scalars.count, scalars[i] == "," { i += 1; continue }
                    if i < scalars.count, scalars[i] == "}" { i += 1; return .object(object) }
                    throw Failure(line: line, message: "expected ',' or '}'")
                }
            case "\"":
                i += 1
                var text = String.UnicodeScalarView()
                while i < scalars.count, scalars[i] != "\"" {
                    if scalars[i] == "\\", i + 1 < scalars.count {
                        i += 1
                        switch scalars[i] {
                        case "n": text.append("\n")
                        case "t": text.append("\t")
                        case "r": text.append("\r")
                        case "u":
                            let hex = String(String.UnicodeScalarView(scalars[(i + 1)..<min(i + 5, scalars.count)]))
                            if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) { text.append(scalar) }
                            i += 4
                        default: text.append(scalars[i])
                        }
                    } else {
                        text.append(scalars[i])
                    }
                    i += 1
                }
                i += 1
                return .string(String(text))
            case "'":
                i += 1
                var text = String.UnicodeScalarView()
                while i < scalars.count {
                    if scalars[i] == "'" {
                        if i + 1 < scalars.count, scalars[i + 1] == "'" { text.append("'"); i += 2; continue }
                        break
                    }
                    text.append(scalars[i])
                    i += 1
                }
                i += 1
                return .string(String(text))
            default:
                let start = i
                var depth = 0
                while i < scalars.count {
                    let scalar = scalars[i]
                    if depth == 0, scalar == "," || scalar == "]" || scalar == "}" { break }
                    if depth == 0, scalar == ":", i + 1 < scalars.count, scalars[i + 1] == " " { break }
                    if scalar == "[" || scalar == "{" { depth += 1 }
                    if scalar == "]" || scalar == "}" { depth -= 1 }
                    i += 1
                }
                let text = String(String.UnicodeScalarView(scalars[start..<i])).trimmingCharacters(in: .whitespaces)
                return Parser.plainScalar(text)
            }
        }

        private mutating func skipSpaces() {
            while i < scalars.count, scalars[i] == " " || scalars[i] == "\t" { i += 1 }
        }
    }
}
