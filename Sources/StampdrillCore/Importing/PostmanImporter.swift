import Foundation
import Stamp

/// Postman collections (format 2.0 and 2.1), environments and globals.
enum PostmanImporter {
    static func collection(_ object: ObjectValue, translator: inout ImportTranslator) throws -> ImportedCollection {
        let info = object["info"]?.objectValue ?? ObjectValue()
        var collection = ImportedCollection(name: info.string("name") ?? "Postman", format: Importer.Format.postman.rawValue)

        for variable in object.objects("variable") {
            guard let key = variable.string("key"), variable.bool("disabled") != true else { continue }
            collection.variables.append(ImportedVariable(
                name: translator.identifier(key), value: translator.mustache(variable.string("value") ?? ""),
                isSecret: variable.string("type") == "secret"
            ))
        }

        var root = ImportedFolder(name: collection.name)
        root.auth = auth(object["auth"]?.objectValue, translator: &translator)
        if !object.objects("event").isEmpty {
            collection.warnings.append("the collection's own scripts weren't carried over")
        }
        read(object.array("item"), into: &root, translator: &translator, warnings: &collection.warnings)
        collection.root = root
        return collection
    }

    private static func read(_ items: [Value], into folder: inout ImportedFolder, translator: inout ImportTranslator, warnings: inout [String]) {
        for case .object(let item) in items {
            let name = item.string("name") ?? "Untitled"
            if item["item"] != nil {
                var child = ImportedFolder(name: name)
                child.auth = auth(item["auth"]?.objectValue, translator: &translator)
                read(item.array("item"), into: &child, translator: &translator, warnings: &warnings)
                if item.objects("event").contains(where: { !scriptLines($0).isEmpty }) {
                    warnings.append("scripts on the folder '\(name)' weren't carried over")
                }
                folder.folders.append(child)
            } else if item["request"] != nil {
                folder.requests.append(request(item, name: name, translator: &translator))
            }
        }
    }

    private static func request(_ item: ObjectValue, name: String, translator: inout ImportTranslator) -> ImportedRequest {
        let request: ObjectValue
        switch item["request"] {
        case .string(let url)?: request = ObjectValue([("url", .string(url)), ("method", "GET")])
        case .object(let object)?: request = object
        default: request = ObjectValue()
        }

        var imported = ImportedRequest(id: item.string("id") ?? UUID().uuidString, title: name, method: request.string("method") ?? "GET", url: "")
        imported.description = description(request["description"]) ?? description(item["description"])

        // URL, with `:name` path variables turned into `{{name}}`.
        var pathVariables: [String: String] = [:]
        switch request["url"] {
        case .string(let raw)?:
            imported.url = translator.mustache(raw)
        case .object(let url)?:
            var raw = url.string("raw") ?? assembledURL(url)
            for variable in url.objects("variable") {
                guard let key = variable.string("key") else { continue }
                pathVariables[key] = variable.string("value") ?? ""
            }
            raw = replacingPathVariables(in: raw, names: Array(pathVariables.keys))
            imported.url = translator.mustache(raw)
        default:
            break
        }
        // Path variables are request-scoped in Postman, so they are declared on the request.
        for (key, value) in pathVariables.sorted(by: { $0.key < $1.key }) {
            imported.variables.append(ImportedVariable(name: translator.identifier(key), value: translator.mustache(value)))
        }

        for header in request.objects("header") {
            guard let key = header.string("key") else { continue }
            imported.headers.append(ImportedField(name: key, value: translator.mustache(header.string("value") ?? ""), isEnabled: header.bool("disabled") != true))
        }
        imported.body = body(request["body"]?.objectValue, translator: &translator, request: &imported)
        imported.auth = auth(request["auth"]?.objectValue, translator: &translator)

        for event in item.objects("event") {
            let lines = scriptLines(event)
            guard !lines.isEmpty else { continue }
            if event.string("listen") == "test" {
                let (statements, leftovers) = PostmanScript.translate(lines, translator: &translator)
                imported.script += statements
                if !leftovers.isEmpty {
                    imported.notes.append("Postman test script lines that weren't converted:")
                    imported.notes += leftovers.prefix(20).map { "  " + $0 }
                }
            } else {
                imported.notes.append("A Postman pre-request script wasn't converted (\(lines.count) lines)")
            }
        }
        return imported
    }

