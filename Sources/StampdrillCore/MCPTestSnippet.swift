import Foundation
import Stamp

/// Script lines that repeat an exchange from the inspector as a test: the
/// call, and assertions on what the server answered this time.
public enum MCPTestSnippet {
    public enum Action: Sendable {
        case call(tool: String, arguments: ObjectValue)
        case read(uri: String)
        case getPrompt(name: String, arguments: ObjectValue)
    }

    /// `result` is what the server answered, or `{ error }` for a JSON-RPC error.
    /// `existing` are the statements already in the script, so names don't clash.
    public static func lines(for action: Action, result: Value, existing: [ScriptStatement]) -> [String] {
        let taken = Set(existing.compactMap { statement -> String? in
            switch statement.kind {
            case .let(let name, _), .set(let name, _), .save(let name, _): name
            default: nil
            }
        })

        let call: String
        let base: String
        switch action {
        case .call(let tool, let arguments):
            base = identifier(from: tool)
            call = "call(\(literal(.string(tool)))\(arguments.isEmpty ? ", {}" : ", " + literal(.object(arguments))))"
        case .read(let uri):
            base = identifier(from: uri.split(separator: "/").last.map(String.init) ?? "resource")
            call = "read(\(literal(.string(uri))))"
        case .getPrompt(let name, let arguments):
            base = identifier(from: name)
            call = "getPrompt(\(literal(.string(name)))\(arguments.isEmpty ? "" : ", " + literal(.object(arguments))))"
        }
        var name = Stamp.Scope.intrinsicNames.contains(base) || MCPScriptSession.functions[base] != nil ? base + "Result" : base
        var suffix = 2
        let root = name
        while taken.contains(name) {
            name = root + String(suffix)
            suffix += 1
        }

        var lines = ["let \(name) = \(call)"]
        let object = result.objectValue ?? ObjectValue()

        if let error = object["error"]?.objectValue, let code = error["code"]?.numberValue {
            lines.append("assert \(name).error.code == \(literal(.number(code)))")
            return lines
        }

        switch action {
        case .call:
            lines.append(object["isError"] == .bool(true) ? "assert \(name).isError" : "assert !\(name).isError")
            if case .object(let structured)? = object["structuredContent"] {
                let scalars = structured.filter { _, value in value.isScalar }.prefix(3)
                for (key, value) in scalars {
                    let expression = "\(name).structuredContent\(path(key))"
                    if case .string(let text) = value {
                        lines.append(textAssertion(expression, text))
                    } else {
                        lines.append("assert \(expression) == \(literal(value))")
                    }
                }
                if scalars.isEmpty { lines.append("assert \(name).structuredContent != null") }
            } else if let text = joinedText(object["content"]) {
                lines.append(textAssertion("\(name).text", text))
            }
        case .read:
            let contents = object["contents"]?.arrayValue ?? []
            lines.append("assert \(name).contents.length == \(contents.count)")
            if let text = joinedText(object["contents"]) {
                lines.append(textAssertion("\(name).text", text))
            }
        case .getPrompt:
            let messages = object["messages"]?.arrayValue ?? []
            lines.append("assert \(name).messages.length == \(messages.count)")
            if let first = messages.first?.objectValue?["content"]?.objectValue?["text"]?.stringValue {
                lines.append(textAssertion("\(name).messages[0].content.text", first))
            }
        }
        return lines
    }

    /// Equality for short single-line text, otherwise the start of its first line.
    private static func textAssertion(_ expression: String, _ text: String) -> String {
        if text.count <= 120, !text.contains("\n") {
            return "assert \(expression) == \(literal(.string(text)))"
        }
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let start = firstLine.trimmingCharacters(in: .whitespaces).prefix(40).trimmingCharacters(in: .whitespaces)
        return start.isEmpty ? "assert \(expression) != \"\"" : "assert \(expression) contains \(literal(.string(start)))"
    }

    private static func joinedText(_ items: Value?) -> String? {
        let texts = (items?.arrayValue ?? []).compactMap { $0.objectValue?["text"]?.stringValue }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// `get-weather` → `getWeather`, `2fa` → `result2fa`.
    static func identifier(from text: String) -> String {
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty else { return "result" }
        var name = words[0].prefix(1).lowercased() + words[0].dropFirst()
        for word in words.dropFirst() { name += word.prefix(1).uppercased() + word.dropFirst() }
        name = String(name.unicodeScalars.filter { $0.isASCII }.map(Character.init))
        if name.isEmpty { return "result" }
        if name.first!.isNumber { name = "result" + name }
        return ["true", "false", "null", "contains", "matches", "and", "or", "not"].contains(name) ? name + "Result" : name
    }

    private static func path(_ key: String) -> String {
        isIdentifier(key) ? "." + key : "[\(literal(.string(key)))]"
    }

    private static func isIdentifier(_ key: String) -> Bool {
        guard let first = key.first, first.isLetter || first == "_" else { return false }
        return key.allSatisfy { ($0.isLetter || $0.isNumber || $0 == "_") && $0.isASCII }
    }

    /// Stamp source for a value: `{ city: "Paris", days: 3 }`.
    static func literal(_ value: Value) -> String {
        switch value {
        case .array(let items):
            "[" + items.map(literal).joined(separator: ", ") + "]"
        case .object(let object):
            object.isEmpty ? "{}" : "{ " + object.map { key, value in
                (isIdentifier(key) ? key : literal(.string(key))) + ": " + literal(value)
            }.joined(separator: ", ") + " }"
        default:
            value.sourceLiteral
        }
    }
}

extension Value {
    fileprivate var isScalar: Bool {
        switch self {
        case .string, .number, .bool, .null: true
        default: false
        }
    }
}
