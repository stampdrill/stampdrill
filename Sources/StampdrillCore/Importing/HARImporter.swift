import Foundation
import Stamp

/// HTTP Archive files, as browsers' developer tools and proxies save them.
///
/// Only API calls are kept: scripts, stylesheets, images, fonts and CORS
/// preflights are left out, and so are the headers a browser adds by itself.
/// Requests are grouped by host, and each host becomes a variable.
enum HARImporter {
    private static let droppedHeaders: Set<String> = [
        "host", "content-length", "connection", "accept-encoding", "accept-language", "user-agent", "referer", "origin",
        "pragma", "cache-control", "upgrade-insecure-requests", "priority", "te", "dnt", "if-none-match", "if-modified-since",
    ]
    private static let assetExtensions: Set<String> = [
        "js", "mjs", "css", "png", "jpg", "jpeg", "gif", "svg", "webp", "avif", "ico", "woff", "woff2", "ttf", "otf", "eot", "map", "mp4", "webm", "mp3",
    ]

    static func collection(_ object: ObjectValue, translator: inout ImportTranslator) throws -> ImportedCollection {
        let log = object["log"]?.objectValue ?? ObjectValue()
        // A single HAR request, as some tools copy one, stands for an archive with one entry.
        let entries = object["log"] == nil && object["url"] != nil ? [ObjectValue([("request", .object(object))])] : log.objects("entries")
        let creator = log["creator"]?.objectValue?.string("name")
        var collection = ImportedCollection(name: creator.map { "Recorded with \($0)" } ?? "Recorded requests", format: Importer.Format.har.rawValue)

        var hosts: [(origin: String, variable: String, folder: ImportedFolder)] = []
        var seen = Set<String>()
        var skipped = 0

        for entry in entries {
            guard let request = entry["request"]?.objectValue, let rawURL = request.string("url"),
                  let components = URLComponents(string: rawURL), let scheme = components.scheme, let host = components.host
            else { continue }
            let method = (request.string("method") ?? "GET").uppercased()
            guard isAPICall(entry, method: method, path: components.path) else {
                skipped += 1
                continue
            }
            let postText = request["postData"]?.objectValue?.string("text") ?? ""
            guard seen.insert(method + " " + rawURL + " " + postText).inserted else { continue }

            let origin = "\(scheme)://\(host)" + (components.port.map { ":\($0)" } ?? "")
            let index: Int
            if let existing = hosts.firstIndex(where: { $0.origin == origin }) {
                index = existing
            } else {
                let variable = translator.uniqueName(hosts.isEmpty ? "baseUrl" : host)
                hosts.append((origin, variable, ImportedFolder(name: host)))
                index = hosts.count - 1
            }

            var pathAndQuery = String(rawURL.dropFirst(origin.count))
            if components.query == nil {
                let query = request.objects("queryString").compactMap { item -> String? in
                    guard let name = item.string("name") else { return nil }
                    let value = item.string("value") ?? ""
                    let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&="))
                    return "\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
                }
                if !query.isEmpty { pathAndQuery += "?" + query.joined(separator: "&") }
            }
            var imported = ImportedRequest(title: requestTitle(method: method, url: rawURL), method: method, url: "{{\(hosts[index].variable)}}" + translator.escapingBraces(pathAndQuery))
            for header in request.objects("headers") {
                guard let name = header.string("name"), !name.hasPrefix(":") else { continue }
                let lower = name.lowercased()
                if droppedHeaders.contains(lower) || lower.hasPrefix("sec-") { continue }
                imported.headers.append(ImportedField(name: name, value: translator.escapingBraces(header.string("value") ?? "")))
            }
            let cookies = request.objects("cookies").compactMap { cookie -> String? in
                guard let name = cookie.string("name") else { return nil }
                return "\(name)=\(cookie.string("value") ?? "")"
            }
            if !cookies.isEmpty, !imported.headers.contains(where: { $0.name.caseInsensitiveCompare("Cookie") == .orderedSame }) {
                imported.headers.append(ImportedField(name: "Cookie", value: translator.escapingBraces(cookies.joined(separator: "; "))))
            }
            imported.body = body(request["postData"]?.objectValue, headers: &imported.headers, translator: translator)
            if let status = entry["response"]?.objectValue?["status"]?.numberValue, (200..<300).contains(status) {
                imported.script = ["assert status == \(Int(status))"]
            }
            if hosts[index].folder.requests.contains(where: { $0.title == imported.title }) {
                imported.title += " (\(hosts[index].folder.requests.count + 1))"
            }
            hosts[index].folder.requests.append(imported)
        }

        guard !hosts.isEmpty else {
            throw Importer.Failure(message: "The HAR file has no API requests\(skipped > 0 ? " (\(skipped) scripts, stylesheets, images and the like were left out)" : "")")
        }
        if skipped > 0 {
            collection.warnings.append("\(skipped) requests for pages, scripts, stylesheets, images and fonts were left out")
        }
        for host in hosts {
            collection.variables.append(ImportedVariable(name: host.variable, value: translator.escapingBraces(host.origin)))
        }
        if hosts.count == 1 {
            collection.name = hosts[0].folder.name
            collection.root.requests = hosts[0].folder.requests
        } else {
            collection.root.folders = hosts.map(\.folder)
        }
        return collection
    }

