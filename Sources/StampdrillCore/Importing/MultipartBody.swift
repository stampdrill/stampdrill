import Foundation

/// A `multipart/form-data` body as it was sent, back into fields.
///
/// Browsers copy such a request with the whole body as text and the original
/// boundary in the header. Sending that text again would be wrong once a value
/// changes, so it becomes form fields and the runtime builds a new body.
enum MultipartBody {
    /// The boundary of a `multipart/form-data` content type.
    static func boundary(in contentType: String) -> String? {
        guard let range = contentType.range(of: "boundary=", options: .caseInsensitive) else { return nil }
        var value = contentType[range.upperBound...].prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") { value = String(value.dropFirst().prefix { $0 != "\"" }) }
        return value.isEmpty ? nil : value
    }

    /// The parts of `text`, or nil when it isn't a body with that boundary.
    static func fields(in text: String, boundary: String) -> [ImportedField]? {
        let marker = "--" + boundary
        guard text.contains(marker) else { return nil }
        var fields: [ImportedField] = []
        for part in text.components(separatedBy: marker).dropFirst() {
            let body = part.first?.isNewline == true ? String(part.dropFirst()) : part
            if body.hasPrefix("--") { break }
            guard let separator = body.range(of: "\r\n\r\n") ?? body.range(of: "\n\n") else { continue }
            let headers = body[..<separator.lowerBound]
            var value = String(body[separator.upperBound...])
            while let last = value.last, last.isNewline { value.removeLast() }

            guard let disposition = headers.split(whereSeparator: \.isNewline).first(where: {
                $0.lowercased().hasPrefix("content-disposition:")
            }) else { continue }
            guard let name = parameter("name", in: String(disposition)) else { continue }
            if let file = parameter("filename", in: String(disposition)) {
                let path = file.hasPrefix("/") ? file : "./" + file
                fields.append(ImportedField(name: name, value: file.isEmpty ? value : path, isFile: !file.isEmpty))
            } else {
                fields.append(ImportedField(name: name, value: value))
            }
        }
        return fields.isEmpty ? nil : fields
    }

    /// `name="photo"` out of a Content-Disposition header.
    private static func parameter(_ name: String, in header: String) -> String? {
        guard let range = header.range(of: name + "=\"") else { return nil }
        return String(header[range.upperBound...].prefix { $0 != "\"" })
    }
}
