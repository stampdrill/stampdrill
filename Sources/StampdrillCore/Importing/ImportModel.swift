import Foundation
import Stamp

/// A collection read from another tool, before it is written as `.stamp` files.
/// Every text in it is already a Stamp template: `{{name}}` with names that
/// are valid identifiers.
public struct ImportedCollection {
    public var name: String
    /// What it was read from, such as "Postman collection".
    public var format: String
    public var root: ImportedFolder
    /// Variables for every environment.
    public var variables: [ImportedVariable] = []
    public var environments: [ImportedEnvironment] = []
    public var warnings: [String] = []
    /// The names given out so far, so the writer's own variables don't clash with them.
    var translator = ImportTranslator()

    public init(name: String, format: String, root: ImportedFolder = ImportedFolder(name: "")) {
        self.name = name
        self.format = format
        self.root = root
    }

    public var requestCount: Int { root.requestCount }
}

public struct ImportedFolder {
    public var name: String
    public var requests: [ImportedRequest] = []
    public var folders: [ImportedFolder] = []
    /// Applies to requests below that don't set their own.
    public var auth: ImportedAuth?
    /// Headers every request below sends, unless it sets the same one.
    public var headers: [ImportedField] = []
    /// Variables for the requests below; the innermost folder wins.
    public var variables: [ImportedVariable] = []
    /// Requests whose responses the folder's own headers or auth use.
    public var dependencies: [String] = []

    public init(name: String) {
        self.name = name
    }

    var requestCount: Int { requests.count + folders.reduce(0) { $0 + $1.requestCount } }
}

public struct ImportedField: Equatable {
    public var name: String
    public var value: String
    public var isEnabled = true
    /// A multipart field whose value is a file path.
    public var isFile = false

    public init(name: String, value: String, isEnabled: Bool = true, isFile: Bool = false) {
        self.name = name
        self.value = value
        self.isEnabled = isEnabled
        self.isFile = isFile
    }
}

public struct ImportedRequest {
    /// Identifies the request inside its source, for dependencies between requests.
    public var id: String
    public var title: String
    public var method: String
    public var url: String
    public var headers: [ImportedField] = []
    /// Declared on the request, such as path parameters.
    public var variables: [ImportedVariable] = []
    public var body: ImportedBody?
    /// `nil` inherits from the folders above.
    public var auth: ImportedAuth?
    public var description: String?
    /// Stamp statements, without `>`.
    public var script: [String] = []
    /// Comment lines, for what couldn't be carried over.
    public var notes: [String] = []
    /// Ids of requests whose responses this one uses.
    public var dependencies: [String] = []
    /// Directives such as `@insecure` or `@timeout 30s`.
    public var directives: [String] = []

    public init(id: String = UUID().uuidString, title: String, method: String, url: String) {
        self.id = id
        self.title = title
        self.method = method
        self.url = url
    }
}

public enum ImportedBody: Equatable {
    case text(String)
    case urlEncoded([ImportedField])
    case multipart([ImportedField])
    case graphQL(query: String, variables: String?)
    case file(String)
}

public enum ImportedAuth: Equatable {
    case none
    case bearer(String)
    case basic(username: String, password: String)
    case apiKey(name: String, value: String, inQuery: Bool)
    case oauth2ClientCredentials(tokenURL: String, clientID: String, clientSecret: String, scope: String?)
    case oauth2Password(tokenURL: String, clientID: String, clientSecret: String, username: String, password: String, scope: String?)
    /// A kind Stamp has no directive for, by name.
    case unsupported(String)
}

public struct ImportedVariable: Equatable {
    public var name: String
    /// A template.
    public var value: String
    public var isSecret = false
    /// Set when the source says what this is, so its name isn't guessed at.
    public var isSecretKnown = false

    public init(name: String, value: String, isSecret: Bool = false, isSecretKnown: Bool = false) {
        self.name = name
        self.value = value
        self.isSecret = isSecret
        self.isSecretKnown = isSecretKnown
    }
}

public struct ImportedEnvironment {
    public var name: String
    public var variables: [ImportedVariable]

    public init(name: String, variables: [ImportedVariable]) {
        self.name = name
        self.variables = variables
    }
}

