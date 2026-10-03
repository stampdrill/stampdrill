import Foundation
import Stamp

/// Insomnia exports: the JSON or YAML of export format 4, and the YAML
/// collections of Insomnia 10 and later (`collection.insomnia.rest/5.0`).
enum InsomniaImporter {
    static func collection(_ value: Value, translator: inout ImportTranslator) throws -> ImportedCollection {
        guard case .object(let object) = value else { throw Importer.Failure(message: "The Insomnia export isn't an object") }
        if object["resources"] != nil {
            return try version4(object, translator: &translator)
        }
        if object["collection"] != nil || object["environments"] != nil {
            return version5(object, translator: &translator)
        }
        throw Importer.Failure(message: "This Insomnia file has no requests; export a collection, not a design document")
    }

    // MARK: Format 4

    private static func version4(_ object: ObjectValue, translator: inout ImportTranslator) throws -> ImportedCollection {
        let resources = object.objects("resources")
        let workspaces = resources.filter { $0.string("_type") == "workspace" }
        var collection = ImportedCollection(name: workspaces.first?.string("name") ?? "Insomnia", format: Importer.Format.insomnia.rawValue)
        var context = Context(requestIDs: Set(resources.filter { $0.string("_type") == "request" }.compactMap { $0.string("_id") }))

        func folder(_ id: String, name: String) -> ImportedFolder {
            var result = ImportedFolder(name: name)
            let children = resources.filter { $0.string("parentId") == id }
                .sorted { ($0["metaSortKey"]?.numberValue ?? 0) < ($1["metaSortKey"]?.numberValue ?? 0) }
            for child in children {
                switch child.string("_type") {
                case "request":
                    result.requests.append(request(child, id: child.string("_id") ?? UUID().uuidString, context: &context, translator: &translator))
                case "request_group":
                    // Read the group's own settings first: they can refer to another request.
                    context.dependencies = []
                    let groupAuth = auth(child["authentication"]?.objectValue, context: &context, translator: &translator)
                    let groupHeaders = headers(child, context: &context, translator: &translator)
                    let groupDependencies = context.dependencies
                    for key in ["preRequestScript", "afterResponseScript"] where !(child.string(key) ?? "").isEmpty {
                        collection.warnings.append("scripts on the folder '\(child.string("name") ?? "")' weren't carried over")
                    }
                    var group = folder(child.string("_id") ?? "", name: child.string("name") ?? "Folder")
                    group.auth = groupAuth
                    group.headers = groupHeaders
                    group.dependencies = groupDependencies
                    if let data = child["environment"]?.objectValue, !data.isEmpty {
                        collection.warnings.append("the folder '\(child.string("name") ?? "")' has its own environment, which was added to the shared variables")
                        collection.variables += flatten(data, translator: &translator)
                    }
                    result.folders.append(group)
                case "websocket_request":
                    result.requests.append(request(child, id: child.string("_id") ?? UUID().uuidString, context: &context, translator: &translator))
                case "grpc_request":
                    collection.warnings.append("gRPC requests weren't imported ('\(child.string("name") ?? "")')")
                default:
                    break
                }
            }
            return result
        }

        if workspaces.count <= 1 {
            collection.root = folder(workspaces.first?.string("_id") ?? "", name: collection.name)
        } else {
            for workspace in workspaces {
                collection.root.folders.append(folder(workspace.string("_id") ?? "", name: workspace.string("name") ?? "Workspace"))
            }
        }

        // The base environment applies everywhere; sub-environments are the dimension's values.
        let environments = resources.filter { $0.string("_type") == "environment" }
        let workspaceIDs = Set(workspaces.compactMap { $0.string("_id") })
        for base in environments where workspaceIDs.contains(base.string("parentId") ?? "") || workspaces.isEmpty {
            collection.variables += flatten(base["data"]?.objectValue ?? ObjectValue(), translator: &translator)
            for sub in environments where sub.string("parentId") == base.string("_id") {
                collection.environments.append(ImportedEnvironment(
                    name: sub.string("name") ?? "Environment",
                    variables: flatten(sub["data"]?.objectValue ?? ObjectValue(), translator: &translator, secret: sub.bool("isPrivate") == true)
                ))
            }
        }
        collection.warnings += context.warnings
        return collection
    }

