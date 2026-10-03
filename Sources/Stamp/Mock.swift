import Foundation

/// Builds sample values from a JSON Schema (the subset OpenAPI uses).
///
/// Examples and defaults in the schema win; otherwise the type, format,
/// enum and bounds decide, and property names like `email` or `city` pick
/// fitting fake data.
public enum Mock {
    public static func value(for schema: Value, using random: inout SeededRandom, name: String? = nil, depth: Int = 0) -> Value {
        guard case .object(let schema) = schema else {
            // A bare string names a fake member: mock("email").
            if case .string(let member) = schema { return Faker.value(member, using: &random) ?? .string(member) }
            return schema
        }
        guard depth < 12 else { return .null }

        if let example = schema["example"] { return example }
        if case .array(let examples)? = schema["examples"], let first = examples.first { return first }
        if let constant = schema["const"] { return constant }
        if case .array(let options)? = schema["enum"], !options.isEmpty { return random.pick(options) }
        for key in ["oneOf", "anyOf"] {
            if case .array(let options)? = schema[key], !options.isEmpty {
                return value(for: options[0], using: &random, name: name, depth: depth + 1)
            }
        }
        if case .array(let parts)? = schema["allOf"] {
            var merged = ObjectValue()
            for part in parts {
                if case .object(let object) = value(for: part, using: &random, name: name, depth: depth + 1) {
                    for (key, value) in object { merged[key] = value }
                }
            }
            return .object(merged)
        }

        var type = schema["type"]?.stringValue
        if case .array(let types)? = schema["type"] { type = types.compactMap(\.stringValue).first { $0 != "null" } }
        if type == nil {
            if schema["properties"] != nil { type = "object" } else if schema["items"] != nil { type = "array" }
        }

        switch type {
        case "object":
            var object = ObjectValue()
            // Name-like fields of one object describe one person.
            let person = Faker.person(using: &random).objectValue ?? ObjectValue()
            if case .object(let properties)? = schema["properties"] {
                for (key, propertySchema) in properties {
                    if let shared = personField(key, schema: propertySchema, person: person) {
                        object[key] = shared
                    } else {
                        object[key] = value(for: propertySchema, using: &random, name: key, depth: depth + 1)
                    }
                }
            }
            return .object(object)
        case "array":
            let minimum = Int(schema["minItems"]?.numberValue ?? 1)
            let maximum = Int(schema["maxItems"]?.numberValue ?? Double(max(minimum, 3)))
            let count = random.int(max(minimum, 0)...max(maximum, minimum, 0))
            let items = schema["items"] ?? ["type": "string"]
            return .array((0..<count).map { _ in value(for: items, using: &random, name: name.map(singular), depth: depth + 1) })
        case "integer":
            return .number(Double(integer(schema, name: name, using: &random)))
        case "number":
            let low = schema["minimum"]?.numberValue ?? 0
            let high = schema["maximum"]?.numberValue ?? max(low + 1000, 1000)
            return .number((low + (high - low) * Double(random.int(0...10_000)) / 10_000).rounded(toPlaces: 2))
        case "boolean":
            return .bool(random.int(0...1) == 1)
        default:
            return .string(string(schema, name: name, using: &random))
        }
    }

    private static func personField(_ key: String, schema: Value, person: ObjectValue) -> Value? {
        guard case .object(let schema) = schema, schema["example"] == nil, schema["enum"] == nil,
              (schema["type"]?.stringValue ?? "string") == "string"
        else { return nil }
        let lowered = key.lowercased().replacingOccurrences(of: "_", with: "")
        let field: String? = switch lowered {
        case "firstname", "givenname": "firstName"
        case "lastname", "surname", "familyname": "lastName"
        case "name", "fullname", "displayname": "name"
        case "email", "emailaddress": "email"
        case "username", "login", "handle": "username"
        case "phone", "phonenumber": "phone"
        case "avatar", "avatarurl", "picture": "avatar"
        default: nil
        }
        return field.flatMap { person[$0] }
    }

    private static func integer(_ schema: ObjectValue, name: String?, using random: inout SeededRandom) -> Int {
        let low = Int(schema["minimum"]?.numberValue ?? (name?.lowercased().hasSuffix("id") == true ? 1 : 0))
        let high = Int(schema["maximum"]?.numberValue ?? Double(name?.lowercased().contains("age") == true ? 90 : max(low + 1000, 1000)))
        return random.int(min(low, high)...max(low, high))
    }

    private static func string(_ schema: ObjectValue, name: String?, using random: inout SeededRandom) -> String {
        switch schema["format"]?.stringValue {
        case "email": return Faker.value("email", using: &random)!.interpolated
        case "uuid": return random.uuid()
        case "date-time": return Faker.value("date", using: &random)!.interpolated
        case "date": return String(Faker.value("date", using: &random)!.interpolated.prefix(10))
        case "uri", "url": return Faker.value("url", using: &random)!.interpolated
        case "hostname": return Faker.value("domain", using: &random)!.interpolated
        case "ipv4": return Faker.value("ipv4", using: &random)!.interpolated
        case "ipv6": return Faker.value("ipv6", using: &random)!.interpolated
        case "password": return "P@ss-" + random.uuid().prefix(8)
        default: break
        }

        let lowered = (name ?? "").lowercased()
        let hints: [(String, String)] = [
            ("email", "email"), ("firstname", "firstName"), ("lastname", "lastName"), ("username", "username"),
            ("phone", "phone"), ("avatar", "avatar"), ("city", "city"), ("countrycode", "countryCode"), ("country", "country"),
            ("street", "street"), ("zip", "zip"), ("postal", "zip"), ("company", "company"), ("title", "sentence"),
            ("description", "paragraph"), ("url", "url"), ("website", "url"), ("color", "color"), ("currency", "currency"),
            ("iban", "iban"), ("uuid", "uuid"), ("name", "name"), ("date", "date"), ("slug", "slug"),
        ]
        for (hint, member) in hints where lowered.contains(hint) {
            var text = Faker.value(member, using: &random)!.interpolated
            if hint == "title" { text = String(text.dropLast().prefix(60)) }
            return clamp(text, schema)
        }
        return clamp(Faker.value("words", using: &random)!.interpolated, schema)
    }

    private static func clamp(_ text: String, _ schema: ObjectValue) -> String {
        var text = text
        if let maxLength = schema["maxLength"]?.numberValue { text = String(text.prefix(Int(maxLength))) }
        if let minLength = schema["minLength"]?.numberValue, text.count < Int(minLength) {
            text += String(repeating: "x", count: Int(minLength) - text.count)
        }
        return text
    }

    private static func singular(_ name: String) -> String {
        name.hasSuffix("s") ? String(name.dropLast()) : name
    }
}
