import Foundation
import Stamp

/// Writes an imported collection as request files and environment changes.
///
/// A folder with requests becomes one `.stamp` file, and nested folders
/// become folders. Environments become values of an `environment` dimension.
/// Tokens, passwords and cookies written out literally move to
/// `environment.local.stamp`, so they don't end up in git.
struct ImportWriter {
    private var collection: ImportedCollection
    private var translator: ImportTranslator
    private var names: [String: String] = [:]
    /// Request names that exist already, outside the import.
    private var taken: Set<String> = []
    private var secrets: [String: String] = [:]
    /// Variables whose values all belong in `environment.local.stamp`.
    private var secretNames: Set<String> = []
    private var changes = ImportedEnvironmentChanges()

    init(_ collection: ImportedCollection) {
        self.collection = collection
        translator = collection.translator
    }

    static func output(_ collection: ImportedCollection) -> Importer.Output {
        var writer = ImportWriter(collection)
        return writer.write()
    }

    /// Request blocks only, for adding to a file that already exists.
    static func blocks(_ collection: ImportedCollection, avoiding: Set<String> = []) -> (text: String, environment: ImportedEnvironmentChanges, names: [String]) {
        var writer = ImportWriter(collection)
        writer.taken = avoiding
        writer.nameRequests(in: collection.root)
        writer.writeVariables()
        var blocks: [String] = []
        var requestNames: [String] = []
        for (request, folders) in Self.requests(in: collection.root, parents: []) {
            blocks.append(writer.block(request, folders: folders).joined(separator: "\n"))
            requestNames.append(writer.names[request.id] ?? "")
        }
        return (blocks.joined(separator: "\n\n"), writer.changes, requestNames)
    }

    private mutating func write() -> Importer.Output {
        nameRequests(in: collection.root)
        writeVariables()

        var files: [(path: String, text: String)] = []
        // The workspace's own files; a folder with one of these names gets a number.
        var usedPaths: Set<String> = ["environment", "environment.local"]
        var byFile: [(path: String, lines: [String])] = []

        func add(_ folder: ImportedFolder, path: [String], parents: [ImportedFolder]) {
            let chain = parents + [folder]
            if !folder.requests.isEmpty {
                var file = (path.isEmpty ? ["Requests"] : path).joined(separator: "/")
                var counter = 2
                let base = file
                while !usedPaths.insert(file.lowercased()).inserted {
                    file = base + " \(counter)"
                    counter += 1
                }
                let title = ([collection.name] + path).joined(separator: " · ")
                var lines = ["# \(title)", "# Imported from \(article(collection.format)) \(collection.format); edit freely.", ""]
                for request in folder.requests {
                    lines += block(request, folders: chain)
                    lines.append("")
                }
                byFile.append((file + ".stamp", lines))
            }
            for child in folder.folders {
                add(child, path: path + [Self.fileName(child.name)], parents: chain)
            }
        }
        add(collection.root, path: [], parents: [])

        for (path, lines) in byFile {
            var lines = lines
            while lines.last == "" { lines.removeLast() }
            files.append((path, lines.joined(separator: "\n") + "\n"))
        }
        return Importer.Output(
            title: collection.name, format: collection.format, files: files, environment: changes,
            requestCount: collection.requestCount, warnings: collection.warnings + translator.warnings
        )
    }

    private func article(_ noun: String) -> String {
        noun.first.map { "aeiouAEIOU".contains($0) } == true ? "an" : "a"
    }

    /// Every request with the folders it sits in, outermost first.
    private static func requests(in folder: ImportedFolder, parents: [ImportedFolder]) -> [(ImportedRequest, [ImportedFolder])] {
        let chain = parents + [folder]
        return folder.requests.map { ($0, chain) } + folder.folders.flatMap { requests(in: $0, parents: chain) }
    }

    // MARK: Names

    /// Request names follow the title, as the parser derives them, and are unique across the import.
    private mutating func nameRequests(in folder: ImportedFolder) {
        for request in folder.requests {
            var name = request.title.stampIdentifier ?? "request"
            let base = name
            var counter = 2
            // A response is addressed by the request's name, so it must not be a variable's.
            while names.values.contains(name) || taken.contains(name) || translator.used.contains(name) {
                name = ImportTranslator.numbered(base, counter)
                counter += 1
            }
            names[request.id] = name
        }
        for child in folder.folders { nameRequests(in: child) }
    }

    /// `⟦request:ID⟧` in a template is the name of the request with that id.
    private func resolvingReferences(_ text: String) -> String {
        guard text.contains("⟦request:") else { return text }
        var result = text
        for (id, name) in names {
            result = result.replacingOccurrences(of: "⟦request:\(id)⟧", with: name)
        }
        return result
    }