    // MARK: Format 5

    private static func version5(_ object: ObjectValue, translator: inout ImportTranslator) -> ImportedCollection {
        var collection = ImportedCollection(name: object.string("name") ?? "Insomnia", format: Importer.Format.insomnia.rawValue)
        var ids = Set<String>()
        func collectIDs(_ items: [ObjectValue]) {
            for item in items {
                if let id = item["meta"]?.objectValue?.string("id"), item["children"] == nil { ids.insert(id) }
                collectIDs(item.objects("children"))
            }
        }
        collectIDs(object.objects("collection"))
        var context = Context(requestIDs: ids)

        func folder(_ items: [ObjectValue], name: String) -> ImportedFolder {
            var result = ImportedFolder(name: name)
            for item in items {
                if item["children"] != nil {
                    context.dependencies = []
                    let groupAuth = auth(item["authentication"]?.objectValue, context: &context, translator: &translator)
                    let groupHeaders = headers(item, context: &context, translator: &translator)
                    let groupDependencies = context.dependencies
                    if let scripts = item["scripts"]?.objectValue,
                       [scripts.string("preRequest"), scripts.string("afterResponse")].contains(where: { !($0 ?? "").isEmpty })
                    {
                        collection.warnings.append("scripts on the folder '\(item.string("name") ?? "")' weren't carried over")
                    }
                    var child = folder(item.objects("children"), name: item.string("name") ?? "Folder")
                    child.auth = groupAuth
                    child.headers = groupHeaders
                    child.dependencies = groupDependencies
                    if let data = item["environment"]?.objectValue, !data.isEmpty {
                        collection.warnings.append("the folder '\(item.string("name") ?? "")' has its own environment, which was added to the shared variables")
                        collection.variables += flatten(data, translator: &translator)
                    }
                    result.folders.append(child)
                } else if item["protoFileId"] != nil || item["eventListeners"] != nil {
                    collection.warnings.append("\(item["protoFileId"] != nil ? "gRPC" : "Socket.IO") requests weren't imported ('\(item.string("name") ?? "")')")
                } else if item["url"] != nil || item["method"] != nil {
                    let id = item["meta"]?.objectValue?.string("id") ?? UUID().uuidString
                    result.requests.append(request(item, id: id, context: &context, translator: &translator))
                }
            }
            return result
        }
        collection.root = folder(object.objects("collection"), name: collection.name)

        if let environments = object["environments"]?.objectValue {
            collection.variables += flatten(environments["data"]?.objectValue ?? ObjectValue(), translator: &translator)
            for sub in environments.objects("subEnvironments") {
                collection.environments.append(ImportedEnvironment(
                    name: sub.string("name") ?? "Environment",
                    variables: flatten(sub["data"]?.objectValue ?? ObjectValue(), translator: &translator, secret: sub.bool("isPrivate") == true)
                ))
            }
        }
        collection.warnings += context.warnings
        return collection
    }

    // MARK: Requests

    private struct Context {
        var requestIDs: Set<String>
        var warnings: [String] = []
        /// Requests the one being read refers to with `{% response %}`.
        var dependencies: [String] = []
    }

