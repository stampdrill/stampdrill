/// How a request authenticates, declared with `@auth`.
///
///     @auth bearer {{token}}
///     @auth jwt {{idToken}}
///     @auth basic {{user}} {{password}}
///     @auth apikey X-API-Key {{key}}
///     @auth apikey api_key {{key}} query
///     @auth oauth2 client_credentials token_url={{idp}}/token client_id={{id}} client_secret={{secret}} scope="read write"
///     @auth none
///
/// `@auth` before the first request applies to the whole file; a request
/// can override it with its own, including `@auth none`.
public enum AuthScheme: Hashable, Sendable {
    public enum KeyLocation: String, Hashable, Sendable {
        case header
        case query
    }

    case none
    case bearer(Template)
    /// Sent like a bearer token; the app also shows the token's claims.
    case jwt(Template)
    case basic(username: Template, password: Template)
    case apiKey(name: String, value: Template, location: KeyLocation)
    case oauth2(OAuth2Settings)

    public var kindName: String {
        switch self {
        case .none: "none"
        case .bearer: "bearer"
        case .jwt: "jwt"
        case .basic: "basic"
        case .apiKey: "apikey"
        case .oauth2: "oauth2"
        }
    }
}

/// An OAuth 2 token endpoint the runner fetches a token from before sending.
public struct OAuth2Settings: Hashable, Sendable {
    public enum Grant: String, Hashable, Sendable, CaseIterable {
        case clientCredentials = "client_credentials"
        case password
    }

    public static let parameterNames = ["token_url", "client_id", "client_secret", "scope", "audience", "username", "password"]

    public var grant: Grant
    /// Keyed by the names in `parameterNames`.
    public var parameters: [String: Template]
}

enum AuthParser {
    /// Parses the text after `@auth`, which starts at `column`.
    static func parse(_ text: Substring, in line: String, number: Int) throws(Diagnostic) -> AuthScheme {
        let arguments = splitArguments(text)
        guard let kind = arguments.first else {
            throw .error("'@auth' needs a scheme: none, bearer, jwt, basic, apikey or oauth2", at: SourceRange(line: number, column: line.column(of: text), length: 1))
        }

        func template(_ index: Int) throws(Diagnostic) -> Template {
            let argument = arguments[index]
            return try Template.parse(unquoted(argument), line: number, column: line.column(of: argument) + (isQuoted(argument) ? 1 : 0))
        }

        func expect(_ counts: ClosedRange<Int>, _ usage: String) throws(Diagnostic) {
            guard counts.contains(arguments.count - 1) else {
                throw .error("expected '@auth \(usage)'", at: SourceRange(line: number, column: line.column(of: text), length: text.utf16.count))
            }
        }

        switch kind.lowercased() {
        case "none":
            try expect(0...0, "none")
            return .none
        case "bearer":
            try expect(1...1, "bearer <token>")
            return .bearer(try template(1))
        case "jwt":
            try expect(1...1, "jwt <token>")
            return .jwt(try template(1))
        case "basic":
            try expect(2...2, "basic <username> <password>")
            return .basic(username: try template(1), password: try template(2))
        case "apikey":
            try expect(2...3, "apikey <name> <value> [header|query]")
            var location = AuthScheme.KeyLocation.header
            if arguments.count == 4 {
                guard let parsed = AuthScheme.KeyLocation(rawValue: arguments[3].lowercased()) else {
                    throw .error("an API key goes in the 'header' or the 'query'", at: SourceRange(line: number, column: line.column(of: arguments[3]), length: arguments[3].utf16.count))
                }
                location = parsed
            }
            return .apiKey(name: unquoted(arguments[1]), value: try template(2), location: location)
        case "oauth2":
            guard arguments.count >= 2, let grant = OAuth2Settings.Grant(rawValue: arguments[1].lowercased()) else {
                throw .error("expected '@auth oauth2 client_credentials|password token_url=… client_id=…'", at: SourceRange(line: number, column: line.column(of: text), length: text.utf16.count))
            }
            var parameters: [String: Template] = [:]
            for argument in arguments.dropFirst(2) {
                guard let equals = argument.firstIndex(of: "="), OAuth2Settings.parameterNames.contains(String(argument[..<equals])) else {
                    throw .error("unknown oauth2 setting '\(argument.prefix { $0 != "=" })'; use \(OAuth2Settings.parameterNames.joined(separator: ", "))", at: SourceRange(line: number, column: line.column(of: argument), length: argument.utf16.count))
                }
                let value = argument[argument.index(after: equals)...]
                parameters[String(argument[..<equals])] = try Template.parse(unquoted(value), line: number, column: line.column(of: value) + (isQuoted(value) ? 1 : 0))
            }
            let required = grant == .password ? ["token_url", "client_id", "username", "password"] : ["token_url", "client_id"]
            if let missing = required.first(where: { parameters[$0] == nil }) {
                throw .error("oauth2 \(grant.rawValue) needs '\(missing)'", at: SourceRange(line: number, column: line.column(of: text), length: text.utf16.count))
            }
            return .oauth2(OAuth2Settings(grant: grant, parameters: parameters))
        default:
            throw .error("unknown auth scheme '\(kind)'", at: SourceRange(line: number, column: line.column(of: kind), length: kind.utf16.count))
        }
    }

    /// Splits on whitespace, keeping `{{ ... }}` and quoted text together.
    static func splitArguments(_ text: Substring) -> [Substring] {
        var arguments: [Substring] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index] == " " || text[index] == "\t" { index = text.index(after: index) }
            guard index < text.endIndex else { break }

            let start = index
            var depth = 0
            var quote: Character?
            while index < text.endIndex {
                let character = text[index]
                if let q = quote {
                    if character == q { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if text[index...].hasPrefix("{{") {
                    depth += 1
                    index = text.index(after: index)
                } else if depth > 0, text[index...].hasPrefix("}}") {
                    depth -= 1
                    index = text.index(after: index)
                } else if depth == 0, character == " " || character == "\t" {
                    break
                }
                index = text.index(after: index)
            }
            arguments.append(text[start..<min(index, text.endIndex)])
        }
        return arguments
    }

    private static func isQuoted(_ text: Substring) -> Bool {
        text.count >= 2 && (text.first == "\"" || text.first == "'") && text.last == text.first
    }

    private static func unquoted(_ text: Substring) -> String {
        isQuoted(text) ? String(text.dropFirst().dropLast()) : String(text)
    }
}