extension ImportedCollection {
    /// Renames a variable everywhere this collection refers to it, so two
    /// collections imported together can each keep their own value.
    func rewriting(_ old: String, to new: String) -> ImportedCollection {
        let from = "{{" + old + "}}"
        let to = "{{" + new + "}}"
        func text(_ value: String) -> String { value.replacingOccurrences(of: from, with: to) }
        func field(_ field: ImportedField) -> ImportedField {
            ImportedField(name: field.name, value: text(field.value), isEnabled: field.isEnabled, isFile: field.isFile)
        }
        func variable(_ variable: ImportedVariable) -> ImportedVariable {
            ImportedVariable(
                name: variable.name == old ? new : variable.name, value: text(variable.value),
                isSecret: variable.isSecret, isSecretKnown: variable.isSecretKnown
            )
        }
        func auth(_ auth: ImportedAuth?) -> ImportedAuth? {
            switch auth {
            case .bearer(let token)?: .bearer(text(token))
            case .basic(let username, let password)?: .basic(username: text(username), password: text(password))
            case .apiKey(let name, let value, let inQuery)?: .apiKey(name: name, value: text(value), inQuery: inQuery)
            case .oauth2ClientCredentials(let url, let id, let secret, let scope)?:
                .oauth2ClientCredentials(tokenURL: text(url), clientID: text(id), clientSecret: text(secret), scope: scope)
            case .oauth2Password(let url, let id, let secret, let user, let password, let scope)?:
                .oauth2Password(tokenURL: text(url), clientID: text(id), clientSecret: text(secret), username: text(user), password: text(password), scope: scope)
            default: auth
            }
        }
        func body(_ body: ImportedBody?) -> ImportedBody? {
            switch body {
            case .text(let value)?: .text(text(value))
            case .urlEncoded(let fields)?: .urlEncoded(fields.map(field))
            case .multipart(let fields)?: .multipart(fields.map(field))
            case .graphQL(let query, let variables)?: .graphQL(query: text(query), variables: variables.map(text))
            default: body
            }
        }
        func rewrite(_ folder: ImportedFolder) -> ImportedFolder {
            var result = folder
            result.headers = folder.headers.map(field)
            result.variables = folder.variables.map(variable)
            result.auth = auth(folder.auth)
            result.folders = folder.folders.map(rewrite)
            result.requests = folder.requests.map { request in
                var request = request
                request.url = text(request.url)
                request.headers = request.headers.map(field)
                request.variables = request.variables.map(variable)
                request.body = body(request.body)
                request.auth = auth(request.auth)
                request.script = request.script.map(text)
                return request
            }
            return result
        }
        var result = self
        result.root = rewrite(root)
        result.variables = variables.map(variable)
        result.environments = environments.map { ImportedEnvironment(name: $0.name, variables: $0.variables.map(variable)) }
        return result
    }
}

/// What an import adds to `environment.stamp` and `environment.local.stamp`.
public struct ImportedEnvironmentChanges: Equatable {
    public struct Entry: Equatable {
        public var conditions: [VariableSet.Condition]
        public var name: String
        /// An expression.
        public var source: String
    }

    /// A dimension and the values the import needs in it.
    public var dimension: (name: String, values: [String])?
    public var shared: [Entry] = []
    /// Secrets, for the file that stays out of git.
    public var local: [Entry] = []

    public var isEmpty: Bool { dimension == nil && shared.isEmpty && local.isEmpty }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.dimension?.name == rhs.dimension?.name && lhs.dimension?.values == rhs.dimension?.values
            && lhs.shared == rhs.shared && lhs.local == rhs.local
    }

    /// Every variable name a `vars` block in these files declares.
    public static func declaredNames(in texts: [String]) -> Set<String> {
        Set(texts.flatMap { Document.parse($0).variableSets.flatMap(\.declarations).map(\.name) })
    }

    /// Adds the changes to an environment file's text. Variables that the file
    /// already sets for the same combination keep their value, and are returned.
    public func apply(to text: String, other: String = "", local isLocal: Bool) -> (text: String, kept: [String]) {
        // The two files share one set of names: the local one wins for the same
        // conditions, so a name either file declares already is left alone.
        let elsewhere = Self.declaredNames(in: [other])
        var editor = EnvironmentEditor(text: text)
        if !isLocal, let dimension {
            let existing = Document.parse(text).dimensions.first { $0.name == dimension.name }?.values ?? []
            let values = existing + dimension.values.filter { !existing.contains($0) }
            if values != existing { editor.setDimension(dimension.name, values: values) }
        }
        var kept: [String] = []
        for entry in isLocal ? local : shared {
            let document = Document.parse(editor.text)
            if elsewhere.contains(entry.name) {
                kept.append(entry.name)
                continue
            }
            if let index = editor.setIndex(where: entry.conditions),
               document.variableSets[index].declarations.contains(where: { $0.name == entry.name })
            {
                kept.append(entry.name)
                continue
            }
            editor.setVariable(entry.name, source: entry.source, where: entry.conditions)
        }
        return (editor.text, kept)
    }
}
