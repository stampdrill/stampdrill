import Foundation

/// A request and its response written out as plain text, for keeping,
/// diffing and reading in any editor.
///
///     ### Log in · 2026-09-13 12:43:48 · 200 OK · 132 ms
///     POST https://dummyjson.com/auth/login
///     Content-Type: application/json
///
///     { "username": "emilys" }
///
///     <<< HTTP 200 OK
///     Content-Type: application/json
///
///     {
///       "id": 1
///     }
public enum ExchangeFile {
    public static func text(for result: RunResult, title: String? = nil, masksSecrets: Bool = true) -> String {
        var lines: [String] = []
        let timestamp = result.startedAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.space))
        var heading = "### \(title ?? result.reference.name) · \(timestamp)"
        if let response = result.response {
            heading += " · \(response.statusCode) \(response.reason) · \(Int((response.duration * 1000).rounded())) ms"
        }
        lines.append(heading)

        let mask = { (text: String) in masksSecrets ? (result.request?.masked(text) ?? text) : text }

        if let request = result.request {
            lines.append("\(request.method) \(mask(request.target))")
            for header in request.headers { lines.append("\(header.name): \(mask(header.value))") }
            if let body = request.body, !body.isEmpty {
                lines.append("")
                let kind = ContentKind.detect(contentType: request.header("Content-Type"), body: body)
                switch kind {
                case .json: lines.append(mask(JSONFormatter.prettyPrinted(String(decoding: body, as: UTF8.self)) ?? String(decoding: body, as: UTF8.self)))
                case _ where kind.isTextual: lines.append(mask(String(decoding: body, as: UTF8.self)))
                default: lines.append("<\(body.count) bytes of \(kind.rawValue)>")
                }
            }
        }

        lines.append("")
        if let response = result.response {
            lines.append("<<< HTTP \(response.statusCode) \(response.reason)")
            for header in response.headers { lines.append("\(header.name): \(header.value)") }
            lines.append("")
            if let formatted = response.formattedBody {
                lines.append(formatted)
            } else if response.body.isEmpty {
                lines.append("<empty body>")
            } else {
                lines.append("<\(response.body.count) bytes of \(response.kind.rawValue)>")
            }
        } else if let error = result.error {
            lines.append("<<< failed: \(mask(error))")
        }

        if !result.assertions.isEmpty {
            lines.append("")
            for assertion in result.assertions {
                let mark = assertion.passed ? "✓" : "✗"
                lines.append("# \(mark) \(assertion.source)" + (assertion.message.map { " — \($0)" } ?? ""))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `<request name>/<timestamp>.<status>.http` under `directory`.
    public static func location(for result: RunResult, in directory: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let status = result.response.map { String($0.statusCode) } ?? "failed"
        let file = (result.reference.path as NSString).deletingPathExtension
        return directory
            .appendingPathComponent(file, isDirectory: true)
            .appendingPathComponent(result.reference.name, isDirectory: true)
            .appendingPathComponent("\(formatter.string(from: result.startedAt)).\(status).http")
    }

    @discardableResult
    public static func save(_ result: RunResult, in directory: URL, title: String? = nil) throws -> URL {
        let url = location(for: result, in: directory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text(for: result, title: title).utf8).write(to: url, options: .atomic)
        return url
    }
}
