import Foundation
import Stamp

/// Turns an OpenAPI 3 or Swagger 2 specification into request files: one
/// `.stamp` file per tag, one request per operation.
///
/// Parameters become variables declared on the request, security schemes
/// become `@auth`, and request bodies are filled with example data, taken from
/// the spec when it has examples and generated from the schema otherwise.
public enum OpenAPIImporter {
    public struct Output {
        public var title: String
        /// Relative paths and file contents.
        public var files: [(path: String, text: String)]
        public var operationCount: Int
    }

    public enum Failure: Error, LocalizedError {
        case notASpecification

        public var errorDescription: String? {
            "This file isn't an OpenAPI or Swagger specification"
        }
    }

    public static func convert(_ data: Data) throws -> Output {
        let text = String(decoding: data, as: UTF8.self)
        let value: Value
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            value = try Value(json: data)
        } else {
            value = try YAML.parse(text)
        }
        guard case .object(let spec) = value, spec["openapi"] != nil || spec["swagger"] != nil,
              case .object(let paths)? = spec["paths"]
        else { throw Failure.notASpecification }

        let info = spec["info"]?.objectValue
        let title = info?["title"]?.stringValue ?? "API"
        let baseURL = serverURL(spec)
        let resolver = References(spec: spec)

        var byTag: [(tag: String, lines: [String])] = []
        var usedNames = Set<String>()
        var operationCount = 0
        let globalSecurity = spec["security"]

        for (path, item) in paths {
            guard case .object(let pathItem) = item else { continue }
            let sharedParameters = pathItem["parameters"]
            for method in ["get", "post", "put", "patch", "delete", "head", "options"] {
                guard case .object(let operation)? = pathItem[method] else { continue }
                operationCount += 1
                let tag = operation["tags"].flatMap { if case .array(let tags) = $0 { tags.first?.stringValue } else { nil } } ?? title
                var lines = request(
                    method: method.uppercased(), path: path, operation: operation, sharedParameters: sharedParameters,
                    spec: spec, resolver: resolver, security: operation["security"] ?? globalSecurity, usedNames: &usedNames
                )
                lines.append("")
                if let index = byTag.firstIndex(where: { $0.tag == tag }) {
                    byTag[index].lines += lines
                } else {
                    byTag.append((tag, lines))
                }
            }
        }

