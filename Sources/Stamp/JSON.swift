import Foundation

extension Value {
    /// Parses JSON text, keeping the key order of objects.
    public init(json text: String) throws(EvaluationError) {
        var parser = JSONParser(Array(text.utf8))
        self = try parser.document()
    }

    public init(json data: Data) throws(EvaluationError) {
        var parser = JSONParser(Array(data))
        self = try parser.document()
    }

    public func jsonString(pretty: Bool = false) -> String {
        var output = ""
        writeJSON(self, into: &output, pretty: pretty, depth: 0)
        return output
    }
}

private func writeJSON(_ value: Value, into output: inout String, pretty: Bool, depth: Int) {
    let indent = pretty ? String(repeating: "  ", count: depth + 1) : ""
    let closingIndent = pretty ? String(repeating: "  ", count: depth) : ""
    let newline = pretty ? "\n" : ""
    let separator = pretty ? ": " : ":"

    switch value {
    case .null, .function, .dynamic, .lambda:
        output += "null"
    case .bool(let b):
        output += b ? "true" : "false"
    case .number(let n):
        output += n.isFinite ? formatNumber(n) : "null"
    case .string(let s):
        output += quoted(s)
    case .array(let items):
        guard !items.isEmpty else { output += "[]"; return }
        output += "[" + newline
        for (i, item) in items.enumerated() {
            output += indent
            writeJSON(item, into: &output, pretty: pretty, depth: depth + 1)
            output += (i < items.count - 1 ? "," : "") + newline
        }
        output += closingIndent + "]"
    case .object(let object):
        guard !object.isEmpty else { output += "{}"; return }
        output += "{" + newline
        for (i, entry) in object.enumerated() {
            output += indent + quoted(entry.key) + separator
            writeJSON(entry.value, into: &output, pretty: pretty, depth: depth + 1)
            output += (i < object.count - 1 ? "," : "") + newline
        }
        output += closingIndent + "}"
    }
}

private struct JSONParser {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
    }

    mutating func document() throws(EvaluationError) -> Value {
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw failure("unexpected trailing characters") }
        return value
    }

    private mutating func parseValue(depth: Int) throws(EvaluationError) -> Value {
        guard depth < 512 else { throw failure("nesting is too deep") }
        skipWhitespace()
        guard let byte = peek() else { throw failure("unexpected end of input") }
        switch byte {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    private mutating func parseObject(depth: Int) throws(EvaluationError) -> Value {
        index += 1
        var object = ObjectValue()
        skipWhitespace()
        if peek() == UInt8(ascii: "}") { index += 1; return .object(object) }
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else { throw failure("expected a property name") }
            let key = try parseString()
            skipWhitespace()
            guard peek() == UInt8(ascii: ":") else { throw failure("expected ':'") }
            index += 1
            object[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "}"): index += 1; return .object(object)
            default: throw failure("expected ',' or '}'")
            }
        }
    }

    private mutating func parseArray(depth: Int) throws(EvaluationError) -> Value {
        index += 1
        var items: [Value] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "]") { index += 1; return .array(items) }
        while true {
            items.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "]"): index += 1; return .array(items)
            default: throw failure("expected ',' or ']'")
            }
        }
    }

    private mutating func parseString() throws(EvaluationError) -> String {
        index += 1
        var buffer: [UInt8] = []
        while let byte = peek() {
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(decoding: buffer, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard let escaped = peek() else { break }
                index += 1
                switch escaped {
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "u"): buffer.append(contentsOf: try unicodeEscape())
                default: buffer.append(escaped)
                }
            default:
                buffer.append(byte)
            }
        }
        throw failure("unterminated string")
    }

    private mutating func unicodeEscape() throws(EvaluationError) -> [UInt8] {
        var high = try hexQuad()
        if (0xD800...0xDBFF).contains(high), peek() == UInt8(ascii: "\\"), peek(1) == UInt8(ascii: "u") {
            index += 2
            let low = try hexQuad()
            high = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
        }
        let scalar = Unicode.Scalar(high) ?? "\u{FFFD}"
        return Array(String(Character(scalar)).utf8)
    }

    private mutating func hexQuad() throws(EvaluationError) -> UInt32 {
        guard index + 4 <= bytes.count,
              let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
        else { throw failure("invalid unicode escape") }
        index += 4
        return value
    }

    private mutating func parseNumber() throws(EvaluationError) -> Double {
        let start = index
        while let byte = peek(), byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") || (byte >= 0x30 && byte <= 0x39)
        {
            index += 1
        }
        guard index > start, let number = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else {
            index = start
            throw failure("unexpected character")
        }
        return number
    }

    private mutating func expect(_ word: String) throws(EvaluationError) {
        let utf8 = Array(word.utf8)
        guard bytes.count >= index + utf8.count, Array(bytes[index..<index + utf8.count]) == utf8 else {
            throw failure("unexpected character")
        }
        index += utf8.count
    }

    private mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { index += 1 }
    }

    private func peek(_ ahead: Int = 0) -> UInt8? {
        index + ahead < bytes.count ? bytes[index + ahead] : nil
    }

    private func failure(_ message: String) -> EvaluationError {
        EvaluationError("invalid JSON at byte \(index): \(message)")
    }
}
