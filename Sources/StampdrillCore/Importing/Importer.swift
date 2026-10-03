import Foundation
import Stamp

/// Brings requests in from other tools: Postman collections and environments,
/// Insomnia and Bruno exports, HAR files, curl commands and OpenAPI documents.
///
/// Formats are recognised by their content. Several inputs can go in at once,
/// such as a Postman collection with its environments.
public enum Importer {
    public enum Format: String, Sendable, CaseIterable {
        case openAPI = "OpenAPI document"
        case postman = "Postman collection"
        case postmanEnvironment = "Postman environment"
        case insomnia = "Insomnia export"
        case bruno = "Bruno collection"
        case har = "HAR file"
        case curl = "curl command"
    }

    public struct Output {
        public var title: String
        public var format: String
        /// Request files, relative to the folder the import goes into.
        public var files: [(path: String, text: String)]
        public var environment: ImportedEnvironmentChanges
        public var requestCount: Int
        /// Things that couldn't be carried over as they were.
        public var warnings: [String]
    }

    public struct Failure: Error, LocalizedError, Sendable {
        public var message: String
        public var errorDescription: String? { message }
    }

    public static let supportedDescription =
        "a Postman collection or environment, an Insomnia export, a Bruno collection folder, a HAR file, curl commands, or an OpenAPI document"

    /// Reads every input and writes one import. OpenAPI documents are converted on their own.
    ///
    /// `existingNames` are the variables the workspace already declares: imported
    /// ones never take those names, so an import can't change what an existing
    /// request sends, or reuse a credential from an earlier import.
    public static func convert(_ urls: [URL], existingNames: Set<String> = []) throws -> Output {
        guard !urls.isEmpty else { throw Failure(message: "Nothing to import") }
        var collections: [ImportedCollection] = []
        var environments: [(ImportedEnvironment, [String])] = []
        var translator = ImportTranslator()
        translator.reserve(existingNames)

        for url in urls {
            let format = try detect(url)
            switch format {
            case .openAPI:
                guard urls.count == 1 else { throw Failure(message: "Import an OpenAPI document on its own") }
                let output = try OpenAPIImporter.convert(try Data(contentsOf: url))
                return Output(
                    title: output.title, format: format.rawValue, files: output.files, environment: ImportedEnvironmentChanges(),
                    requestCount: output.operationCount, warnings: []
                )
            case .postmanEnvironment:
                let (environment, isGlobals) = try PostmanImporter.environment(try object(url), translator: &translator)
                if isGlobals {
                    var globals = ImportedCollection(name: environment.name, format: format.rawValue)
                    globals.variables = environment.variables
                    collections.append(globals)
                } else {
                    environments.append((environment, []))
                }
            case .postman:
                collections.append(try PostmanImporter.collection(try object(url), translator: &translator))
            case .insomnia:
                collections.append(try InsomniaImporter.collection(try value(url), translator: &translator))
            case .bruno:
                if OpenCollectionImporter.isCollection(url) {
                    collections.append(try OpenCollectionImporter.collection(at: url, translator: &translator))
                } else {
                    collections.append(try BrunoImporter.collection(at: url, translator: &translator))
                }
            case .har:
                collections.append(try HARImporter.collection(try object(url), translator: &translator))
            case .curl:
                collections.append(try CurlImporter.collection(decoded(try Data(contentsOf: url)), translator: &translator))
            }
        }

        var merged: ImportedCollection
        if let baseIndex = collections.firstIndex(where: { $0.requestCount > 0 }) ?? (collections.isEmpty ? nil : 0) {
            merged = collections[baseIndex]
            for (index, collection) in collections.enumerated() where index != baseIndex {
                var other = collection
                // Two collections often both call something `baseUrl`; the second keeps its own.
                for variable in collection.variables {
                    guard let clash = merged.variables.first(where: { $0.name == variable.name }), clash.value != variable.value else { continue }
                    let renamed = translator.uniqueName(variable.name)
                    other = other.rewriting(variable.name, to: renamed)
                    merged.warnings.append("'\(collection.name)' also has a variable called \(variable.name); its own is now \(renamed)")
                }
                if other.requestCount > 0 {
                    var folder = other.root
                    folder.name = other.name
                    merged.root.folders.append(folder)
                }
                merged.variables += other.variables.filter { variable in
                    !merged.variables.contains { $0.name == variable.name && $0.value == variable.value }
                }
                merged.environments += other.environments
                merged.warnings += other.warnings
            }
        } else {
            merged = ImportedCollection(name: environments.first?.0.name ?? "Environments", format: Format.postmanEnvironment.rawValue)
        }
        merged.environments += environments.map(\.0)
        merged.translator = translator
        let output = ImportWriter.output(merged)
        guard !output.files.isEmpty || !output.environment.isEmpty else {
            throw Failure(message: "There is nothing to import in \(urls.map(\.lastPathComponent).joined(separator: ", ")): no requests and no environments")
        }
        return output
    }

