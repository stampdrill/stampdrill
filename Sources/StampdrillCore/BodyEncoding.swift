import Foundation
import Stamp

/// Turns a rendered body into what goes over the wire for requests that
/// aren't sent as plain text: GraphQL operations and forms.
enum BodyEncoding {
    /// `GRAPHQL url` requests: the body is the query, optionally followed by a
    /// blank line and a JSON object of variables.
    ///
    ///     GRAPHQL https://countries.trevorblades.com/graphql
    ///
    ///     query Country($code: ID!) {
    ///       country(code: $code) { name capital }
    ///     }
    ///
    ///     { "code": "{{countryCode}}" }
    static func graphQL(_ text: String, line: Int) throws(ResolutionError) -> Data {
        var query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var variables: Value?
        if let split = query.range(of: "\n\n", options: .backwards) ?? query.range(of: "\r\n\r\n", options: .backwards) {
            let tail = query[split.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.hasPrefix("{") {
                do {
                    variables = try Value(json: tail)
                    query = String(query[..<split.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    throw ResolutionError("the GraphQL variables aren't valid JSON: \(error.message)", line: line)
                }
            }
        }
        guard !query.isEmpty else { throw ResolutionError("a GRAPHQL request needs a query in its body", line: line) }

        var payload: [(String, Value)] = [("query", .string(query))]
        if let variables { payload.append(("variables", variables)) }
        if let name = operationName(in: query) { payload.append(("operationName", .string(name))) }
        return Data(Value.object(ObjectValue(payload)).jsonString().utf8)
    }

    static func operationName(in query: String) -> String? {
        for keyword in ["query", "mutation", "subscription"] {
            guard let range = query.range(of: keyword + " ") else { continue }
            let name = query[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { return String(name) }
        }
        return nil
    }

    struct FormField {
        var name: String
        var value: String
        var file: URL?
    }

    /// `name = value` and `name = < ./file` lines, or nil when the body isn't shaped like a form.
    static func formFields(_ text: String, relativeTo directory: URL) -> [FormField]? {
        var fields: [FormField] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let equals = line.firstIndex(of: "=") else { return nil }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { return nil }
            if value.hasPrefix("< ") {
                let path = value.dropFirst(2).trimmingCharacters(in: .whitespaces)
                fields.append(FormField(name: name, value: path, file: resolvePath(path, in: directory)))
            } else {
                fields.append(FormField(name: name, value: value))
            }
        }
        return fields.isEmpty ? nil : fields
    }

    static func urlEncoded(_ fields: [FormField]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encode = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text }
        return Data(fields.map { "\(encode($0.name))=\(encode($0.value))" }.joined(separator: "&").utf8)
    }

    static func multipart(_ fields: [FormField], boundary: String, line: Int) throws(ResolutionError) -> Data {
        var data = Data()
        func append(_ text: String) { data.append(Data(text.utf8)) }
        for field in fields {
            append("--\(boundary)\r\n")
            if let file = field.file {
                guard let contents = try? Data(contentsOf: file) else {
                    throw ResolutionError("cannot read '\(field.value)' for form field '\(field.name)'", line: line)
                }
                let type = MediaType.forFileExtension(file.pathExtension) ?? "application/octet-stream"
                append("Content-Disposition: form-data; name=\"\(field.name)\"; filename=\"\(file.lastPathComponent)\"\r\n")
                append("Content-Type: \(type)\r\n\r\n")
                data.append(contents)
                append("\r\n")
            } else {
                append("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n\(field.value)\r\n")
            }
        }
        append("--\(boundary)--\r\n")
        return data
    }
}

/// A path from a file, relative to the file's folder unless it is absolute or starts with `~`.
func resolvePath(_ path: String, in directory: URL) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
    return URL(fileURLWithPath: directory.path, isDirectory: true).appendingPathComponent(expanded).standardizedFileURL
}