    private static func description(_ value: Value?) -> String? {
        switch value {
        case .string(let text)?: text
        case .object(let object)?: object.string("content")
        default: nil
        }
    }

    private static func assembledURL(_ url: ObjectValue) -> String {
        func joined(_ key: String, _ separator: String) -> String {
            switch url[key] {
            case .string(let text)?: text
            case .array(let parts)?: parts.map(\.interpolated).joined(separator: separator)
            default: ""
            }
        }
        var text = ""
        if let scheme = url.string("protocol") { text += scheme + "://" }
        text += joined("host", ".")
        if let port = url.string("port") { text += ":" + port }
        let path = joined("path", "/")
        if !path.isEmpty { text += "/" + path }
        let query = url.objects("query").filter { $0.bool("disabled") != true }.compactMap { item -> String? in
            guard let key = item.string("key") else { return nil }
            return item.string("value").map { "\(key)=\($0)" } ?? key
        }
        if !query.isEmpty { text += "?" + query.joined(separator: "&") }
        return text
    }

    /// `/users/:id` → `/users/{{id}}` for the variables the URL declares.
    private static func replacingPathVariables(in url: String, names: [String]) -> String {
        guard !names.isEmpty else { return url }
        var result = url
        for name in names.sorted(by: { $0.count > $1.count }) {
            let pattern = ":" + NSRegularExpression.escapedPattern(for: name) + "(?=[/?#]|$)"
            result = result.replacingOccurrences(of: pattern, with: "{{\(name)}}", options: .regularExpression)
        }
        return result
    }

    private static func scriptLines(_ event: ObjectValue) -> [String] {
        let script = event["script"]?.objectValue
        switch script?["exec"] {
        case .array(let lines)?: return lines.compactMap(\.stringValue).flatMap { $0.components(separatedBy: "\n") }
        case .string(let text)?: return text.components(separatedBy: "\n")
        default: return []
        }
    }

    // MARK: Body

