import Foundation
import Stamp

/// A form for a tool's `inputSchema` or a prompt's arguments: one field per
/// property, typed from the JSON Schema, turned back into arguments.
public struct MCPArgumentForm: Sendable, Equatable {
    public struct Field: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case string
            case number
            case integer
            case boolean
            case choice([String])
            /// Text, or JSON when it is typed as an array or object: `anyOf` a string and something else.
            case textOrJSON
            /// Arrays, objects and anything else, typed as JSON.
            case json
        }

        public var name: String
        public var title: String?
        public var description: String?
        public var kind: Kind
        public var isRequired: Bool
        /// Text the field starts with: the schema's default, as it would be typed.
        public var initialText: String

        public var id: String { name }

        /// A short hint of the expected type, such as `number` or `array of string`.
        public var typeHint: String?
    }

    public var fields: [Field]

    public init(fields: [Field]) {
        self.fields = fields
    }

    /// Fields for a JSON Schema object. Properties keep the schema's order.
    public init(schema: Value?) {
        let object = schema?.objectValue ?? ObjectValue()
        let required = Set((object["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        var fields: [Field] = []
        for (name, property) in object["properties"]?.objectValue ?? ObjectValue() {
            let property = Self.simplified(property.objectValue ?? ObjectValue())
            let kind = Self.kind(of: property)
            var initial = ""
            if let value = property["default"] {
                initial = switch (kind, value) {
                case (.json, _): value.jsonString()
                case (_, .string(let text)): text
                default: value.interpolated
                }
            }
            fields.append(Field(
                name: name,
                title: property["title"]?.stringValue,
                description: property["description"]?.stringValue,
                kind: kind,
                isRequired: required.contains(name),
                initialText: initial,
                typeHint: Self.typeHint(of: property, kind: kind)
            ))
        }
        self.fields = fields
    }

    /// Prompt arguments: `[{ name, description, required }]`, all strings.
    public init(promptArguments: [Value]) {
        fields = promptArguments.compactMap { argument in
            guard let object = argument.objectValue, let name = object["name"]?.stringValue else { return nil }
            return Field(
                name: name, title: object["title"]?.stringValue, description: object["description"]?.stringValue,
                kind: .string, isRequired: object["required"] == .bool(true), initialText: "", typeHint: nil
            )
        }
    }

    public struct Problem: Error, Equatable, Sendable, CustomStringConvertible {
        public var field: String
        public var message: String
        public var description: String { "\(field): \(message)" }

        public init(field: String, message: String) {
            self.field = field
            self.message = message
        }
    }

    /// Arguments from what was typed, keyed by field name. Empty optional
    /// fields are left out; a boolean is sent when it was set.
    public func arguments(texts: [String: String], flags: [String: Bool]) throws(Problem) -> ObjectValue {
        var arguments = ObjectValue()
        for field in fields {
            if case .boolean = field.kind {
                if let flag = flags[field.name] {
                    arguments[field.name] = .bool(flag)
                } else if field.isRequired {
                    arguments[field.name] = .bool(false)
                }
                continue
            }
            let text = texts[field.name] ?? field.initialText
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if field.isRequired, field.kind != .string {
                    throw Problem(field: field.name, message: "is required")
                }
                if field.isRequired { arguments[field.name] = .string(text) }
                continue
            }
            switch field.kind {
            case .string, .choice:
                arguments[field.name] = .string(text)
            case .textOrJSON:
                if trimmed.first == "[" || trimmed.first == "{", let value = try? Value(json: trimmed) {
                    arguments[field.name] = value
                } else {
                    arguments[field.name] = .string(text)
                }
            case .number:
                guard let number = Double(trimmed) else { throw Problem(field: field.name, message: "must be a number") }
                arguments[field.name] = .number(number)
            case .integer:
                guard let number = Double(trimmed), number == number.rounded() else {
                    throw Problem(field: field.name, message: "must be a whole number")
                }
                arguments[field.name] = .number(number)
            case .json:
                do {
                    arguments[field.name] = try Value(json: trimmed)
                } catch {
                    throw Problem(field: field.name, message: "must be JSON, such as [1, 2] or {\"key\": \"value\"}")
                }
            case .boolean:
                break
            }
        }
        return arguments
    }

    /// What was typed for each field, from arguments: the way back from the JSON editor.
    public func texts(from arguments: ObjectValue) -> (texts: [String: String], flags: [String: Bool]) {
        var texts: [String: String] = [:]
        var flags: [String: Bool] = [:]
        for field in fields {
            guard let value = arguments[field.name] else { continue }
            switch (field.kind, value) {
            case (.boolean, .bool(let flag)): flags[field.name] = flag
            case (.json, _), (.textOrJSON, .array), (.textOrJSON, .object): texts[field.name] = value.jsonString()
            case (_, .string(let text)): texts[field.name] = text
            default: texts[field.name] = value.interpolated
            }
        }
        return (texts, flags)
    }

    // MARK: Schema

    /// `anyOf: [{ type: string }, { type: null }]` and `type: ["string", "null"]`,
    /// as optional fields usually come out of Pydantic and Zod, read as `string`.
    static func simplified(_ property: ObjectValue) -> ObjectValue {
        var property = property
        for key in ["anyOf", "oneOf"] {
            guard let options = property[key]?.arrayValue else { continue }
            let real = options.filter { $0.objectValue?["type"] != .string("null") }
            if real.count == 1, let only = real[0].objectValue {
                for (name, value) in only where property[name] == nil { property[name] = value }
                property[key] = nil
            }
        }
        if case .array(let types)? = property["type"] {
            let real = types.filter { $0 != .string("null") }
            if real.count == 1 { property["type"] = real[0] }
        }
        return property
    }

    static func kind(of property: ObjectValue) -> Field.Kind {
        if let options = property["enum"]?.arrayValue, !options.isEmpty, options.allSatisfy({ $0.stringValue != nil }) {
            return .choice(options.compactMap(\.stringValue))
        }
        if let options = property["anyOf"]?.arrayValue ?? property["oneOf"]?.arrayValue {
            let types = options.compactMap { $0.objectValue?["type"]?.stringValue }
            return types.contains("string") ? .textOrJSON : .json
        }
        switch property["type"]?.stringValue {
        case "string": return .string
        case "number": return .number
        case "integer": return .integer
        case "boolean": return .boolean
        case nil where property["const"]?.stringValue != nil: return .string
        default: return .json
        }
    }

    static func typeHint(of property: ObjectValue, kind: Field.Kind) -> String? {
        switch kind {
        case .string:
            return property["format"]?.stringValue
        case .number, .integer, .boolean, .choice:
            return nil
        case .textOrJSON:
            return "text, or JSON"
        case .json:
            if property["type"]?.stringValue == "array" {
                let items = property["items"]?.objectValue?["type"]?.stringValue
                return items.map { "array of \($0)" } ?? "array"
            }
            return property["type"]?.stringValue ?? "JSON"
        }
    }
}

/// The variables of a resource template, such as `{owner}` and `{+path}`, and the URI they make.
public enum MCPURITemplate {
    public static func variables(in template: String) -> [String] {
        var names: [String] = []
        for expression in expressions(in: template) {
            for name in expression.names where !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Expands the simple forms: `{name}` and `{+name}`, plus `{?a,b}` and `{/name}`.
    public static func expand(_ template: String, with values: [String: String]) -> String {
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            result += rest[..<open]
            let body = rest[rest.index(after: open)..<close]
            let expression = Expression(body)
            let filled = expression.names.compactMap { name in values[name].flatMap { $0.isEmpty ? nil : (name, $0) } }
            switch expression.operator {
            case "?":
                if !filled.isEmpty { result += "?" + filled.map { "\($0.0)=\(encode($0.1, reserved: false))" }.joined(separator: "&") }
            case "/":
                result += filled.map { "/" + encode($0.1, reserved: false) }.joined()
            case "+", "#":
                if !filled.isEmpty { result += (expression.operator == "#" ? "#" : "") + filled.map { encode($0.1, reserved: true) }.joined(separator: ",") }
            default:
                result += filled.map { encode($0.1, reserved: false) }.joined(separator: ",")
            }
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    private struct Expression {
        var `operator`: Character?
        var names: [String]

        init(_ body: Substring) {
            var body = body
            if let first = body.first, "+#./;?&".contains(first) {
                `operator` = first
                body = body.dropFirst()
            }
            names = body.split(separator: ",").map { String($0.prefix { $0 != ":" && $0 != "*" }) }
        }
    }

    private static func expressions(in template: String) -> [Expression] {
        var found: [Expression] = []
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            found.append(Expression(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return found
    }

    private static func encode(_ value: String, reserved: Bool) -> String {
        var allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        if reserved { allowed.formUnion(CharacterSet(charactersIn: ":/?#[]@!$&'()*+,;=")) }
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