    /// curl commands as request blocks, for adding to a file.
    /// `avoiding` are request names the file already has.
    public static func requests(
        fromCurl text: String, avoiding: Set<String> = [], existingNames: Set<String> = []
    ) throws -> (text: String, environment: ImportedEnvironmentChanges, names: [String]) {
        var translator = ImportTranslator()
        translator.reserve(existingNames)
        var collection = try CurlImporter.collection(text, translator: &translator)
        collection.translator = translator
        return ImportWriter.blocks(collection, avoiding: avoiding)
    }

    /// Whether text looks like one or more curl commands.
    public static func looksLikeCurl(_ text: String) -> Bool {
        CurlImporter.commands(in: text).isEmpty == false
    }

    /// A folder name for an import's title, without path separators or a leading dot.
    public static func folderName(for title: String) -> String {
        ImportWriter.fileName(title)
    }

    public static func detect(_ url: URL) throws -> Format {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw Failure(message: "\(url.lastPathComponent) doesn't exist")
        }
        if isDirectory.boolValue {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("bruno.json").path) || OpenCollectionImporter.isCollection(url) { return .bruno }
            throw Failure(message: "\(url.lastPathComponent) is a folder, but not a Bruno collection (it has neither bruno.json nor opencollection.yml)")
        }
        if url.pathExtension.lowercased() == "bru" { return .bruno }

        let text = Self.decoded(try Data(contentsOf: url).prefix(4_000_000))
        // Structured formats first: a YAML document can hold a curl example in a description.
        if case .object(let object)? = try? parse(text) {
            if object["openapi"] != nil || object["swagger"] != nil { return .openAPI }
            if object["opencollection"] != nil { return .bruno }
            if let info = object["info"]?.objectValue, info["_postman_id"] != nil || info["schema"]?.stringValue?.contains("postman") == true {
                return .postman
            }
            if object["_postman_variable_scope"] != nil || (object["values"]?.arrayValue != nil && object["name"] != nil) {
                return .postmanEnvironment
            }
            if object["_type"]?.stringValue == "export" || object["type"]?.stringValue?.contains("insomnia") == true {
                return .insomnia
            }
            if object["log"]?.objectValue?["entries"] != nil { return .har }
            if object.string("method") != nil, object.string("url") != nil, object["httpVersion"] != nil || object["headers"] != nil { return .har }
        }
        if !CurlImporter.commands(in: text).isEmpty { return .curl }
        throw Failure(message: "\(url.lastPathComponent) isn't something Stampdrill can import: choose \(supportedDescription)")
    }

    /// Text of a file, without the byte-order mark some Windows tools write.
    static func decoded(_ data: some DataProtocol) -> String {
        var text = String(decoding: data, as: UTF8.self)
        if text.first == "\u{FEFF}" { text.removeFirst() }
        return text
    }

    static func parse(_ text: String) throws -> Value {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return try Value(json: Data(trimmed.utf8)) }
        return try YAML.parse(text)
    }

    private static func value(_ url: URL) throws -> Value {
        try parse(decoded(try Data(contentsOf: url)))
    }

    private static func object(_ url: URL) throws -> ObjectValue {
        guard case .object(let object) = try value(url) else { throw Failure(message: "\(url.lastPathComponent) isn't a JSON object") }
        return object
    }
}

// MARK: Reading helpers

extension ObjectValue {
    func string(_ key: String) -> String? {
        switch self[key] {
        case .string(let text)?: text
        case .number?, .bool?: self[key]!.interpolated
        default: nil
        }
    }

    func array(_ key: String) -> [Value] { self[key]?.arrayValue ?? [] }

    func objects(_ key: String) -> [ObjectValue] { array(key).compactMap(\.objectValue) }

    func bool(_ key: String) -> Bool? {
        if case .bool(let flag)? = self[key] { return flag }
        return nil
    }
}

/// A title for a request from its method and URL: `GET /users/{id}`.
func requestTitle(method: String, url: String) -> String {
    var path = url
    if let schemeEnd = path.range(of: "://") { path = String(path[schemeEnd.upperBound...]) }
    if path.hasPrefix("{{"), let close = path.range(of: "}}") { path = String(path[close.upperBound...]) }
    else if let slash = path.firstIndex(of: "/") { path = String(path[slash...]) }
    else { path = "/" }
    if let query = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<query]) }
    return "\(method.uppercased()) \(path.isEmpty ? "/" : path)"
}
