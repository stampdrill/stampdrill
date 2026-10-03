import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// What a body contains, decided from its media type and, when that is
/// missing or generic, from the first bytes.
public enum ContentKind: String, Sendable, CaseIterable {
    case json
    case xml
    case html
    case image
    case svg
    case pdf
    case form
    case csv
    case text
    case binary
    case empty

    public static func detect(contentType: String?, body: Data, url: URL? = nil) -> ContentKind {
        guard !body.isEmpty else { return .empty }
        let mediaType = contentType?
            .split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces)
            .lowercased() ?? ""

        // Raw file hosts often serve CSV as plain text; the file name says what it is.
        if ["", "text/plain", "application/octet-stream"].contains(mediaType),
           let ext = url?.pathExtension.lowercased(), ext == "csv" || ext == "tsv"
        {
            return .csv
        }

        switch mediaType {
        case "text/csv", "application/csv", "text/tab-separated-values": return .csv
        case "application/json", "text/json": return .json
        case _ where mediaType.hasSuffix("+json"): return .json
        case "image/svg+xml": return .svg
        case "text/html", "application/xhtml+xml": return .html
        case "application/xml", "text/xml": return .xml
        case _ where mediaType.hasSuffix("+xml"): return .xml
        case "application/pdf": return .pdf
        case "application/x-www-form-urlencoded": return .form
        case _ where mediaType.hasPrefix("image/"): return .image
        case _ where mediaType.hasPrefix("text/"): return .text
        case "application/javascript", "application/x-javascript", "application/graphql", "application/yaml", "application/x-yaml":
            return .text
        default:
            return sniff(body)
        }
    }

    static func sniff(_ body: Data) -> ContentKind {
        let head = [UInt8](body.prefix(512))
        if head.starts(with: [0x25, 0x50, 0x44, 0x46]) { return .pdf }                         // %PDF
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) || head.starts(with: [0xFF, 0xD8, 0xFF])  // PNG, JPEG
            || head.starts(with: [0x47, 0x49, 0x46, 0x38])                                        // GIF
            || (head.count > 12 && head[0...3] == [0x52, 0x49, 0x46, 0x46] && head[8...11] == [0x57, 0x45, 0x42, 0x50]) // WEBP
        {
            return .image
        }
        guard let text = String(bytes: head, encoding: .utf8) ?? String(data: body.prefix(1024), encoding: .utf8) else {
            return head.contains(0) ? .binary : .text
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return JSONFormatter.minified(String(decoding: body, as: UTF8.self)) != nil ? .json : .text }
        if trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html") { return .html }
        if trimmed.hasPrefix("<svg") || (trimmed.hasPrefix("<?xml") && trimmed.contains("<svg")) { return .svg }
        if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<") { return .xml }
        return head.contains(0) ? .binary : .text
    }

    public var isTextual: Bool {
        switch self {
        case .json, .xml, .html, .svg, .form, .csv, .text: true
        case .image, .pdf, .binary, .empty: false
        }
    }

    /// A file extension for saving a body of this kind.
    public static func fileExtension(contentType: String?, kind: ContentKind) -> String {
        if let mediaType = contentType?.split(separator: ";").first.map({ String($0).trimmingCharacters(in: .whitespaces) }),
           let ext = MediaType.fileExtension(for: mediaType)
        {
            return ext
        }
        switch kind {
        case .json: return "json"
        case .xml: return "xml"
        case .html: return "html"
        case .svg: return "svg"
        case .pdf: return "pdf"
        case .csv: return "csv"
        case .form, .text, .empty: return "txt"
        case .image: return "png"
        case .binary: return "bin"
        }
    }
}

public enum XMLFormatter {
    public static func prettyPrinted(_ text: String) -> String? {
        guard let document = try? XMLDocument(xmlString: text, options: [.nodePreserveWhitespace]) else { return nil }
        let pretty = document.xmlString(options: [.nodePrettyPrint])
        return pretty.isEmpty ? nil : pretty
    }
}

extension HTTPResponse {
    public var kind: ContentKind {
        ContentKind.detect(contentType: contentType, body: body, url: url)
    }

    /// The body laid out for reading: JSON and XML indented, text as is.
    public var formattedBody: String? {
        switch kind {
        case .json: JSONFormatter.prettyPrinted(bodyText) ?? bodyText
        case .xml, .svg: XMLFormatter.prettyPrinted(bodyText) ?? bodyText
        case .html, .text, .form, .csv: bodyText
        case .image, .pdf, .binary, .empty: nil
        }
    }

    /// A file name for saving the body, from Content-Disposition or the URL.
    public var suggestedFileName: String {
        if let disposition = header("Content-Disposition"),
           let range = disposition.range(of: "filename=")
        {
            let name = disposition[range.upperBound...]
                .split(separator: ";").first.map(String.init)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) ?? ""
            if !name.isEmpty { return (name as NSString).lastPathComponent }
        }
        let ext = ContentKind.fileExtension(contentType: contentType, kind: kind)
        let last = url.lastPathComponent
        let base = last.isEmpty || last == "/" ? (url.host ?? "response") : last
        return (base as NSString).pathExtension.isEmpty ? base + "." + ext : base
    }
}

public enum HexDump {
    /// Classic offset / hex / ASCII lines, limited to `limit` bytes.
    public static func format(_ data: Data, limit: Int = 64 * 1024) -> String {
        var lines: [String] = []
        let bytes = [UInt8](data.prefix(limit))
        stride(from: 0, to: bytes.count, by: 16).forEach { offset in
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = row.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = row.map { (0x20...0x7E).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            lines.append(String(format: "%08x  ", offset) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + ascii)
        }
        if data.count > limit { lines.append("… \(data.count - limit) more bytes") }
        return lines.joined(separator: "\n")
    }
}