    private static func request(_ object: ObjectValue, id: String, context: inout Context, translator: inout ImportTranslator) -> ImportedRequest {
        context.dependencies = []
        var url = template(object.string("url") ?? "", context: &context, translator: &translator)
        let parameters = object.objects("parameters").filter { $0.bool("disabled") != true }.compactMap { parameter -> String? in
            guard let name = parameter.string("name"), !name.isEmpty else { return nil }
            let value = template(parameter.string("value") ?? "", context: &context, translator: &translator)
            return "\(encodedOutsideBraces(name))=\(encodedOutsideBraces(value))"
        }
        if !parameters.isEmpty { url += (url.contains("?") ? "&" : "?") + parameters.joined(separator: "&") }

        var method = object.string("method") ?? "GET"
        let lowercasedURL = url.lowercased()
        if lowercasedURL.hasPrefix("ws://") || lowercasedURL.hasPrefix("wss://") || object.string("_type") == "websocket_request" { method = "WS" }
        var request = ImportedRequest(id: id, title: object.string("name") ?? requestTitle(method: method, url: url), method: method, url: url)
        request.description = object.string("description") ?? object["meta"]?.objectValue?.string("description")
        request.headers = headers(object, context: &context, translator: &translator)
        for parameter in object.objects("pathParameters") {
            guard let name = parameter.string("name"), !name.isEmpty else { continue }
            let identifier = translator.identifier(name)
            request.url = request.url.replacingOccurrences(of: ":" + NSRegularExpression.escapedPattern(for: name) + "(?=[/?#]|$)", with: "{{\(identifier)}}", options: .regularExpression)
            request.variables.append(ImportedVariable(name: identifier, value: template(parameter.string("value") ?? "", context: &context, translator: &translator)))
        }
        request.body = body(object["body"]?.objectValue, context: &context, translator: &translator)
        request.auth = auth(object["authentication"]?.objectValue, context: &context, translator: &translator)
        if let scripts = object["scripts"]?.objectValue, [scripts.string("preRequest"), scripts.string("afterResponse")].contains(where: { !($0 ?? "").isEmpty }) {
            request.notes.append("Insomnia scripts weren't converted")
        }
        for key in ["preRequestScript", "afterResponseScript"] where !(object.string(key) ?? "").isEmpty {
            request.notes.append("An Insomnia \(key == "preRequestScript" ? "pre-request" : "after-response") script wasn't converted")
        }
        request.dependencies = context.dependencies
        return request
    }