    private static func body(_ body: ObjectValue?, translator: inout ImportTranslator, request: inout ImportedRequest) -> ImportedBody? {
        guard let body, body.bool("disabled") != true else { return nil }
        func fields(_ key: String) -> [ImportedField] {
            body.objects(key).compactMap { field in
                guard let name = field.string("key") else { return nil }
                let isFile = field.string("type") == "file"
                var value = field.string("value") ?? ""
                if isFile {
                    switch field["src"] {
                    case .string(let path)?: value = path
                    case .array(let paths)?:
                        value = paths.first?.stringValue ?? ""
                        if paths.count > 1 {
                            request.notes.append("Only the first file of '\(name)' was kept: \(paths.dropFirst().compactMap(\.stringValue).joined(separator: ", "))")
                        }
                    default: break
                    }
                }
                if !isFile, value.hasPrefix("< ") {
                    // `< path` in a form means an upload, so a text value that looks like one is quoted.
                    return ImportedField(name: name, value: "{{\(Value.string(value).sourceLiteral)}}", isEnabled: field.bool("disabled") != true)
                }
                return ImportedField(name: name, value: isFile ? value : translator.mustache(value), isEnabled: field.bool("disabled") != true, isFile: isFile)
            }
        }

        /// `a=1&b=two%20words` as form fields.
        func formFields(_ text: String) -> [ImportedField]? {
            var fields: [ImportedField] = []
            for part in text.split(separator: "&") where !part.isEmpty {
                guard let equals = part.firstIndex(of: "="), !part.contains(where: \.isNewline) else { return nil }
                let name = String(part[..<equals]).replacingOccurrences(of: "+", with: " ")
                let value = part[part.index(after: equals)...].replacingOccurrences(of: "+", with: " ")
                fields.append(ImportedField(name: name.removingPercentEncoding ?? name, value: value.removingPercentEncoding ?? String(value)))
            }
            return fields.isEmpty ? nil : fields
        }
        switch body.string("mode") {
        case "raw":
            let text = translator.mustache(body.string("raw") ?? "")
            let declared = request.headers.first { $0.isEnabled && $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value.lowercased()
            if declared?.contains("x-www-form-urlencoded") == true, let fields = formFields(text) {
                // A form body is written as `name = value` lines, not as raw text.
                return .urlEncoded(fields)
            }
            let language = body["options"]?.objectValue?["raw"]?.objectValue?.string("language")
            let type: String? = switch language {
            case "json": "application/json"
            case "xml": "application/xml"
            case "html": "text/html"
            case "javascript": "application/javascript"
            default: nil
            }
            if let type, !request.headers.contains(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
                request.headers.append(ImportedField(name: "Content-Type", value: type))
            }
            return .text(text)
        case "urlencoded":
            return .urlEncoded(fields("urlencoded"))
        case "formdata":
            return .multipart(fields("formdata"))
        case "file":
            guard let path = body["file"]?.objectValue?.string("src") else { return nil }
            return .file(path)
        case "graphql":
            let graphql = body["graphql"]?.objectValue
            return .graphQL(query: translator.mustache(graphql?.string("query") ?? ""), variables: graphql?.string("variables").map { translator.mustache($0) })
        default:
            return nil
        }
    }

    // MARK: Auth

    /// `nil` for `inherit` or no auth at all, so the folders above decide.
    static func auth(_ auth: ObjectValue?, translator: inout ImportTranslator) -> ImportedAuth? {
        guard let auth, let type = auth.string("type") else { return nil }
        // 2.1 writes `[{ key, value }]`, 2.0 an object.
        var settings: [String: String] = [:]
        switch auth[type] {
        case .array(let items)?:
            for case .object(let item) in items {
                if let key = item.string("key") { settings[key] = item.string("value") ?? item["value"]?.jsonString() }
            }
        case .object(let object)?:
            for (key, value) in object { settings[key] = value.stringValue ?? value.interpolated }
        default:
            break
        }
        func setting(_ key: String) -> String { translator.mustache(settings[key] ?? "") }

        switch type {
        case "noauth": return ImportedAuth.none
        case "inherit": return nil
        case "bearer": return .bearer(setting("token"))
        case "basic": return .basic(username: setting("username"), password: setting("password"))
        case "apikey": return .apiKey(name: settings["key"] ?? "X-API-Key", value: setting("value"), inQuery: settings["in"] == "query")
        case "oauth2":
            let grant = settings["grant_type"] ?? ""
            if grant == "client_credentials" {
                return .oauth2ClientCredentials(tokenURL: setting("accessTokenUrl"), clientID: setting("clientId"), clientSecret: setting("clientSecret"), scope: settings["scope"])
            }
            if grant == "password_credentials" {
                return .oauth2Password(
                    tokenURL: setting("accessTokenUrl"), clientID: setting("clientId"), clientSecret: setting("clientSecret"),
                    username: setting("username"), password: setting("password"), scope: settings["scope"]
                )
            }
            if let token = settings["accessToken"], !token.isEmpty {
                // Postman can put the token in the query, or use its own header prefix.
                if settings["addTokenTo"] == "queryParams" {
                    return .apiKey(name: "access_token", value: translator.mustache(token), inQuery: true)
                }
                let prefix = settings["headerPrefix"]?.trimmingCharacters(in: .whitespaces) ?? ""
                if !prefix.isEmpty, prefix.lowercased() != "bearer" {
                    return .apiKey(name: "Authorization", value: prefix + " " + translator.mustache(token), inQuery: false)
                }
                return .bearer(translator.mustache(token))
            }
            return .unsupported("OAuth 2 (\(grant.isEmpty ? "authorization code" : grant))")
        default:
            return .unsupported(type)
        }
    }

    // MARK: Environments

    /// An environment file, or the globals file, which applies everywhere.
    static func environment(_ object: ObjectValue, translator: inout ImportTranslator) throws -> (ImportedEnvironment, isGlobals: Bool) {
        let variables = object.objects("values").compactMap { value -> ImportedVariable? in
            guard let key = value.string("key"), value.bool("enabled") != false else { return nil }
            return ImportedVariable(name: translator.identifier(key), value: translator.mustache(value.string("value") ?? ""), isSecret: value.string("type") == "secret")
        }
        return (ImportedEnvironment(name: object.string("name") ?? "Environment", variables: variables), object.string("_postman_variable_scope") == "globals")
    }
}

/// The common lines of Postman test scripts, as Stamp statements.
enum PostmanScript {
    static func translate(_ lines: [String], translator: inout ImportTranslator) -> (statements: [String], leftovers: [String]) {
        var statements: [String] = []
        var leftovers: [String] = []
        var bodyNames: Set<String> = []

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") || isStructural(line) { continue }

            if let name = match(line, #"^(?:var|let|const)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:pm\.response\.json\(\)|JSON\.parse\(responseBody\))\s*;?$"#)?[0] {
                bodyNames.insert(name)
                continue
            }
            if let status = match(line, #"pm\.response\.to\.have\.status\((\d{3})\)"#)?[0]
                ?? match(line, #"pm\.expect\(pm\.response\.code\)\.to\.(?:eql|equal|be\.equal|eq)\((\d{3})\)"#)?[0]
                ?? match(line, #"responseCode\.code\s*===?\s*(\d{3})"#)?[0]
            {
                statements.append("assert status == \(status)")
                continue
            }
            // Postman's `.ok` is exactly 200; `.success` is any 2xx.
            if line.contains("pm.response.to.be.ok") {
                statements.append("assert status == 200")
                continue
            }
            if line.contains("pm.response.to.be.success") {
                statements.append("assert status >= 200 && status < 300")
                continue
            }
            if let limit = match(line, #"pm\.expect\(pm\.response\.responseTime\)\.to\.be\.(?:below|lessThan|lt)\((\d+)\)"#)?[0] {
                statements.append("assert time < \(limit)")
                continue
            }
            if let header = match(line, #"pm\.response\.to\.have\.header\(\s*["']([^"']+)["']\s*\)"#)?[0] {
                statements.append("assert headers[\(Value.string(header.lowercased()).sourceLiteral)] != null")
                continue
            }
            if let groups = match(line, #"(?:pm\.(?:environment|collectionVariables|globals|variables)\.set|postman\.set(?:Environment|Global)Variable)\(\s*["']([^"']+)["']\s*,\s*(.+?)\s*\)\s*;?$"#),
               let path = responsePath(groups[1], bodyNames: bodyNames)
            {
                statements.append("set \(translator.identifier(groups[0])) = \(path)")
                continue
            }
            if let groups = match(line, #"pm\.expect\((.+?)\)\.to\.(?:eql|equal|eq|be\.equal)\((.+)\)\s*;?$"#),
               let path = responsePath(groups[0], bodyNames: bodyNames), let literal = literal(groups[1])
            {
                statements.append("assert \(path) == \(literal)")
                continue
            }
            leftovers.append(line)
        }
        return (statements, leftovers)
    }

    private static func isStructural(_ line: String) -> Bool {
        line.range(of: #"^pm\.test\(.*function\s*\(\)\s*\{$|^pm\.test\(.*=>\s*\{$|^\}\);?$|^\}\)\s*;?$|^\};?$"#, options: .regularExpression) != nil
    }

    /// `pm.response.json().data[0].id` or `jsonData.token` → `body.data[0].id`.
    private static func responsePath(_ expression: String, bodyNames: Set<String>) -> String? {
        let accessors = #"((?:\.[A-Za-z_$][\w$]*|\[\d+\]|\[\s*["'][^"']+["']\s*\])*)"#
        var rest: String?
        if let groups = match(expression, #"^pm\.response\.json\(\)"# + accessors + "$") {
            rest = groups[0]
        } else if let groups = match(expression, #"^([A-Za-z_$][\w$]*)"# + accessors + "$"), bodyNames.contains(groups[0]) {
            rest = groups[1]
        } else if expression == "pm.response.code" {
            return "status"
        }
        guard let rest else { return nil }
        return "body" + rest.replacingOccurrences(of: "'", with: "\"")
    }

    private static func literal(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if Double(text) != nil || ["true", "false", "null"].contains(text) { return text }
        if let groups = match(text, #"^"([^"\\]*)"$"#) ?? match(text, #"^'([^'\\]*)'$"#) { return Value.string(groups[0]).sourceLiteral }
        return nil
    }
}

/// Capture groups of the first match, or nil.
func match(_ text: String, _ pattern: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return nil }
    return (1..<max(result.numberOfRanges, 1)).map { index in
        Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
    }
}