        let files = byTag.map { tag, lines -> (String, String) in
            let header = [
                "# \(title)\(info?["version"].map { " \($0.interpolated)" } ?? "") · \(tag)",
                "# Imported from the OpenAPI specification; edit freely.",
                "",
                "@baseUrl = \(baseURL)",
                "",
            ]
            return (fileName(tag) + ".stamp", (header + lines).joined(separator: "\n"))
        }
        return Output(title: title, files: files, operationCount: operationCount)
    }

    // MARK: Operations

    private static func request(
        method: String, path: String, operation: ObjectValue, sharedParameters: Value?, spec: ObjectValue,
        resolver: References, security: Value?, usedNames: inout Set<String>
    ) -> [String] {
        let summary = operation["summary"]?.stringValue ?? operation["operationId"]?.stringValue ?? "\(method) \(path)"
        var lines: [String] = []
        if let description = operation["description"]?.stringValue, !description.hasPrefix(summary.trimmingCharacters(in: CharacterSet(charactersIn: ". "))) {
            for line in description.split(separator: "\n").prefix(3) { lines.append("# " + line) }
        }
        lines.append("### " + summary.replacingOccurrences(of: "\n", with: " "))

        var name = operation["operationId"]?.stringValue?.stampIdentifierKeepingName ?? summary.stampIdentifier ?? "request"
        var counter = 2
        let base = name
        while !usedNames.insert(name).inserted {
            name = base + String(counter)
            counter += 1
        }
        lines.append("@name \(name)")
        if operation["deprecated"] == .bool(true) { lines.append("# Deprecated") }

        var parameters: [ObjectValue] = []
        for source in [sharedParameters, operation["parameters"]] {
            if case .array(let items)? = source {
                parameters += items.compactMap { resolver.resolve($0).objectValue }
            }
        }

        var variables: [String] = []
        var query: [String] = []
        var headers: [String] = []
        for parameter in parameters {
            guard let parameterName = parameter["name"]?.stringValue, let location = parameter["in"]?.stringValue else { continue }
            let variable = parameterName.stampIdentifierKeepingName ?? "value"
            let example = exampleValue(parameter, resolver: resolver, seed: name + "." + parameterName)
            switch location {
            case "path":
                variables.append("@\(variable) = \(example)")
            case "query":
                if parameter["required"] == .bool(true) {
                    variables.append("@\(variable) = \(example)")
                    query.append("\(parameterName)={{\(variable)}}")
                }
            case "header":
                variables.append("@\(variable) = \(example)")
                headers.append("\(parameterName): {{\(variable)}}")
            default:
                break
            }
        }
        lines += variables

        if let auth = authLine(security: security, spec: spec) {
            lines.append(auth)
        }

        var target = "{{baseUrl}}" + path.replacingOccurrences(of: "{", with: "{{").replacingOccurrences(of: "}", with: "}}")
        for parameter in parameters where parameter["in"]?.stringValue == "path" {
            if let original = parameter["name"]?.stringValue, let variable = original.stampIdentifierKeepingName, variable != original {
                target = target.replacingOccurrences(of: "{{\(original)}}", with: "{{\(variable)}}")
            }
        }
        if !query.isEmpty { target += "?" + query.joined(separator: "&") }
        lines.append("\(method) \(target)")

        let (contentType, body) = requestBody(operation, parameters: parameters, spec: spec, resolver: resolver, seed: name)
        if let contentType { lines.append("Content-Type: \(contentType)") }
        if producesJSON(operation, spec: spec) { lines.append("Accept: application/json") }
        lines += headers
        if let body {
            lines.append("")
            lines.append(body)
        }

        if let status = successStatus(operation) {
            lines.append("")
            lines.append("> assert status == \(status)")
        }
        return lines
    }

    private static func requestBody(
        _ operation: ObjectValue, parameters: [ObjectValue], spec: ObjectValue, resolver: References, seed: String
    ) -> (String?, String?) {
        // OpenAPI 3
        if case .object(let requestBody) = resolver.resolve(operation["requestBody"] ?? .null),
           case .object(let content)? = requestBody["content"]
        {
            let preferred = ["application/json", "application/x-www-form-urlencoded", "multipart/form-data"]
            let type = preferred.first { content[$0] != nil } ?? content.keys.first
            guard let type, case .object(let media)? = content[type] else { return (nil, nil) }
            let example = mediaExample(media, resolver: resolver, seed: seed)
            if type.contains("json") {
                return (type, example.jsonString(pretty: true))
            }
            if type.contains("form"), case .object(let fields) = example {
                return (type, fields.map { "\($0.key) = \($0.value.interpolated)" }.joined(separator: "\n"))
            }
            return (type, example == .null ? nil : example.interpolated)
        }
        // Swagger 2: a "body" parameter, or formData parameters.
        if let bodyParameter = parameters.first(where: { $0["in"]?.stringValue == "body" }), let schema = bodyParameter["schema"] {
            var random = SeededRandom(seed: seed)
            return ("application/json", Mock.value(for: resolver.inline(schema), using: &random).jsonString(pretty: true))
        }
        let form = parameters.filter { $0["in"]?.stringValue == "formData" }
        if !form.isEmpty {
            let hasFile = form.contains { $0["type"]?.stringValue == "file" }
            let lines = form.map { field -> String in
                let fieldName = field["name"]?.stringValue ?? "field"
                return field["type"]?.stringValue == "file" ? "\(fieldName) = < ./\(fieldName)" : "\(fieldName) = \(exampleValue(field, resolver: resolver, seed: seed + fieldName))"
            }
            return (hasFile ? "multipart/form-data" : "application/x-www-form-urlencoded", lines.joined(separator: "\n"))
        }
        return (nil, nil)
    }

    private static func mediaExample(_ media: ObjectValue, resolver: References, seed: String) -> Value {
        if let example = media["example"] { return example }
        if case .object(let examples)? = media["examples"], let first = examples.first(where: { _ in true }),
           case .object(let wrapper) = resolver.resolve(first.value), let value = wrapper["value"]
        {
            return value
        }
        guard let schema = media["schema"] else { return .null }
        var random = SeededRandom(seed: seed)
        return Mock.value(for: resolver.inline(schema), using: &random)
    }

    private static func exampleValue(_ parameter: ObjectValue, resolver: References, seed: String) -> String {
        if let example = parameter["example"] { return example.interpolated }
        let schema = resolver.inline(parameter["schema"] ?? .object(parameter))
        if case .object(let object) = schema {
            if let example = object["example"] ?? object["default"] { return example.interpolated }
            if case .array(let options)? = object["enum"], let first = options.first { return first.interpolated }
        }
        var random = SeededRandom(seed: seed)
        return Mock.value(for: schema, using: &random, name: parameter["name"]?.stringValue).interpolated
    }

    private static func successStatus(_ operation: ObjectValue) -> String? {
        guard case .object(let responses)? = operation["responses"] else { return nil }
        return responses.keys.first { $0.hasPrefix("2") && $0.count == 3 }
    }

    private static func producesJSON(_ operation: ObjectValue, spec: ObjectValue) -> Bool {
        if case .object(let responses)? = operation["responses"] {
            for (_, response) in responses {
                if case .object(let content)? = response.objectValue?["content"], content.keys.contains(where: { $0.contains("json") }) { return true }
            }
        }
        if case .array(let produces)? = operation["produces"] ?? spec["produces"] {
            return produces.contains { $0.stringValue?.contains("json") == true }
        }
        return false
    }

    // MARK: Security

    private static func authLine(security: Value?, spec: ObjectValue) -> String? {
        guard case .array(let requirements)? = security, let first = requirements.first?.objectValue, let schemeName = first.keys.first else {
            return nil
        }
        let schemes = spec["components"]?.objectValue?["securitySchemes"]?.objectValue ?? spec["securityDefinitions"]?.objectValue
        guard case .object(let scheme)? = schemes?[schemeName] else { return nil }
        let variable = schemeName.stampIdentifier ?? "token"

        switch (scheme["type"]?.stringValue, scheme["scheme"]?.stringValue?.lowercased()) {
        case ("http", "bearer"?):
            return scheme["bearerFormat"]?.stringValue?.uppercased() == "JWT" ? "@auth jwt {{\(variable)}}" : "@auth bearer {{\(variable)}}"
        case ("http", "basic"?), ("basic", _):
            return "@auth basic {{username}} {{password}}"
        case ("apiKey", _):
            let name = scheme["name"]?.stringValue ?? "X-API-Key"
            let location = scheme["in"]?.stringValue == "query" ? "query" : "header"
            return "@auth apikey \(name) {{\(variable)}} \(location)"
        case ("oauth2", _):
            let flows = scheme["flows"]?.objectValue
            if let tokenURL = flows?["clientCredentials"]?.objectValue?["tokenUrl"]?.stringValue ?? scheme["tokenUrl"]?.stringValue {
                return "@auth oauth2 client_credentials token_url=\(tokenURL) client_id={{clientId}} client_secret={{secret(clientSecret)}}"
            }
            if let tokenURL = flows?["password"]?.objectValue?["tokenUrl"]?.stringValue {
                return "@auth oauth2 password token_url=\(tokenURL) client_id={{clientId}} username={{username}} password={{secret(password)}}"
            }
            return "@auth bearer {{accessToken}}"
        default:
            return nil
        }
    }

    // MARK: Helpers

    private static func serverURL(_ spec: ObjectValue) -> String {
        if case .array(let servers)? = spec["servers"], let first = servers.first?.objectValue?["url"]?.stringValue {
            var url = first
            // Server variables: {region} becomes its default.
            if case .object(let variables)? = servers.first?.objectValue?["variables"] {
                for (name, variable) in variables {
                    url = url.replacingOccurrences(of: "{\(name)}", with: variable.objectValue?["default"]?.interpolated ?? name)
                }
            }
            if url.hasPrefix("/") {
                // Relative to wherever the document is served; the host is the user's to fill in.
                url = "https://api.example.com" + url
            }
            return url.hasSuffix("/") ? String(url.dropLast()) : url
        }
        if let host = spec["host"]?.stringValue {
            let scheme = spec["schemes"].flatMap { if case .array(let schemes) = $0 { schemes.first?.stringValue } else { nil } } ?? "https"
            return "\(scheme)://\(host)\(spec["basePath"]?.stringValue ?? "")"
        }
        return "https://api.example.com"
    }

    private static func fileName(_ tag: String) -> String {
        let cleaned = tag.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Requests" : cleaned.prefix(1).uppercased() + cleaned.dropFirst()
    }

    /// Resolves local `$ref`s.
    struct References {
        let spec: ObjectValue

        func resolve(_ value: Value) -> Value {
            guard case .object(let object) = value, let reference = object["$ref"]?.stringValue, reference.hasPrefix("#/") else { return value }
            var current: Value = .object(spec)
            for component in reference.dropFirst(2).split(separator: "/") {
                let key = component.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                guard case .object(let container) = current, let next = container[key] else { return .null }
                current = next
            }
            return current
        }

        /// A schema with every `$ref` replaced, stopping at cycles.
        func inline(_ value: Value, depth: Int = 0) -> Value {
            guard depth < 10 else { return .null }
            switch value {
            case .object(let object):
                if object["$ref"] != nil { return inline(resolve(value), depth: depth + 1) }
                var result = ObjectValue()
                for (key, child) in object { result[key] = inline(child, depth: depth + 1) }
                return .object(result)
            case .array(let items):
                return .array(items.map { inline($0, depth: depth + 1) })
            default:
                return value
            }
        }
    }
}

extension String {
    /// Keeps a name as written when it is already a valid identifier, like `petId`.
    var stampIdentifierKeepingName: String? {
        let units = Array(utf16)
        if let first = units.first, units.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F }),
           !(first >= 0x30 && first <= 0x39)
        {
            return self
        }
        return stampIdentifier
    }
}
