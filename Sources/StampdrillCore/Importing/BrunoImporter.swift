import Foundation
import Stamp

/// Bruno collections: a folder with `bruno.json`, request `.bru` files in
/// folders, and environments in `environments/`. A single `.bru` file works too.
enum BrunoImporter {
    static func collection(at url: URL, translator: inout ImportTranslator) throws -> ImportedCollection {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        manager.fileExists(atPath: url.path, isDirectory: &isDirectory)

        if !isDirectory.boolValue {
            var collection = ImportedCollection(name: url.deletingPathExtension().lastPathComponent, format: Importer.Format.bruno.rawValue)
            let file = BruFile(try String(contentsOf: url, encoding: .utf8))
            if let request = request(file, fallbackName: collection.name, root: url.deletingLastPathComponent(), translator: &translator, warnings: &collection.warnings) {
                collection.root.requests = [request]
            }
            return collection
        }

        let config = (try? Data(contentsOf: url.appendingPathComponent("bruno.json"))).flatMap { try? Value(json: $0) }?.objectValue
        var collection = ImportedCollection(name: config?.string("name") ?? url.lastPathComponent, format: Importer.Format.bruno.rawValue)

        var root = ImportedFolder(name: collection.name)
        if let text = try? String(contentsOf: url.appendingPathComponent("collection.bru"), encoding: .utf8) {
            let file = BruFile(text)
            apply(file, to: &root, isCollection: true, translator: &translator, warnings: &collection.warnings)
            collection.variables += variables(file.dictionary("vars:pre-request"), translator: &translator)
        }
        read(url, into: &root, isRoot: true, root: url, translator: &translator, warnings: &collection.warnings)
        collection.root = root

        let environments = url.appendingPathComponent("environments")
        let files = ((try? manager.contentsOfDirectory(at: environments, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "bru" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let bru = BruFile(text)
            let secretNames = Set(bru.list("vars:secret"))
            var list = variables(bru.dictionary("vars"), translator: &translator)
            for name in secretNames where !bru.dictionary("vars").contains(where: { $0.name == name }) {
                list.append(ImportedVariable(name: translator.identifier(name), value: "", isSecret: true))
            }
            let secretIdentifiers = Set(secretNames.map { translator.identifier($0) })
            for index in list.indices where secretIdentifiers.contains(list[index].name) {
                list[index].isSecret = true
            }
            collection.environments.append(ImportedEnvironment(name: file.deletingPathExtension().lastPathComponent, variables: list))
        }
        if !files.isEmpty, collection.environments.contains(where: { $0.variables.contains(where: { $0.isSecret && $0.value.isEmpty }) }) {
            collection.warnings.append("Bruno keeps secret values out of its files; fill them in environment.local.stamp")
        }
        return collection
    }

    /// Bruno stores a file path relative to the collection, but a .stamp file
    /// reads it relative to itself, so it is written out in full.
    static func resolve(_ path: String, in root: URL) -> String {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("{{") else { return path }
        return root.appendingPathComponent(path).standardizedFileURL.path
    }

    private static func read(_ directory: URL, into folder: inout ImportedFolder, isRoot: Bool, root: URL, translator: inout ImportTranslator, warnings: inout [String]) {
        let manager = FileManager.default
        let items = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []

        var requests: [(seq: Double, request: ImportedRequest)] = []
        for item in items {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                if isRoot, ["environments", "node_modules"].contains(item.lastPathComponent) { continue }
                var child = ImportedFolder(name: item.lastPathComponent)
                if let text = try? String(contentsOf: item.appendingPathComponent("folder.bru"), encoding: .utf8) {
                    let file = BruFile(text)
                    if let name = file.dictionary("meta").first(where: { $0.name == "name" })?.value { child.name = name }
                    apply(file, to: &child, translator: &translator, warnings: &warnings)
                }
                read(item, into: &child, isRoot: false, root: root, translator: &translator, warnings: &warnings)
                if child.requestCount > 0 { folder.folders.append(child) }
            } else if item.pathExtension == "bru", !["collection.bru", "folder.bru"].contains(item.lastPathComponent),
                      let text = try? String(contentsOf: item, encoding: .utf8)
            {
                let file = BruFile(text)
                let seq = Double(file.dictionary("meta").first { $0.name == "seq" }?.value ?? "") ?? .infinity
                if let request = request(file, fallbackName: item.deletingPathExtension().lastPathComponent, root: root, translator: &translator, warnings: &warnings) {
                    requests.append((seq, request))
                }
            }
        }
        folder.requests += requests.sorted { $0.seq < $1.seq }.map(\.request)
        folder.folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Headers, auth and variables that `collection.bru` or `folder.bru` give everything below.
    private static func apply(
        _ file: BruFile, to folder: inout ImportedFolder, isCollection: Bool = false,
        translator: inout ImportTranslator, warnings: inout [String]
    ) {
        folder.headers = file.dictionary("headers").map { ImportedField(name: $0.name, value: translator.mustache($0.value), isEnabled: $0.isEnabled) }
        folder.auth = auth(file, mode: file.dictionary("auth").first { $0.name == "mode" }?.value, translator: &translator)
        if !isCollection {
            // A folder's variables outrank the environment, so they stay with its requests.
            folder.variables = variables(file.dictionary("vars:pre-request"), translator: &translator)
        }
        let scripts = ["script:pre-request", "script:post-response", "tests", "vars:post-response"]
            .filter { file.raw($0) != nil || !file.dictionary($0).isEmpty }
        if !scripts.isEmpty {
            let place = isCollection ? "the collection" : "the folder '\(folder.name)'"
            warnings.append("scripts on \(place) weren't carried over (\(scripts.joined(separator: ", ")))")
        }
    }

    private static func variables(_ entries: [BruFile.Entry], translator: inout ImportTranslator) -> [ImportedVariable] {
        entries.filter(\.isEnabled).map { ImportedVariable(name: translator.identifier($0.name), value: translator.mustache($0.value)) }
    }

    private static func request(_ file: BruFile, fallbackName: String, root: URL, translator: inout ImportTranslator, warnings: inout [String]) -> ImportedRequest? {
        let methods = ["get", "post", "put", "delete", "patch", "options", "head", "connect", "trace"]
        guard let method = methods.first(where: { file.blocks[$0] != nil }) else {
            if file.blocks.keys.contains(where: { $0.hasPrefix("grpc") || $0 == "ws" }) {
                warnings.append("'\(fallbackName)' isn't an HTTP request and wasn't imported")
            }
            return nil
        }
        let meta = file.dictionary("meta")
        let settings = file.dictionary(method)
        func setting(_ key: String) -> String? { settings.first { $0.name == key }?.value }

        var url = setting("url") ?? ""
        var request = ImportedRequest(title: meta.first { $0.name == "name" }?.value ?? fallbackName, method: method.uppercased(), url: "")

        let pathParams = file.dictionary("params:path")
        for param in pathParams {
            url = url.replacingOccurrences(of: ":" + NSRegularExpression.escapedPattern(for: param.name) + "(?=[/?#]|$)", with: "{{\(param.name)}}", options: .regularExpression)
            request.variables.append(ImportedVariable(name: translator.identifier(param.name), value: translator.mustache(param.value)))
        }
        // Query parameters are part of the URL in Bruno already; disabled ones are only in the block.
        request.url = translator.mustache(url)
        request.headers = file.dictionary("headers").map { ImportedField(name: $0.name, value: translator.mustache($0.value), isEnabled: $0.isEnabled) }
        request.auth = auth(file, mode: setting("auth"), translator: &translator)
        request.description = file.raw("docs")

        switch setting("body") {
        case "json", "text", "xml", "sparql":
            if let text = file.raw("body:\(setting("body")!)") { request.body = .text(translator.mustache(text)) }
            if setting("body") == "xml", !request.headers.contains(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
                request.headers.append(ImportedField(name: "Content-Type", value: "application/xml"))
            }
        case "formUrlEncoded":
            request.body = .urlEncoded(file.dictionary("body:form-urlencoded").map { ImportedField(name: $0.name, value: translator.mustache($0.value), isEnabled: $0.isEnabled) })
        case "multipartForm":
            var parts: [ImportedField] = []
            for entry in file.dictionary("body:multipart-form") {
                // A part can carry its own type: `photo: @file(a.png) @contentType(image/png)`.
                var text = entry.value
                if let groups = match(text, #"^(.*?)\s*@contentType\(([^)]*)\)\s*$"#) {
                    text = groups[0]
                    if !groups[1].isEmpty { request.notes.append("Part content type not carried over: \(entry.name): \(groups[1])") }
                }
                if let path = match(text, #"^@file\((.*?)\)$"#)?[0] {
                    let file = path.components(separatedBy: "|").first ?? path
                    parts.append(ImportedField(name: entry.name, value: resolve(file, in: root), isEnabled: entry.isEnabled, isFile: true))
                } else {
                    parts.append(ImportedField(name: entry.name, value: translator.mustache(text), isEnabled: entry.isEnabled))
                }
            }
            request.body = .multipart(parts)
        case "file":
            let entries = file.dictionary("body:file")
            var text = (entries.first { $0.isEnabled } ?? entries.first)?.value ?? ""
            var type = ""
            if let groups = match(text, #"^(.*?)\s*@contentType\(([^)]*)\)\s*$"#) {
                text = groups[0]
                type = groups[1]
            }
            if let path = match(text, #"^@file\((.*?)\)$"#)?[0] {
                request.body = .file(resolve(path.components(separatedBy: "|").first ?? path, in: root))
                if !type.isEmpty, !request.headers.contains(where: { $0.isEnabled && $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
                    request.headers.append(ImportedField(name: "Content-Type", value: type))
                }
            } else {
                request.notes.append("A Bruno file body wasn't converted")
            }
        case "graphql":
            request.body = .graphQL(query: translator.mustache(file.raw("body:graphql") ?? ""), variables: file.raw("body:graphql:vars").map { translator.mustache($0) })
        default:
            break
        }

        // Assertions and variables taken from the response.
        for entry in file.dictionary("assert") where entry.isEnabled {
            if let statement = BrunoScript.assertion(entry.name, entry.value, translator: &translator) {
                request.script.append(statement)
            } else {
                request.notes.append("Assertion not converted: \(entry.name): \(entry.value)")
            }
        }
        for entry in file.dictionary("vars:post-response") where entry.isEnabled {
            if let path = BrunoScript.responsePath(entry.value) {
                request.script.append("set \(translator.identifier(entry.name)) = \(path)")
            } else {
                request.notes.append("Post-response variable not converted: \(entry.name): \(entry.value)")
            }
        }
        for entry in file.dictionary("vars:pre-request") where entry.isEnabled {
            request.variables.append(ImportedVariable(name: translator.identifier(entry.name), value: translator.mustache(entry.value)))
        }
        for block in ["script:post-response", "tests"] {
            guard let script = file.raw(block) else { continue }
            let (statements, leftovers) = BrunoScript.translate(script.components(separatedBy: "\n"), translator: &translator)
            request.script += statements
            if !leftovers.isEmpty {
                request.notes.append("Bruno \(block == "tests" ? "test" : "post-response") script lines that weren't converted:")
                request.notes += leftovers.prefix(20).map { "  " + $0 }
            }
        }
        if let script = file.raw("script:pre-request"), !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.notes.append("A Bruno pre-request script wasn't converted")
        }
        return request
    }

    private static func auth(_ file: BruFile, mode: String?, translator: inout ImportTranslator) -> ImportedAuth? {
        func value(_ block: String, _ key: String) -> String {
            translator.mustache(file.dictionary(block).first { $0.name == key }?.value ?? "")
        }
        switch mode {
        case nil, "inherit": return nil
        case "none": return ImportedAuth.none
        case "bearer": return .bearer(value("auth:bearer", "token"))
        case "basic": return .basic(username: value("auth:basic", "username"), password: value("auth:basic", "password"))
        case "apikey":
            return .apiKey(name: file.dictionary("auth:apikey").first { $0.name == "key" }?.value ?? "X-API-Key",
                           value: value("auth:apikey", "value"), inQuery: value("auth:apikey", "placement") == "queryparams")
        case "oauth2":
            switch file.dictionary("auth:oauth2").first(where: { $0.name == "grant_type" })?.value {
            case "client_credentials":
                return .oauth2ClientCredentials(tokenURL: value("auth:oauth2", "access_token_url"), clientID: value("auth:oauth2", "client_id"),
                                                clientSecret: value("auth:oauth2", "client_secret"), scope: value("auth:oauth2", "scope"))
            case "password":
                return .oauth2Password(tokenURL: value("auth:oauth2", "access_token_url"), clientID: value("auth:oauth2", "client_id"),
                                       clientSecret: value("auth:oauth2", "client_secret"), username: value("auth:oauth2", "username"),
                                       password: value("auth:oauth2", "password"), scope: value("auth:oauth2", "scope"))
            case let grant:
                return .unsupported("OAuth 2 (\(grant ?? "authorization code"))")
            }
        case let other?:
            return .unsupported(other)
        }
    }
}

/// The blocks of a `.bru` file: `name { key: value }` dictionaries, `name [ items ]`
/// lists, and raw blocks such as `body:json` whose content is kept as written.
struct BruFile {
    struct Entry {
        var name: String
        var value: String
        var isEnabled: Bool
    }

    /// Block contents, without the braces and with the block's indentation removed.
    private(set) var blocks: [String: [String]] = [:]

    init(_ text: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            guard let last = line.last, last == "{" || last == "[" else { continue }
            let name = line.dropLast().trimmingCharacters(in: .whitespaces)
            let closing = last == "{" ? "}" : "]"
            var content: [String] = []
            while index < lines.count, lines[index] != closing {
                content.append(lines[index])
                index += 1
            }
            index += 1
            blocks[name] = content.map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 }
        }
    }

