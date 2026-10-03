import Foundation

public enum CurlExporter {
    /// A `curl` command that sends the same request, one option per line.
    public static func command(for request: ResolvedRequest, masked: Bool = false) -> String {
        let mask = { (text: String) in masked ? request.masked(text) : text }
        var parts = ["curl"]
        if request.method != "GET" || request.body != nil && request.method == "GET" {
            parts.append("--request \(request.method)")
        }
        parts.append(quote(mask(request.url.absoluteString)))
        for header in request.headers {
            parts.append("--header " + quote(mask("\(header.name): \(header.value)")))
        }
        if let body = request.body, !body.isEmpty {
            if let text = String(data: body, encoding: .utf8) {
                parts.append("--data-raw " + quote(mask(text)))
            } else {
                parts.append("--data-binary @body.bin")
            }
        }
        if !request.followsRedirects {
            parts.append("--max-redirs 0")
        } else {
            parts.append("--location")
        }
        if request.allowsInsecureConnections { parts.append("--insecure") }
        parts.append("--max-time \(Int(request.timeout.rounded(.up)))")
        return parts.joined(separator: " \\\n  ")
    }

    /// Single-quotes for POSIX shells.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