    /// XHR and fetch calls when the browser recorded the type; otherwise anything that isn't an asset.
    private static func isAPICall(_ entry: ObjectValue, method: String, path: String) -> Bool {
        if method == "OPTIONS" { return false }
        if let type = entry.string("_resourceType")?.lowercased() {
            return type == "xhr" || type == "fetch" || (type == "document" && method != "GET")
        }
        let ext = (path as NSString).pathExtension.lowercased()
        if assetExtensions.contains(ext) { return false }
        let mime = entry["response"]?.objectValue?["content"]?.objectValue?.string("mimeType")?.lowercased() ?? ""
        return !(mime.hasPrefix("image/") || mime.hasPrefix("font/") || mime.contains("css") || mime.contains("javascript") || (mime.hasPrefix("text/html") && method == "GET"))
    }

    private static func body(_ postData: ObjectValue?, headers: inout [ImportedField], translator: ImportTranslator) -> ImportedBody? {
        guard let postData else { return nil }
        let mime = postData.string("mimeType")?.lowercased() ?? ""
        let params = postData.objects("params")
        let text = postData.string("text") ?? ""

        func parts(_ params: [ObjectValue]) -> [ImportedField] {
            params.compactMap { param in
                guard let name = param.string("name") else { return nil }
                if let file = param.string("fileName"), !file.isEmpty {
                    return ImportedField(name: name, value: file.hasPrefix("/") ? file : "./" + file, isFile: true)
                }
                return ImportedField(name: name, value: translator.escapingBraces(param.string("value") ?? ""))
            }
        }
        if mime.contains("multipart/form-data") || params.contains(where: { $0["fileName"] != nil }) {
            if !params.isEmpty { return .multipart(parts(params)) }
            // The whole body as text: take it apart so a new boundary can be built.
            let contentType = headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value ?? mime
            if let boundary = MultipartBody.boundary(in: contentType), let fields = MultipartBody.fields(in: text, boundary: boundary) {
                headers.removeAll { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }
                return .multipart(fields.map { ImportedField(name: $0.name, value: translator.escapingBraces($0.value), isFile: $0.isFile) })
            }
        }
        if mime.contains("x-www-form-urlencoded") || (mime.isEmpty && !params.isEmpty) {
            // Browsers differ: Chrome records what was sent, Safari and Firefox decode it first.
            var fields: [ImportedField]
            if !text.isEmpty {
                fields = text.split(separator: "&").compactMap { part in
                    guard let equals = part.firstIndex(of: "=") else { return nil }
                    let name = String(part[..<equals]).replacingOccurrences(of: "+", with: " ")
                    let value = part[part.index(after: equals)...].replacingOccurrences(of: "+", with: " ")
                    return ImportedField(name: name.removingPercentEncoding ?? name, value: value.removingPercentEncoding ?? String(value))
                }
            } else {
                fields = params.compactMap { param in
                    guard let name = param.string("name") else { return nil }
                    let value = param.string("value") ?? ""
                    return ImportedField(name: name.removingPercentEncoding ?? name, value: value.removingPercentEncoding ?? value)
                }
            }
            // A value with a line break can't be written as a form line; send the body as it was.
            if !fields.isEmpty, !fields.contains(where: { $0.name.contains(where: \.isNewline) || $0.value.contains(where: \.isNewline) }) {
                return .urlEncoded(fields.map { ImportedField(name: $0.name, value: translator.escapingBraces($0.value)) })
            }
        }
        guard !text.isEmpty else { return nil }
        return .text(translator.escapingBraces(text))
    }
}
