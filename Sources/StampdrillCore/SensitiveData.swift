import Foundation

/// Finds values that shouldn't be on screen by default: fields and headers
/// named like credentials, tokens that look like JWTs, and values that came
/// from `secret()`.
public enum SensitiveData {
    private static let sensitiveWords = [
        "token", "secret", "password", "passwd", "passphrase", "apikey", "accesskey", "privatekey",
        "credential", "authorization", "cookie", "sessionid", "session", "signature", "jwt", "bearer",
    ]
    private static let exactWords: Set<String> = ["pwd", "otp", "pin", "auth", "sid", "csrf", "xsrf"]
    /// Names that mention a credential but hold something about it, like `token_type`.
    private static let harmlessSuffixes = [
        "type", "expires", "expiresin", "expiresat", "expiry", "ttl", "length", "count", "url", "uri",
        "endpoint", "policy", "hint", "required", "enabled", "format", "scheme", "domain", "path", "samesite",
    ]

    /// Whether a field, header, variable or form name suggests a credential.
    public static func isSensitiveName(_ name: String) -> Bool {
        let normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !normalized.isEmpty else { return false }
        if exactWords.contains(normalized) { return true }
        guard sensitiveWords.contains(where: normalized.contains) else { return false }
        return !harmlessSuffixes.contains { normalized.hasSuffix($0) && normalized != $0 && !sensitiveWords.contains(normalized) }
    }

    /// Whether a value should be hidden whatever its name: a JWT, or a known secret.
    public static func isSensitiveValue(_ value: String, secrets: Set<String> = []) -> Bool {
        guard !value.isEmpty else { return false }
        if secrets.contains(value) { return true }
        return value.range(of: jwtPattern, options: .regularExpression) != nil
    }

    /// UTF-16 ranges of the values to hide in a body or transcript: JSON and
    /// XML fields, form and query parameters, header lines, bearer tokens, JWTs
    /// and the given secrets. Ranges are sorted and don't overlap.
    public static func ranges(in text: String, secrets: Set<String> = []) -> [NSRange] {
        let string = text as NSString
        guard string.length > 0, string.length < 2_000_000 else { return [] }
        var found: [NSRange] = []

        func named(_ pattern: NSRegularExpression, name: Int, value: Int) {
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
                let valueRange = match.range(at: value)
                guard valueRange.location != NSNotFound, valueRange.length > 0 else { continue }
                if isSensitiveName(string.substring(with: match.range(at: name))) { found.append(valueRange) }
            }
        }
        named(Patterns.jsonString, name: 1, value: 2)
        named(Patterns.jsonNumber, name: 1, value: 2)
        named(Patterns.form, name: 1, value: 2)
        named(Patterns.header, name: 1, value: 2)
        named(Patterns.xml, name: 1, value: 2)

        for pattern in [Patterns.jwt, Patterns.bearer] {
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
                found.append(match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range)
            }
        }
        for secret in secrets where secret.utf16.count >= 4 {
            var search = NSRange(location: 0, length: string.length)
            while true {
                let range = string.range(of: secret, options: .literal, range: search)
                guard range.location != NSNotFound else { break }
                found.append(range)
                search = NSRange(location: NSMaxRange(range), length: string.length - NSMaxRange(range))
            }
        }
        return merge(found)
    }

    private static func merge(_ ranges: [NSRange]) -> [NSRange] {
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static let jwtPattern = #"^eyJ[A-Za-z0-9_-]{4,}\.eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*$"#

    private enum Patterns {
        // "name": "value" (the value without its quotes)
        static let jsonString = try! NSRegularExpression(pattern: #""((?:[^"\\\n]|\\.){1,80})"\s*:\s*"((?:[^"\\\n]|\\.)+)""#)
        // "name": 123456
        static let jsonNumber = try! NSRegularExpression(pattern: #""((?:[^"\\\n]|\\.){1,80})"\s*:\s*(-?\d[\d.eE+-]*)"#)
        // name=value in forms, queries and cookies
        static let form = try! NSRegularExpression(pattern: #"(?:^|[?&;\s])([A-Za-z0-9_.\-\[\]]{1,80})=([^&;\s"'<>]+)"#, options: .anchorsMatchLines)
        // Name: value on a line of its own
        static let header = try! NSRegularExpression(pattern: #"^[ \t]*([A-Za-z0-9][A-Za-z0-9-]{0,80}):[ \t]*(\S.*?)[ \t]*$"#, options: .anchorsMatchLines)
        // <name>value</name>
        static let xml = try! NSRegularExpression(pattern: #"<([A-Za-z_][\w.:-]{0,80})(?:\s[^>]*)?>([^<]+)</\1>"#)
        static let jwt = try! NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_-]{4,}\.eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*"#)
        static let bearer = try! NSRegularExpression(pattern: #"\b(?:Bearer|Basic|Token)\s+([A-Za-z0-9._~+/=-]{8,})"#)
    }
}