    static func reference(to id: String) -> String {
        "⟦request:\(id)⟧"
    }

    // MARK: Environments

    private mutating func writeVariables() {
        // A name is secret if any of its values is: the local file outranks the
        // shared one, so splitting a name across both would change which value wins.
        secretNames = Set((collection.variables + collection.environments.flatMap(\.variables)).filter(isSecret).map(\.name))
        for variable in collection.variables {
            add(variable, conditions: [])
        }
        guard !collection.environments.isEmpty else { return }
        var values: [String] = []
        for environment in collection.environments {
            var value = Self.dimensionValue(environment.name)
            let base = value
            var counter = 2
            while values.contains(value) {
                value = "\(base)-\(counter)"
                counter += 1
            }
            values.append(value)
            for variable in environment.variables {
                add(variable, conditions: [VariableSet.Condition(dimension: "environment", values: [value])])
            }
        }
        changes.dimension = ("environment", values)
    }

    /// Whether this value should stay out of the shared file.
    private func isSecret(_ variable: ImportedVariable) -> Bool {
        if variable.isSecret { return true }
        if variable.isSecretKnown { return false }
        let looksLikeAddress = variable.value.hasPrefix("http://") || variable.value.hasPrefix("https://")
        return !looksLikeAddress && SensitiveData.isSensitiveName(variable.name) && !variable.value.contains("{{") && !variable.value.isEmpty
    }

    private mutating func add(_ variable: ImportedVariable, conditions: [VariableSet.Condition]) {
        let expression = ImportTranslator.expression(forTemplate: resolvingReferences(variable.value))
        // Only a literal is wrapped in secret(); a template keeps referring to other variables.
        let hidden = secretNames.contains(variable.name)
        let wraps = hidden && !variable.value.contains("{{")
        let entry = ImportedEnvironmentChanges.Entry(conditions: conditions, name: variable.name, source: wraps ? "secret(\(expression))" : expression)
        if hidden { changes.local.append(entry) } else { changes.shared.append(entry) }
    }

    /// `Local Dev` → `local-dev`.
    static func dimensionValue(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        var value = ""
        for character in folded {
            if character.isASCII, character.isLetter || character.isNumber || "_.".contains(character) {
                value.append(character)
            } else if !value.hasSuffix("-") {
                value.append("-")
            }
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return value.isEmpty ? "default" : value
    }

    /// A literal credential becomes a secret variable in the local environment; a template stays.
    private mutating func secretReference(_ value: String, preferred: String) -> String {
        guard !value.isEmpty, !value.contains("{{") else { return value }
        let key = preferred.lowercased() + "\u{0}" + value
        if let known = secrets[key] { return "{{\(known)}}" }
        let name = translator.uniqueName(preferred, camelCase: true)
        secrets[key] = name
        changes.local.append(.init(conditions: [], name: name, source: "secret(\(Value.string(value).sourceLiteral))"))
        return "{{\(name)}}"
    }

    // MARK: Requests

    private mutating func block(_ request: ImportedRequest, folders: [ImportedFolder]) -> [String] {
        let name = names[request.id] ?? "request"
        var lines = ["### " + oneLine(request.title)]
        if let description = request.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            for line in description.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).prefix(3) {
                lines.append("# " + line.trimmingCharacters(in: .whitespaces))
            }
        }
        for note in request.notes { lines.append("# " + note) }
        if request.title.stampIdentifier != name { lines.append("@name \(name)") }

        // A folder's variables apply to the requests below it, innermost last so it wins.
        for variable in folders.flatMap(\.variables) + request.variables {
            var value = oneLine(resolvingReferences(variable.value))
            if SensitiveData.isSensitiveName(variable.name) {
                value = secretReference(value, preferred: variable.name)
            }
            lines.append("@\(variable.name) = \(value)")
        }

        let dependencies = (folders.flatMap(\.dependencies) + request.dependencies).compactMap { names[$0] }
            .filter { $0 != name }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if !dependencies.isEmpty { lines.append("@needs " + dependencies.joined(separator: ", ")) }
        lines += request.directives

        let auth = request.auth ?? folders.reversed().lazy.compactMap(\.auth).first
        if let auth, let line = authLine(auth, request: name) { lines.append(line) }

        var method = request.method.uppercased().filter { $0.isLetter }
        if method.isEmpty { method = "GET" }
        if case .graphQL? = request.body { method = "GRAPHQL" }
        lines.append("\(method) \(target(secretQueryValues(in: resolvingReferences(request.url))))")