    func raw(_ name: String) -> String? {
        guard let content = blocks[name] else { return nil }
        let text = content.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return text.isEmpty ? nil : text
    }

    func dictionary(_ name: String) -> [Entry] {
        let lines = blocks[name] ?? []
        var entries: [Entry] = []
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            var key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let isEnabled = !key.hasPrefix("~")
            if !isEnabled { key.removeFirst() }
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // A value with line breaks is written between ''' markers, indented by two more spaces.
            if value == "'''" {
                var content: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "'''" {
                    content.append(lines[index].hasPrefix("  ") ? String(lines[index].dropFirst(2)) : lines[index])
                    index += 1
                }
                index += 1
                value = content.joined(separator: "\n")
            }
            entries.append(Entry(name: key, value: value, isEnabled: isEnabled))
        }
        return entries
    }

    func list(_ name: String) -> [String] {
        (blocks[name] ?? []).flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Bruno's assertions and the common lines of its scripts, as Stamp statements.
enum BrunoScript {
    /// `res.status: eq 200` → `assert status == 200`.
    static func assertion(_ subject: String, _ condition: String, translator: inout ImportTranslator) -> String? {
        guard let left = responsePath(subject) else { return nil }
        let parts = condition.split(separator: " ", maxSplits: 1).map(String.init)
        let op = parts.first ?? ""
        let right = parts.count > 1 ? literal(parts[1], translator: &translator) : ""
        switch op {
        case "eq": return "assert \(left) == \(right)"
        case "neq": return "assert \(left) != \(right)"
        case "gt": return "assert \(left) > \(right)"
        case "gte": return "assert \(left) >= \(right)"
        case "lt": return "assert \(left) < \(right)"
        case "lte": return "assert \(left) <= \(right)"
        case "contains": return "assert \(left) contains \(right)"
        case "notContains": return "assert !(\(left) contains \(right))"
        case "matches": return "assert \(left) matches \(right)"
        case "startsWith": return "assert \(left) matches \(Value.string("^" + NSRegularExpression.escapedPattern(for: unquoted(parts.count > 1 ? parts[1] : ""))).sourceLiteral)"
        case "endsWith": return "assert \(left) matches \(Value.string(NSRegularExpression.escapedPattern(for: unquoted(parts.count > 1 ? parts[1] : "")) + "$").sourceLiteral)"
        case "length": return "assert \(left).length == \(right)"
        case "isDefined", "isNotNull": return "assert \(left) != null"
        case "isUndefined", "isNull": return "assert \(left) == null"
        case "isTruthy": return "assert \(left)"
        case "isFalsy": return "assert !\(left)"
        case "isEmpty": return "assert \(left).length == 0"
        default: return nil
        }
    }

    /// `res.body.data[0].id` → `body.data[0].id`; `res.status`, `res.headers`, `res.responseTime` likewise.
    static func responsePath(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)
        let accessors = #"((?:\.[A-Za-z_$][\w$]*|\[\d+\]|\[\s*["'][^"']+["']\s*\])*)"#
        if match(text, #"^res\.(?:status|getStatus\(\))$"#) != nil { return "status" }
        if match(text, #"^res\.(?:responseTime|getResponseTime\(\))$"#) != nil { return "time" }
        if let groups = match(text, #"^res\.(?:body|getBody\(\))"# + accessors + "$") {
            return "body" + groups[0].replacingOccurrences(of: "'", with: "\"")
        }
        if let groups = match(text, #"^res\.(?:headers|getHeaders\(\))(?:\.([A-Za-z_][\w-]*)|\[\s*["']([^"']+)["']\s*\])$"#) {
            let name = groups[0].isEmpty ? groups[1] : groups[0]
            return "headers[\(Value.string(name.lowercased()).sourceLiteral)]"
        }
        if let groups = match(text, #"^res\.getHeader\(\s*["']([^"']+)["']\s*\)$"#) {
            return "headers[\(Value.string(groups[0].lowercased()).sourceLiteral)]"
        }
        return nil
    }

    private static func unquoted(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" { return String(text.dropFirst().dropLast()) }
        return text
    }

    /// The right side of an assertion: a number, true/false/null, a `{{variable}}`, or text.
    private static func literal(_ text: String, translator: inout ImportTranslator) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        if Double(text) != nil || ["true", "false", "null"].contains(text) { return text }
        if text.hasPrefix("{{"), text.hasSuffix("}}"), !text.dropFirst(2).dropLast(2).contains("{{") {
            let inner = String(text.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            if inner.hasPrefix("process.env.") {
                return "getenv(\(Value.string(String(inner.dropFirst(12))).sourceLiteral))"
            }
            if !inner.hasPrefix("$"), !inner.isEmpty { return translator.identifier(inner) }
        }
        return Value.string(unquoted(text)).sourceLiteral
    }

    /// A JavaScript value a Stamp assertion can compare against; nil for anything else.
    private static func comparable(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if Double(text) != nil || ["true", "false", "null"].contains(text) { return text }
        if let groups = match(text, #"^"([^"\\]*)"$"#) ?? match(text, #"^'([^'\\]*)'$"#) { return Value.string(groups[0]).sourceLiteral }
        return nil
    }

    static func translate(_ lines: [String], translator: inout ImportTranslator) -> (statements: [String], leftovers: [String]) {
        var statements: [String] = []
        var leftovers: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") { continue }
            if line.range(of: #"^test\(.*(function\s*\(\)|=>)\s*\{$|^\}\);?$|^\};?$"#, options: .regularExpression) != nil { continue }
            if let groups = match(line, #"^expect\((.+?)\)\.to\.(?:equal|eql|eq|be\.equal)\((.+)\)\s*;?$"#), let path = responsePath(groups[0]),
               let value = comparable(groups[1])
            {
                statements.append("assert \(path) == \(value)")
                continue
            }
            if let groups = match(line, #"^bru\.(?:setVar|setEnvVar)\(\s*["']([^"']+)["']\s*,\s*(.+?)\s*\)\s*;?$"#), let path = responsePath(groups[1]) {
                statements.append("set \(translator.identifier(groups[0])) = \(path)")
                continue
            }
            leftovers.append(line)
        }
        return (statements, leftovers)
    }
}

// MARK: OpenCollection YAML

/// Bruno's YAML collections, the OpenCollection format: a folder with
/// `opencollection.yml`, `folder.yml` in folders, request `.yml` files and
/// `environments/*.yml`, or all of it bundled in one file.
enum OpenCollectionImporter {
    static func isCollection(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            return ["opencollection.yml", "opencollection.yaml"].contains { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
        }
        guard ["yml", "yaml", "json"].contains(url.pathExtension.lowercased()),
              let text = try? String(contentsOf: url, encoding: .utf8), text.contains("opencollection")
        else { return false }
        return (try? Importer.parse(text))?.objectValue?["opencollection"] != nil
    }

    static func collection(at url: URL, translator: inout ImportTranslator) throws -> ImportedCollection {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let rootFile = isDirectory.boolValue
            ? ["opencollection.yml", "opencollection.yaml"].map { url.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }!
            : url
        let document = try object(rootFile)
        var collection = ImportedCollection(
            name: document["info"]?.objectValue?.string("name") ?? url.deletingPathExtension().lastPathComponent,
            format: Importer.Format.bruno.rawValue
        )

        // Files a request uploads are stored relative to the collection.
        let root = isDirectory.boolValue ? url : url.deletingLastPathComponent()
        var folder = ImportedFolder(name: collection.name)
        applyDefaults(document["request"]?.objectValue, to: &folder, isCollection: true, collection: &collection, translator: &translator)
        if isDirectory.boolValue {
            read(directory: url, into: &folder, isRoot: true, root: root, collection: &collection, translator: &translator)
            let environments = url.appendingPathComponent("environments")
            let files = ((try? FileManager.default.contentsOfDirectory(at: environments, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["yml", "yaml"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for file in files {
                guard let environment = try? object(file) else { continue }
                collection.environments.append(self.environment(environment, fallbackName: file.deletingPathExtension().lastPathComponent, translator: &translator))
            }
        } else {
            read(items: document.objects("items"), into: &folder, root: root, collection: &collection, translator: &translator)
        }
        for environment in document["config"]?.objectValue?.objects("environments") ?? [] {
            collection.environments.append(self.environment(environment, fallbackName: "Environment", translator: &translator))
        }
        if collection.environments.contains(where: { $0.variables.contains(where: { $0.isSecret && $0.value.isEmpty }) }) {
            collection.warnings.append("Bruno keeps secret values out of its files; fill them in environment.local.stamp")
        }
        collection.root = folder
        return collection
    }

    private static func object(_ url: URL) throws -> ObjectValue {
        guard let object = try Importer.parse(try String(contentsOf: url, encoding: .utf8)).objectValue else {
            throw Importer.Failure(message: "\(url.lastPathComponent) isn't a YAML mapping")
        }
        return object
    }

    // MARK: Structure

    private static func read(directory: URL, into folder: inout ImportedFolder, isRoot: Bool, root: URL, collection: inout ImportedCollection, translator: inout ImportTranslator) {
        let manager = FileManager.default
        let items = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var requests: [(seq: Double, request: ImportedRequest)] = []
        var folders: [(seq: Double, folder: ImportedFolder)] = []

        for item in items {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                if isRoot, ["environments", "node_modules"].contains(item.lastPathComponent) { continue }
                var child = ImportedFolder(name: item.lastPathComponent)
                var seq = Double.infinity
                if let info = try? object(item.appendingPathComponent("folder.yml")) {
                    if let name = info["info"]?.objectValue?.string("name") { child.name = name }
                    seq = info["info"]?.objectValue?["seq"]?.numberValue ?? .infinity
                    applyDefaults(info["request"]?.objectValue, to: &child, isCollection: false, collection: &collection, translator: &translator)
                }
                read(directory: item, into: &child, isRoot: false, root: root, collection: &collection, translator: &translator)
                if child.requestCount > 0 { folders.append((seq, child)) }
            } else if ["yml", "yaml"].contains(item.pathExtension.lowercased()),
                      !["opencollection.yml", "opencollection.yaml", "folder.yml", "folder.yaml"].contains(item.lastPathComponent),
                      let object = try? object(item)
            {
                let seq = object["info"]?.objectValue?["seq"]?.numberValue ?? .infinity
                if let request = request(object, fallbackName: item.deletingPathExtension().lastPathComponent, root: root, collection: &collection, translator: &translator) {
                    requests.append((seq, request))
                }
            }
        }
        folder.requests += requests.sorted { $0.seq < $1.seq }.map(\.request)
        folder.folders += folders.sorted { $0.seq == $1.seq ? $0.folder.name < $1.folder.name : $0.seq < $1.seq }.map(\.folder)
    }

    private static func read(items: [ObjectValue], into folder: inout ImportedFolder, root: URL, collection: inout ImportedCollection, translator: inout ImportTranslator) {
        for item in items {
            if item["items"] != nil || item["info"]?.objectValue?.string("type") == "folder" {
                var child = ImportedFolder(name: item["info"]?.objectValue?.string("name") ?? "Folder")
                applyDefaults(item["request"]?.objectValue, to: &child, isCollection: false, collection: &collection, translator: &translator)
                read(items: item.objects("items"), into: &child, root: root, collection: &collection, translator: &translator)
                folder.folders.append(child)
            } else if let request = request(item, fallbackName: "Request", root: root, collection: &collection, translator: &translator) {
                folder.requests.append(request)
            }
        }
    }

    /// Headers, auth and variables a collection or folder gives everything below.
    private static func applyDefaults(
        _ defaults: ObjectValue?, to folder: inout ImportedFolder, isCollection: Bool,
        collection: inout ImportedCollection, translator: inout ImportTranslator
    ) {
        guard let defaults else { return }
        folder.headers = fields(defaults.objects("headers"), translator: &translator)
        folder.auth = auth(defaults["auth"], translator: &translator)
        let variables = defaults.objects("variables").filter(isEnabled).compactMap { variable(from: $0, translator: &translator) }
        // Only the collection's variables apply everywhere; a folder's stay with its requests.
        if isCollection { collection.variables += variables } else { folder.variables += variables }
        if let scripts = defaults["scripts"]?.arrayValue, !scripts.isEmpty {
            collection.warnings.append("scripts on \(isCollection ? "the collection" : "the folder '\(folder.name)'") weren't carried over")
        }
    }

    // MARK: Requests

    private static func request(_ object: ObjectValue, fallbackName: String, root: URL, collection: inout ImportedCollection, translator: inout ImportTranslator) -> ImportedRequest? {
        let info = object["info"]?.objectValue ?? ObjectValue()
        let name = info.string("name") ?? fallbackName
        guard let details = object["http"]?.objectValue ?? object["graphql"]?.objectValue else {
            if object["grpc"] != nil || object["websocket"] != nil || ["grpc", "ws", "websocket"].contains(info.string("type") ?? "") {
                collection.warnings.append("'\(name)' isn't an HTTP request and wasn't imported")
            }
            return nil
        }
        let isGraphQL = object["graphql"] != nil

        var url = details.string("url") ?? ""
        var request = ImportedRequest(title: name, method: (details.string("method") ?? (isGraphQL ? "POST" : "GET")).uppercased(), url: "")
        for param in details.objects("params") where param.string("type") == "path" {
            guard let paramName = param.string("name") else { continue }
            url = url.replacingOccurrences(of: ":" + NSRegularExpression.escapedPattern(for: paramName) + "(?=[/?#]|$)", with: "{{\(paramName)}}", options: .regularExpression)
            request.variables.append(ImportedVariable(name: translator.identifier(paramName), value: translator.mustache(param.string("value") ?? "")))
        }
        request.url = translator.mustache(url)
        request.headers = fields(details.objects("headers"), translator: &translator)
        // The format writes `auth: inherit` when a request inherits, so a missing one sends nothing.
        request.auth = details["auth"] == nil ? ImportedAuth.none : auth(details["auth"], translator: &translator)
        request.description = text(object["docs"]) ?? text(info["description"])
        request.body = body(details["body"], isGraphQL: isGraphQL, root: root, translator: &translator)

        let runtime = object["runtime"]?.objectValue ?? ObjectValue()
        for variable in runtime.objects("variables").filter(isEnabled) {
            if let imported = self.variable(from: variable, translator: &translator) { request.variables.append(imported) }
        }
        for assertion in runtime.objects("assertions").filter(isEnabled) {
            let expression = assertion.string("expression") ?? ""
            let condition = [assertion.string("operator") ?? "", assertion.string("value") ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            if let statement = BrunoScript.assertion(expression, condition, translator: &translator) {
                request.script.append(statement)
            } else {
                request.notes.append("Assertion not converted: \(expression) \(condition)")
            }
        }
        for action in runtime.objects("actions").filter(isEnabled) where action.string("type") == "set-variable" {
            let expression = action["selector"]?.objectValue?.string("expression") ?? ""
            let target = action["variable"]?.objectValue?.string("name") ?? ""
            if !target.isEmpty, let path = BrunoScript.responsePath(expression) ?? jsonPath(expression) {
                request.script.append("set \(translator.identifier(target)) = \(path)")
            } else {
                request.notes.append("Action not converted: set \(target) from \(expression)")
            }
        }
        for script in runtime.objects("scripts") {
            let code = script.string("code") ?? ""
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            switch script.string("type") {
            case "tests", "after-response":
                let (statements, leftovers) = BrunoScript.translate(code.components(separatedBy: "\n"), translator: &translator)
                request.script += statements
                if !leftovers.isEmpty {
                    request.notes.append("Bruno script lines that weren't converted:")
                    request.notes += leftovers.prefix(20).map { "  " + $0 }
                }
            default:
                request.notes.append("A Bruno pre-request script wasn't converted")
            }
        }
        return request
    }

    private static func isEnabled(_ object: ObjectValue) -> Bool {
        object.bool("disabled") != true && object.bool("enabled") != false
    }

    private static func fields(_ objects: [ObjectValue], translator: inout ImportTranslator) -> [ImportedField] {
        objects.compactMap { field in
            guard let name = field.string("name") else { return nil }
            return ImportedField(name: name, value: translator.mustache(field.string("value") ?? ""), isEnabled: isEnabled(field))
        }
    }

    private static func text(_ value: Value?) -> String? {
        switch value {
        case .string(let text)?: text
        case .object(let object)?: object.string("content")
        default: nil
        }
    }

    /// `$.data.token` → `body.data.token`.
    private static func jsonPath(_ expression: String) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("$"),
              trimmed.dropFirst().range(of: #"^((\.[A-Za-z_]\w*)|(\[\d+\]))*$"#, options: .regularExpression) != nil
        else { return nil }
        return "body" + trimmed.dropFirst()
    }

    private static func body(_ value: Value?, isGraphQL: Bool, root: URL, translator: inout ImportTranslator) -> ImportedBody? {
        var body: ObjectValue?
        switch value {
        case .object(let object)?: body = object
        case .array(let variants)?:
            let chosen = variants.compactMap(\.objectValue).first { $0.bool("selected") == true } ?? variants.first?.objectValue
            body = chosen?["body"]?.objectValue
        default: break
        }
        guard let body else { return nil }
        if isGraphQL || body["query"] != nil {
            return .graphQL(query: translator.mustache(body.string("query") ?? ""), variables: body.string("variables").map { translator.mustache($0) })
        }
        // `type` with `data`, or the older `mode` with a key named after it.
        let type = body.string("type") ?? body.string("mode") ?? ""
        let data = body["data"] ?? body[type] ?? body[type.replacingOccurrences(of: "-", with: "")]
        switch type {
        case "json", "text", "xml", "sparql":
            guard let text = data?.stringValue, !text.isEmpty else { return nil }
            return .text(translator.mustache(text))
        case "form-urlencoded", "formUrlEncoded":
            return .urlEncoded(fields(data?.arrayValue?.compactMap(\.objectValue) ?? [], translator: &translator))
        case "multipart-form", "multipartForm":
            return .multipart((data?.arrayValue ?? []).compactMap(\.objectValue).compactMap { part in
                guard let name = part.string("name") else { return nil }
                let isFile = part.string("type") == "file"
                let value = part["value"]?.stringValue ?? part["value"]?.arrayValue?.first?.stringValue ?? ""
                return ImportedField(
                    name: name, value: isFile ? BrunoImporter.resolve(value, in: root) : translator.mustache(value),
                    isEnabled: isEnabled(part), isFile: isFile
                )
            })
        case "file":
            let files = (data?.arrayValue ?? []).compactMap(\.objectValue)
            guard let path = (files.first { $0.bool("selected") == true } ?? files.first)?.string("filePath") else { return nil }
            return .file(BrunoImporter.resolve(path, in: root))
        default:
            return nil
        }
    }

    private static func auth(_ value: Value?, translator: inout ImportTranslator) -> ImportedAuth? {
        guard case .object(let auth)? = value, let type = auth.string("type") else {
            return value?.stringValue == "none" ? ImportedAuth.none : nil
        }
        func setting(_ object: ObjectValue?, _ key: String) -> String { translator.mustache(object?.string(key) ?? "") }
        switch type {
        case "none": return ImportedAuth.none
        case "inherit": return nil
        case "bearer": return .bearer(setting(auth, "token"))
        case "basic": return .basic(username: setting(auth, "username"), password: setting(auth, "password"))
        case "apikey": return .apiKey(name: auth.string("key") ?? "X-API-Key", value: setting(auth, "value"), inQuery: auth.string("placement")?.hasPrefix("query") == true)
        case "oauth2":
            let credentials = auth["credentials"]?.objectValue
            switch auth.string("flow") {
            case "client_credentials":
                return .oauth2ClientCredentials(tokenURL: setting(auth, "accessTokenUrl"), clientID: setting(credentials, "clientId"),
                                                clientSecret: setting(credentials, "clientSecret"), scope: auth.string("scope"))
            case "resource_owner_password_credentials":
                let owner = auth["resourceOwner"]?.objectValue
                return .oauth2Password(tokenURL: setting(auth, "accessTokenUrl"), clientID: setting(credentials, "clientId"),
                                       clientSecret: setting(credentials, "clientSecret"), username: setting(owner, "username"),
                                       password: setting(owner, "password"), scope: auth.string("scope"))
            case let flow:
                return .unsupported("OAuth 2 (\(flow ?? "authorization code"))")
            }
        default:
            return .unsupported(type)
        }
    }

    // MARK: Environments

    private static func environment(_ object: ObjectValue, fallbackName: String, translator: inout ImportTranslator) -> ImportedEnvironment {
        let variables = object.objects("variables").filter(isEnabled).compactMap { variable(from: $0, translator: &translator) }
        return ImportedEnvironment(name: object.string("name") ?? fallbackName, variables: variables)
    }

    private static func variable(from object: ObjectValue, translator: inout ImportTranslator) -> ImportedVariable? {
        guard let name = object.string("name") else { return nil }
        var value = ""
        switch object["value"] {
        case .string(let text)?: value = text
        case .object(let typed)?: value = typed.string("data") ?? ""
        case .array(let variants)?:
            let chosen = variants.compactMap(\.objectValue).first { $0.bool("selected") == true } ?? variants.first?.objectValue
            switch chosen?["value"] {
            case .string(let text)?: value = text
            case .object(let typed)?: value = typed.string("data") ?? ""
            default: break
            }
        case .number?, .bool?: value = object["value"]!.interpolated
        default: break
        }
        return ImportedVariable(name: translator.identifier(name), value: translator.mustache(value), isSecret: object.bool("secret") == true)
    }
}
