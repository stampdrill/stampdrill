import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPField: Hashable, Codable, Sendable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// A request with every variable filled in, ready to send.
public struct ResolvedRequest: Hashable, Sendable {
    public var name: String
    public var method: String
    public var url: URL
    public var headers: [HTTPField]
    public var body: Data?
    public var timeout: TimeInterval
    public var followsRedirects: Bool
    public var allowsInsecureConnections: Bool
    /// Values that came from `secret(...)` and should not be shown.
    public var secrets: Set<String>
    /// Set when the request authenticates with OAuth 2 and still needs a token.
    public var tokenRequest: OAuth2TokenRequest?

    public init(
        name: String, method: String, url: URL, headers: [HTTPField] = [], body: Data? = nil,
        timeout: TimeInterval = 30, followsRedirects: Bool = true, allowsInsecureConnections: Bool = false,
        secrets: Set<String> = [], tokenRequest: OAuth2TokenRequest? = nil
    ) {
        self.name = name
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.followsRedirects = followsRedirects
        self.allowsInsecureConnections = allowsInsecureConnections
        self.secrets = secrets
        self.tokenRequest = tokenRequest
    }

    public func header(_ name: String) -> String? {
        headers.last { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var bodyText: String? {
        body.flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The URL as written, with a stdio MCP server shown as its command.
    public var target: String {
        MCPServerAddress.command(in: url).map { "stdio: " + $0 } ?? url.absoluteString
    }

    /// Replaces secret values with bullets.
    public func masked(_ text: String) -> String {
        secrets.sorted { $0.count > $1.count }.reduce(text) { result, secret in
            result.replacingOccurrences(of: secret, with: "••••••")
        }
    }
}

public struct HTTPResponse: Hashable, Sendable {
    public var url: URL
    public var statusCode: Int
    public var headers: [HTTPField]
    public var body: Data
    public var duration: TimeInterval

    public init(url: URL, statusCode: Int, headers: [HTTPField], body: Data, duration: TimeInterval) {
        self.url = url
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.duration = duration
    }

    public var reason: String {
        HTTPResponse.reasons[statusCode] ?? HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized
    }

    static let reasons: [Int: String] = [
        100: "Continue", 101: "Switching Protocols", 103: "Early Hints",
        200: "OK", 201: "Created", 202: "Accepted", 203: "Non-Authoritative Information", 204: "No Content",
        205: "Reset Content", 206: "Partial Content", 207: "Multi-Status",
        300: "Multiple Choices", 301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified",
        307: "Temporary Redirect", 308: "Permanent Redirect",
        400: "Bad Request", 401: "Unauthorized", 402: "Payment Required", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout", 409: "Conflict", 410: "Gone",
        411: "Length Required", 412: "Precondition Failed", 413: "Content Too Large", 414: "URI Too Long",
        415: "Unsupported Media Type", 416: "Range Not Satisfiable", 417: "Expectation Failed", 418: "I'm a Teapot",
        422: "Unprocessable Content", 423: "Locked", 425: "Too Early", 426: "Upgrade Required",
        428: "Precondition Required", 429: "Too Many Requests", 431: "Request Header Fields Too Large",
        451: "Unavailable For Legal Reasons",
        500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway", 503: "Service Unavailable",
        504: "Gateway Timeout", 505: "HTTP Version Not Supported", 507: "Insufficient Storage", 511: "Network Authentication Required",
        // STUN and TURN error codes that HTTP doesn't use.
        420: "Unknown Attribute", 437: "Allocation Mismatch", 438: "Stale Nonce", 440: "Address Family Not Supported",
        441: "Wrong Credentials", 442: "Unsupported Transport Protocol", 443: "Peer Address Family Mismatch",
        486: "Allocation Quota Reached", 508: "Insufficient Capacity",
    ]

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var contentType: String? { header("Content-Type") }

    public var isJSON: Bool {
        guard let type = contentType?.lowercased() else { return false }
        return type.contains("json")
    }

    public var bodyText: String {
        String(data: body, encoding: .utf8) ?? String(decoding: body, as: UTF8.self)
    }
}

public struct OAuth2TokenRequest: Hashable, Sendable {
    public var url: URL
    public var form: [HTTPField]

    /// Identifies tokens that can be reused for other requests.
    public var cacheKey: String {
        ([url.absoluteString] + form.filter { ["client_id", "scope", "audience", "username"].contains($0.name) }.map { "\($0.name)=\($0.value)" })
            .joined(separator: "&")
    }

    public var request: ResolvedRequest {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = form
            .map { "\($0.name)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        return ResolvedRequest(
            name: "oauth2 token",
            method: "POST",
            url: url,
            headers: [HTTPField("Content-Type", "application/x-www-form-urlencoded"), HTTPField("Accept", "application/json")],
            body: Data(body.utf8)
        )
    }
}