        // A request's enabled header replaces the inherited one of the same name;
        // a disabled one is kept as a comment and changes nothing.
        var headers: [ImportedField] = []
        let overridden = Set(request.headers.filter(\.isEnabled).map { $0.name.lowercased() })
        for header in folders.flatMap(\.headers) where !(header.isEnabled && overridden.contains(header.name.lowercased())) {
            if header.isEnabled { headers.removeAll { $0.isEnabled && $0.name.caseInsensitiveCompare(header.name) == .orderedSame } }
            headers.append(header)
        }
        headers += request.headers
        if let contentType = contentType(for: request.body),
           !headers.contains(where: { $0.isEnabled && $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame })
        {
            headers.append(ImportedField(name: "Content-Type", value: contentType))
        }
        for header in headers {
            let headerName = header.name.trimmingCharacters(in: .whitespaces)
            guard !headerName.isEmpty, headerName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.!#$%&'*+^`|~".contains($0)) }) else {
                lines.append("# Header not carried over: \(oneLine(header.name)): \(oneLine(header.value))")
                continue
            }
            var value = escapingDollarNames(oneLine(resolvingReferences(header.value)))
            if SensitiveData.isSensitiveName(headerName) {
                value = secretReference(value, preferred: headerName)
            }
            lines.append((header.isEnabled ? "" : "# ") + "\(headerName): \(value)")
        }

        if let body = body(request.body) {
            lines.append("")
            lines += body
        }
        let script = request.script.map(resolvingReferences)
        if !script.isEmpty {
            lines.append("")
            lines += script.map { "> " + $0 }
        }
        return lines
    }

    private func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// The URL with spaces encoded outside `{{ }}`, so the request line stays one word.
    private func target(_ url: String) -> String {
        var result = ""
        var depth = 0
        var previous: Character?
        for character in oneLine(url) {
            if character == "{", previous == "{" { depth += 1 }
            if character == "}", previous == "}" { depth = max(depth - 1, 0) }
            result += character == " " && depth == 0 ? "%20" : String(character)
            previous = character
        }
        return result.isEmpty ? "https://" : escapingDollarNames(result)
    }

    /// `$top` in a request line or header names a variable, so a literal `$` before
    /// a name the import uses is written as an expression.
    private func escapingDollarNames(_ text: String) -> String {
        guard text.contains("$") else { return text }
        var result = ""
        var rest = Substring(text)
        while let mark = rest.firstIndex(of: "$") {
            result += rest[..<mark]
            let after = rest[rest.index(after: mark)...]
            let name = after.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty, translator.used.contains(String(name)) {
                result += "{{\"$\"}}"
            } else {
                result += "$"
            }
            rest = after
        }
        return result + rest
    }

    private mutating func authLine(_ auth: ImportedAuth, request: String) -> String? {
        switch auth {
        case .none:
            return nil
        case .bearer(let token):
            return "@auth bearer " + argument(secretReference(token, preferred: "token"))
        case .basic(let username, let password):
            return "@auth basic " + argument(username) + " " + argument(secretReference(password, preferred: "password"))
        case .apiKey(let name, let value, let inQuery):
            return "@auth apikey " + argument(name) + " " + argument(secretReference(value, preferred: name)) + (inQuery ? " query" : " header")
        case .oauth2ClientCredentials(let tokenURL, let clientID, let clientSecret, let scope):
            var line = "@auth oauth2 client_credentials token_url=\(argument(tokenURL)) client_id=\(argument(clientID))"
            if !clientSecret.isEmpty { line += " client_secret=" + argument(secretReference(clientSecret, preferred: "clientSecret")) }
            if let scope, !scope.isEmpty { line += " scope=" + argument(scope) }
            return line
        case .oauth2Password(let tokenURL, let clientID, let clientSecret, let username, let password, let scope):
            var line = "@auth oauth2 password token_url=\(argument(tokenURL)) client_id=\(argument(clientID))"
            if !clientSecret.isEmpty { line += " client_secret=" + argument(secretReference(clientSecret, preferred: "clientSecret")) }
            line += " username=\(argument(username)) password=" + argument(secretReference(password, preferred: "password"))
            if let scope, !scope.isEmpty { line += " scope=" + argument(scope) }
            return line
        case .unsupported(let kind):
            translator.warn("\(kind) authentication has no @auth equivalent; set it up by hand where it's noted")
            return "# Authentication not carried over: \(kind)"
        }
    }

    /// An `@auth` argument. The directive's parser keeps `{{ … }}` together and
    /// has no backslash escapes, so quotes are only added when they are needed
    /// and never escaped.
    private func argument(_ text: String) -> String {
        let text = oneLine(resolvingReferences(text))
        if text.isEmpty { return "\"\"" }
        var needsQuotes = false
        var depth = 0
        var previous: Character?
        for character in text {
            if character == "{", previous == "{" { depth += 1 }
            if character == "}", previous == "}" { depth = max(depth - 1, 0) }
            if depth == 0, character == " " || character == "\t" || character == "\"" || character == "'" { needsQuotes = true }
            previous = character
        }
        if !needsQuotes { return text }
        if !text.contains("\"") { return "\"" + text + "\"" }
        if !text.contains("'") { return "'" + text + "'" }
        // Both kinds of quote: write it as an expression, which takes escapes.
        return "{{" + Value.string(text).sourceLiteral + "}}"
    }

    /// Replaces the value of query parameters with sensitive names, such as `?access_token=…`.
    private mutating func secretQueryValues(in url: String) -> String {
        guard let mark = url.firstIndex(of: "?") else { return url }
        let query = url[url.index(after: mark)...]
        guard !query.isEmpty else { return url }
        var parts: [String] = []
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            guard let equals = pair.firstIndex(of: "="), !pair.contains("{{") else {
                parts.append(String(pair))
                continue
            }
            let name = String(pair[..<equals])
            let value = String(pair[pair.index(after: equals)...])
            guard !value.isEmpty, SensitiveData.isSensitiveName(name) else {
                parts.append(String(pair))
                continue
            }
            let decoded = value.removingPercentEncoding ?? value
            parts.append(name + "=" + secretReference(decoded, preferred: name))
        }
        return String(url[..<mark]) + "?" + parts.joined(separator: "&")
    }

    private func contentType(for body: ImportedBody?) -> String? {
        switch body {
        case .urlEncoded?: "application/x-www-form-urlencoded"
        case .multipart?: "multipart/form-data"
        case .text(let text)?:
            text.trimmingCharacters(in: .whitespacesAndNewlines).first.map { $0 == "{" || $0 == "[" } == true ? "application/json" : nil
        default: nil
        }
    }

    private mutating func body(_ body: ImportedBody?) -> [String]? {
        switch body {
        case nil:
            return nil
        case .text(let text)?:
            let trimmed = resolvingReferences(text).trimmingCharacters(in: .newlines)
            guard !trimmed.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return safeBody(trimmed)
        case .file(let path)?:
            return ["< " + path]
        case .urlEncoded(let fields)?, .multipart(let fields)?:
            var lines: [String] = []
            for field in fields {
                let name = oneLine(field.name)
                guard !name.isEmpty, !name.contains(" "), !name.contains("=") else {
                    translator.warn("the form field '\(name)' has a name a .stamp form can't hold; it was left out")
                    continue
                }
                if !field.isEnabled {
                    continue
                }
                let resolved = resolvingReferences(field.value)
                if field.isFile {
                    lines.append("\(name) = < \(oneLine(resolved))")
                } else if SensitiveData.isSensitiveName(name) {
                    lines.append("\(name) = \(secretReference(oneLine(resolved), preferred: name))")
                } else if resolved.contains(where: \.isNewline) {
                    // A form value is one line, so line breaks are kept in an expression.
                    lines.append("\(name) = {{\(ImportTranslator.expression(forTemplate: resolved))}}")
                } else {
                    lines.append("\(name) = \(resolved)")
                }
            }
            return lines.isEmpty ? nil : lines
        case .graphQL(let query, let variables)?:
            var lines = safeBody(resolvingReferences(query).trimmingCharacters(in: .whitespacesAndNewlines))
            if let variables = variables?.trimmingCharacters(in: .whitespacesAndNewlines), !variables.isEmpty, variables != "{}" {
                lines.append("")
                lines += safeBody(resolvingReferences(variables))
            }
            return lines
        }
    }

    /// Body lines that would otherwise end the request: `>` starts a script line,
    /// and `###` starts the next request even when it is indented.
    private mutating func safeBody(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("###") {
                translator.warn("a body line started with '###', which would start the next request; it is written as an expression that sends the same text")
                let hashes = line.drop { $0 == " " || $0 == "\t" }.prefix { $0 == "#" }
                return "{{\(Value.string(String(hashes)).sourceLiteral)}}" + line.drop { $0 == " " || $0 == "\t" }.dropFirst(hashes.count)
            }
            if line.hasPrefix(">") {
                translator.warn("a body line started with '>'; it was indented by a space so it stays in the body")
                return " " + line
            }
            return String(line)
        }
    }

    public static func fileName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return cleaned.isEmpty ? "Requests" : cleaned
    }
}
