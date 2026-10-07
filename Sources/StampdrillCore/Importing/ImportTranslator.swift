import Foundation
import Stamp

/// Variable names and placeholders from other tools, turned into Stamp.
///
/// Names become identifiers (`api-key` → `apiKey`) the same way everywhere in
/// one import, so a collection and its environments keep agreeing.
struct ImportTranslator {
    private var identifiers: [String: String] = [:]
    private(set) var used: Set<String> = []
    private(set) var warnings: [String] = []

    /// Names a variable must not take, because scripts and templates already mean something by them.
    static let reserved: Set<String> = Scope.intrinsicNames
        .union(Builtins.standard.keys)
        .union(["true", "false", "null", "env", "fake", "secret", "response", "status", "headers", "body", "text", "time", "size",
                "message", "data", "and", "or", "not", "contains", "matches", "server", "tools", "resources", "prompts", "notifications"])

    mutating func identifier(_ original: String) -> String {
        let original = original.trimmingCharacters(in: .whitespaces)
        if let known = identifiers[original] { return known }
        let name = uniqueName(original)
        identifiers[original] = name
        return name
    }

    /// A fresh name nothing in the import uses yet.
    mutating func uniqueName(_ preferred: String, camelCase: Bool = false) -> String {
        var base = preferred.stampIdentifierKeepingName ?? "value"
        if camelCase {
            // `Cookie` → `cookie`, `X-Api-Key` → `xApiKey`, `clientSecret` stays.
            base = base == preferred ? base.prefix(1).lowercased() + base.dropFirst() : (preferred.stampIdentifier ?? base)
        }
        if Self.reserved.contains(base) { base += "Value" }
        var name = base
        var counter = 2
        while used.contains(name) {
            name = Self.numbered(base, counter)
            counter += 1
        }
        used.insert(name)
        return name
    }

    /// `name2`, or `request1_2` when the name already ends in a digit.
    static func numbered(_ base: String, _ counter: Int) -> String {
        base.last?.isNumber == true ? "\(base)_\(counter)" : "\(base)\(counter)"
    }

    /// Names the workspace already uses, so imported ones never take them over.
    mutating func reserve(_ names: some Sequence<String>) {
        used.formUnion(names)
    }

    mutating func warn(_ message: String) {
        if !warnings.contains(message) { warnings.append(message) }
    }

    // MARK: Templates

    /// `{{name}}`, `{{$guid}}` and `{{process.env.NAME}}`, as Postman and Bruno write them.
    mutating func mustache(_ text: String) -> String {
        var names = self
        let result = Self.replacingBraces(in: text) { inner in
            if inner.hasPrefix("$") { return names.dynamic(String(inner.dropFirst())) }
            if inner.hasPrefix("process.env.") { return "getenv(\(Value.string(String(inner.dropFirst(12))).sourceLiteral))" }
            return names.identifier(inner)
        }
        self = names
        return result
    }

    /// Replaces the inside of every `{{ … }}`; nil keeps it as literal text.
    static func replacingBraces(in text: String, _ transform: (String) -> String?) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            result += escapeStray(rest[..<open.lowerBound])
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                rest = rest[open.lowerBound...]
                break
            }
            let inner = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty, let expression = transform(inner) {
                result += "{{" + expression + "}}"
            } else {
                result += "\\{{" + rest[open.upperBound..<close.upperBound]
            }
            rest = rest[close.upperBound...]
        }
        return result + escapeStray(rest)
    }

    private static func escapeStray(_ text: Substring) -> String {
        text.replacingOccurrences(of: "{{", with: "\\{{")
    }

    /// Postman's and Bruno's `$random…` placeholders, as Stamp expressions.
    mutating func dynamic(_ name: String) -> String? {
        let fake: [String: String] = [
            "randomFirstName": "firstName", "randomLastName": "lastName", "randomFullName": "name", "randomUserName": "username",
            "randomEmail": "email", "randomExampleEmail": "email", "randomPhoneNumber": "phone", "randomCity": "city",
            "randomCountry": "country", "randomCountryCode": "countryCode", "randomStreetAddress": "street",
            "randomCompanyName": "company", "randomJobTitle": "jobTitle", "randomPrice": "price", "randomCurrencyCode": "currency",
            "randomColor": "color", "randomWord": "word", "randomWords": "words", "randomLoremWord": "word",
            "randomLoremWords": "words", "randomLoremSentence": "sentence", "randomLoremParagraph": "paragraph",
            "randomLoremSlug": "slug", "randomUrl": "url", "randomDomainName": "domain", "randomIP": "ipv4", "randomIPV6": "ipv6",
            "randomMACAddress": "mac", "randomUserAgent": "userAgent", "randomDateFuture": "futureDate", "randomDatePast": "pastDate",
            "randomDateRecent": "pastDate", "randomAvatarImage": "avatar", "randomProduct": "product", "randomProductName": "product",
            "randomBankAccountIban": "iban", "randomLatitude": "latitude", "randomLongitude": "longitude",
        ]
        switch name {
        case "guid", "randomUUID", "uuid": return "uuid()"
        case "timestamp": return "timestamp()"
        case "isoTimestamp": return "now()"
        case "randomInt": return "randomInt(0, 1000)"
        case "randomBoolean": return "oneOf([true, false])"
        default:
            if let member = fake[name] { return "fake." + member }
            warn("{{$\(name)}} has no equivalent; it was kept as text")
            return nil
        }
    }

    // MARK: Expressions

    /// A template as an expression: `{{base}}/v1` → `base + "/v1"`, for variables in `vars` blocks.
    static func expression(forTemplate text: String) -> String {
        guard let template = try? Template.parse(text), !template.parts.isEmpty else {
            return Value.string(text).sourceLiteral
        }
        let pieces = template.parts.map { part -> String in
            switch part {
            case .text(let literal): Value.string(literal).sourceLiteral
            case .expression(_, let source, _): template.parts.count == 1 ? source : "(\(source))"
            case .variable(let name): name
            }
        }
        if pieces.count > 1, case .expression = template.parts[0], case .expression = template.parts[1] {
            // Two expressions next to each other are text, not a sum.
            return "\"\" + " + pieces.joined(separator: " + ")
        }
        return pieces.joined(separator: " + ")
    }
}