    /// Percent-encodes the text around `{{ … }}`, the way Insomnia encodes a parameter.
    private static func encodedOutsideBraces(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            result += rest[..<open.lowerBound].addingPercentEncoding(withAllowedCharacters: allowed) ?? String(rest[..<open.lowerBound])
            guard let close = rest[open.upperBound...].range(of: "}}") else { break }
            result += rest[open.lowerBound..<close.upperBound]
            rest = rest[close.upperBound...]
        }
        return result + (rest.addingPercentEncoding(withAllowedCharacters: allowed) ?? String(rest))
    }

    private static func headers(_ object: ObjectValue, context: inout Context, translator: inout ImportTranslator) -> [ImportedField] {
        object.objects("headers").compactMap { header in
            guard let name = header.string("name"), !name.isEmpty else { return nil }
            return ImportedField(name: name, value: template(header.string("value") ?? "", context: &context, translator: &translator), isEnabled: header.bool("disabled") != true)
        }
    }

    private static func body(_ body: ObjectValue?, context: inout Context, translator: inout ImportTranslator) -> ImportedBody? {
        guard let body else { return nil }
        let mime = body.string("mimeType") ?? ""
        let params = body.objects("params").map { param in
            ImportedField(
                name: param.string("name") ?? "",
                value: param.string("type") == "file" ? (param.string("fileName") ?? "") : template(param.string("value") ?? "", context: &context, translator: &translator),
                isEnabled: param.bool("disabled") != true, isFile: param.string("type") == "file"
            )
        }
        switch mime {
        case "application/x-www-form-urlencoded": return .urlEncoded(params)
        case "multipart/form-data": return .multipart(params)
        case "application/graphql":
            let text = body.string("text") ?? ""
            if let graphql = try? Value(json: Data(text.utf8)), let object = graphql.objectValue {
                return .graphQL(
                    query: template(object.string("query") ?? "", context: &context, translator: &translator),
                    variables: object["variables"].map { template($0.jsonString(pretty: true), context: &context, translator: &translator) }
                )
            }
            return .text(template(text, context: &context, translator: &translator))
        default:
            if let file = body.string("fileName"), !file.isEmpty { return .file(file) }
            guard let text = body.string("text"), !text.isEmpty else { return nil }
            return .text(template(text, context: &context, translator: &translator))
        }
    }

    private static func auth(_ auth: ObjectValue?, context: inout Context, translator: inout ImportTranslator) -> ImportedAuth? {
        guard let auth, let type = auth.string("type"), auth.bool("disabled") != true else { return nil }
        func setting(_ key: String) -> String { template(auth.string(key) ?? "", context: &context, translator: &translator) }
        switch type {
        case "none": return ImportedAuth.none
        case "bearer":
            let prefix = auth.string("prefix") ?? ""
            if !prefix.isEmpty, prefix.lowercased() != "bearer" {
                return .apiKey(name: "Authorization", value: prefix + " " + setting("token"), inQuery: false)
            }
            return .bearer(setting("token"))
        case "basic": return .basic(username: setting("username"), password: setting("password"))
        case "apikey": return .apiKey(name: auth.string("key") ?? "X-API-Key", value: setting("value"), inQuery: auth.string("addTo") == "queryParams")
        case "oauth2":
            switch auth.string("grantType") {
            case "client_credentials":
                return .oauth2ClientCredentials(tokenURL: setting("accessTokenUrl"), clientID: setting("clientId"), clientSecret: setting("clientSecret"), scope: auth.string("scope"))
            case "password":
                return .oauth2Password(
                    tokenURL: setting("accessTokenUrl"), clientID: setting("clientId"), clientSecret: setting("clientSecret"),
                    username: setting("username"), password: setting("password"), scope: auth.string("scope")
                )
            default:
                return .unsupported("OAuth 2 (\(auth.string("grantType") ?? "authorization code"))")
            }
        default:
            return .unsupported(type)
        }
    }

    // MARK: Templates

    /// Nunjucks as Insomnia uses it: `{{ _.base_url }}`, `{{ _['api-key'] }}`,
    /// and the `uuid`, `now`, `base64` and `response` tags.
    private static func template(_ text: String, context: inout Context, translator: inout ImportTranslator) -> String {
        var expressions: [String] = []
        var result = translateTags(text, expressions: &expressions, context: &context, translator: &translator)
        var names = translator
        result = ImportTranslator.replacingBraces(in: result) { inner in
            if let groups = match(inner, #"^_\s*\[\s*["']([^"']+)["']\s*\]$"#) { return names.identifier(groups[0]) }
            var name = inner
            if name.hasPrefix("_.") { name = String(name.dropFirst(2)) }
            guard name.range(of: #"^[\w$][\w$.\-]*$"#, options: .regularExpression) != nil else {
                names.warn("the Insomnia expression {{ \(inner) }} was kept as text")
                return nil
            }
            return names.identifier(name)
        }
        translator = names
        // Tags were set aside so the braces pass leaves them alone.
        for (index, expression) in expressions.enumerated() {
            result = result.replacingOccurrences(of: "⟦tag:\(index)⟧", with: "{{\(expression)}}")
        }
        return result
    }

    private static func translateTags(_ text: String, expressions: inout [String], context: inout Context, translator: inout ImportTranslator) -> String {
        guard text.contains("{%") else { return text }
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{%"), let close = rest[open.upperBound...].range(of: "%}") {
            result += rest[..<open.lowerBound]
            let tag = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            let words = tag.split(separator: " ", maxSplits: 1).map(String.init)
            let arguments = words.count > 1 ? tagArguments(words[1]) : []
            func add(_ expression: String) {
                result += "⟦tag:\(expressions.count)⟧"
                expressions.append(expression)
            }
            switch words.first {
            case "uuid":
                add("uuid()")
            case "now":
                switch arguments.first {
                case "millis": add("timestamp() * 1000")
                case "unix": add("timestamp()")
                default: add("now()")
                }
            case "base64" where arguments.count >= 3 && arguments[0] == "encode":
                add("base64(\(Value.string(arguments[2]).sourceLiteral))")
            case "response" where arguments.count >= 3 && context.requestIDs.contains(arguments[1]):
                let reference = ImportWriter.reference(to: arguments[1])
                switch arguments[0] {
                case "body":
                    if let path = jsonPath(arguments[2]) {
                        context.dependencies.append(arguments[1])
                        add("\(reference).body\(path)")
                    } else {
                        translator.warn("the Insomnia filter '\(arguments[2])' has no equivalent; the tag was kept as text")
                        result += "{%" + tag + "%}"
                    }
                case "header":
                    context.dependencies.append(arguments[1])
                    add("\(reference).headers[\(Value.string(arguments[2].lowercased()).sourceLiteral)]")
                case "url", "raw":
                    context.dependencies.append(arguments[1])
                    add("\(reference).\(arguments[0] == "url" ? "url" : "text")")
                default:
                    translator.warn("the Insomnia response attribute '\(arguments[0])' has no equivalent; the tag was kept as text")
                    result += "{%" + tag + "%}"
                }
            default:
                translator.warn("the Insomnia tag {% \(words.first ?? "") %} has no equivalent; it was kept as text")
                result += "{%" + tag + "%}"
            }
            rest = rest[close.upperBound...]
        }
        return result + rest
    }

    /// `'body', 'req_1', 'b64::JC50b2tlbg==::46b'` → the quoted arguments, with base64 decoded.
    private static func tagArguments(_ text: String) -> [String] {
        var arguments: [String] = []
        var rest = Substring(text)
        while let quote = rest.firstIndex(where: { $0 == "'" || $0 == "\"" }) {
            let mark = rest[quote]
            guard let end = rest[rest.index(after: quote)...].firstIndex(of: mark) else { break }
            var argument = String(rest[rest.index(after: quote)..<end])
            if argument.hasPrefix("b64::"), let encoded = argument.dropFirst(5).components(separatedBy: "::").first,
               let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8)
            {
                argument = decoded
            }
            arguments.append(argument)
            rest = rest[rest.index(after: end)...]
        }
        return arguments
    }

    /// `$.data[0].token` → `.data[0].token`; nil for a filter Stamp has no equivalent for.
    private static func jsonPath(_ path: String) -> String? {
        var path = path.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("$") { path.removeFirst() }
        return path.range(of: #"^((\.[A-Za-z_]\w*)|(\[\d+\])|(\[["'][^"']+["']\]))*$"#, options: .regularExpression) != nil
            ? path.replacingOccurrences(of: "'", with: "\"") : nil
    }

    /// Environment data, which can nest: `{ "api": { "url": … } }` gives `apiUrl`, as `_.api.url` would read.
    private static func flatten(_ data: ObjectValue, prefix: String = "", translator: inout ImportTranslator, secret: Bool = false) -> [ImportedVariable] {
        var variables: [ImportedVariable] = []
        for (key, value) in data {
            let path = prefix.isEmpty ? key : prefix + "." + key
            switch value {
            case .object(let nested):
                variables += flatten(nested, prefix: path, translator: &translator, secret: secret)
            case .string(let text):
                var context = Context(requestIDs: [])
                variables.append(ImportedVariable(name: translator.identifier(path), value: template(text, context: &context, translator: &translator), isSecret: secret))
            default:
                variables.append(ImportedVariable(name: translator.identifier(path), value: value.interpolated, isSecret: secret))
            }
        }
        return variables
    }
}
