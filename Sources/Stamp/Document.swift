/// A parsed `.stamp` file.
///
///     @base = http://localhost:8080/api
///
///     ### Login
///     POST {{base}}/login
///     Content-Type: application/json
///
///     { "username": "{{username}}" }
///
///     > assert status == 200
///     > set token = body.token
///
/// Parsing never fails as a whole: problems are collected in `diagnostics`
/// and everything that could be understood is still available, which keeps
/// the editor useful while a file is half-written.
public struct Document: Sendable {
    public var source: SourceText
    public var fileName: String?
    /// Declarations before the first request apply to every request in the file.
    public var declarations: [Declaration] = []
    public var directives: [Directive] = []
    public var dimensions: [DimensionDeclaration] = []
    public var variableSets: [VariableSet] = []
    public var plans: [TestPlan] = []
    public var requests: [RequestBlock] = []
    public var diagnostics: [Diagnostic] = []
    /// What each line is, indexed by `line - 1`. Drives highlighting and editing.
    public var lineKinds: [LineKind] = []

    public init(source: SourceText, fileName: String? = nil) {
        self.source = source
        self.fileName = fileName
    }

    public static func parse(_ text: String, fileName: String? = nil) -> Document {
        DocumentParser(SourceText(text), fileName: fileName).parse()
    }

    public var hasErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }

    /// The file-wide `@auth`, declared before the first request.
    public var auth: AuthScheme? {
        directives.lastAuth
    }

    /// What a request actually uses: its own `@auth`, or the file's.
    public func auth(for request: RequestBlock) -> AuthScheme? {
        request.auth ?? auth
    }

    public func request(named name: String) -> RequestBlock? {
        requests.first { $0.name == name }
    }

    /// The request whose section contains `line`.
    public func request(atLine line: Int) -> RequestBlock? {
        requests.first { $0.lines.contains(line) }
    }
}

public enum LineKind: Hashable, Sendable {
    case blank
    case comment
    case separator
    case declaration
    case directive
    case dimension
    case variableSetOpen
    case variableSetEntry
    case variableSetClose
    case plan
    case requestLine
    case header
    case disabledHeader
    case body
    case script
    case invalid
}

public struct Declaration: Hashable, Sendable {
    public enum Value: Hashable, Sendable {
        /// `@name = text with {{interpolation}}`
        case text(Template)
        /// `let name = expression`
        case expression(Expr)
        /// `fn name(a, b) = expression`
        case function([String], Expr)
    }

    public var name: String
    public var value: Value
    public var line: Int

    public var binding: ScopeBinding {
        switch value {
        case .text(let template): .text(template)
        case .expression(let expr): .expression(expr)
        case .function(let parameters, let body): .value(.lambda(Lambda(name: name, parameters: parameters, body: body)))
        }
    }
}

public struct Directive: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case name(String)
        /// Seconds.
        case timeout(Double)
        case noRedirect
        case insecure
        case needs([String])
        case auth(AuthScheme)
        /// `@sampling reply …`: what an MCP request answers when the server asks for a completion.
        case sampling(Template)
        /// `@elicitation accept { … }`, `decline` or `cancel`: the answer to an MCP server's questions.
        case elicitation(ElicitationReply)
        /// `@roots file:///a, file:///b`: the roots an MCP request offers the server.
        case roots([Template])
    }

    public enum ElicitationReply: Hashable, Sendable {
        case accept(Template)
        case decline
        case cancel
    }

    public var kind: Kind
    public var line: Int
}

public struct Header: Hashable, Sendable {
    public var name: String
    public var value: Template
    /// The value exactly as written.
    public var rawValue: String
    /// Commented-out headers are kept so they can be switched back on.
    public var isEnabled: Bool
    public var line: Int
}

public struct Body: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        case text(String, Template)
        /// `< ./payload.json`, resolved relative to the file.
        case file(path: Template, rawPath: String)
    }

    public var content: Content
    public var lines: ClosedRange<Int>

    public var rawText: String {
        switch content {
        case .text(let text, _): text
        case .file(_, let path): "< " + path
        }
    }
}

public struct ScriptStatement: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case assert(Expr, message: Expr?)
        /// Stores a value for the rest of the session.
        case set(String, Expr)
        /// Binds a value for the following statements of the same script.
        case `let`(String, Expr)
        /// Like `set`, and also writes the value into the environment for
        /// the current combination of dimensions, so it survives the session.
        case save(String, Expr)
        /// WebSocket and MCP requests: send a message.
        case send(Expr)
        /// WebSocket and MCP requests: wait for the next message, binding `message` (text) and `data` (parsed JSON).
        case receive(timeout: Double?)
        case close
        case wait(Double)
        case print(Expr)
        /// A function called for what it does, such as `notify("…")` in an MCP request.
        case evaluate(Expr)
    }

    public var kind: Kind
    public var source: String
    public var line: Int
}

public struct RequestBlock: Hashable, Sendable, Identifiable {
    public var index: Int
    public var id: Int { index }
    /// Text after `###`.
    public var title: String?
    /// An identifier other requests and scripts can refer to.
    public var name: String
    /// First to last non-blank line of the section, including `###`.
    public var lines: ClosedRange<Int>
    public var declarations: [Declaration] = []
    public var directives: [Directive] = []
    public var method: String
    public var target: Template
    public var rawTarget: String
    public var httpVersion: String?
    public var requestLine: Int
    public var headers: [Header] = []
    public var body: Body?
    public var script: [ScriptStatement] = []

    public var displayName: String { title ?? name }

    /// `WS wss://…`, or a bare `ws://` / `wss://` URL.
    public var isWebSocket: Bool {
        method == "WS" || method == "WEBSOCKET"
    }

    /// `STUN stun:host:port` or `TURN turn:host:port`: a check of a WebRTC ICE server.
    public var isICE: Bool {
        method == "STUN" || method == "TURN"
    }

    /// `MCP https://…/mcp` or `MCP stdio: node server.js`: a session with a Model Context Protocol server.
    public var isMCP: Bool {
        method == "MCP"
    }

    public var samplingReply: Template? {
        directives.reversed().lazy.compactMap { directive -> Template? in
            if case .sampling(let reply) = directive.kind { return reply }
            return nil
        }.first
    }

    public var elicitationReply: Directive.ElicitationReply? {
        directives.reversed().lazy.compactMap { directive -> Directive.ElicitationReply? in
            if case .elicitation(let reply) = directive.kind { return reply }
            return nil
        }.first
    }

    public var roots: [Template]? {
        directives.reversed().lazy.compactMap { directive -> [Template]? in
            if case .roots(let roots) = directive.kind { return roots }
            return nil
        }.first
    }

    public var timeout: Double? {
        directives.reversed().lazy.compactMap { directive -> Double? in
            if case .timeout(let seconds) = directive.kind { return seconds }
            return nil
        }.first
    }

    public var followsRedirects: Bool {
        !directives.contains { $0.kind == .noRedirect }
    }

    public var allowsInsecureConnections: Bool {
        directives.contains { $0.kind == .insecure }
    }

    public var dependencies: [String] {
        directives.flatMap { directive -> [String] in
            if case .needs(let names) = directive.kind { return names }
            return []
        }
    }

    /// The request's own `@auth`, if it has one.
    public var auth: AuthScheme? {
        directives.lastAuth
    }
}

extension [Directive] {
    var lastAuth: AuthScheme? {
        reversed().lazy.compactMap { directive -> AuthScheme? in
            if case .auth(let scheme) = directive.kind { return scheme }
            return nil
        }.first
    }
}

public struct DimensionDeclaration: Hashable, Sendable {
    public var name: String
    public var values: [String]
    public var line: Int
}

/// Variables that apply when the selected dimension values match.
///
///     vars environment=qa|prod, region=eu {
///       host = "api.eu.example.com"
///     }
public struct VariableSet: Hashable, Sendable {
    public struct Condition: Hashable, Sendable {
        public var dimension: String
        public var values: [String]

        public init(dimension: String, values: [String]) {
            self.dimension = dimension
            self.values = values
        }
    }

    public var conditions: [Condition]
    public var declarations: [Declaration]
    public var lines: ClosedRange<Int>

    /// Sets constraining more dimensions win over broader ones.
    public var specificity: Int { conditions.count }

    /// `selection` maps dimension names to the chosen value. A dimension left
    /// out of the selection only matches sets that don't constrain it.
    public func matches(_ selection: [String: String]) -> Bool {
        conditions.allSatisfy { condition in
            guard let chosen = selection[condition.dimension] else { return false }
            return condition.values.contains(chosen)
        }
    }

    public var label: String {
        conditions.isEmpty
            ? "*"
            : conditions.map { "\($0.dimension)=\($0.values.joined(separator: "|"))" }.joined(separator: ", ")
    }
}

extension String {
    /// `"Start a chat"` → `startAChat`, or nil when nothing usable is left.
    public var stampIdentifier: String? {
        let words = folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        guard !words.isEmpty else { return nil }
        var identifier = words.enumerated().map { index, word in
            index == 0 ? word.lowercased() : word.prefix(1).uppercased() + word.dropFirst()
        }.joined()
        if identifier.first?.isNumber == true { identifier = "_" + identifier }
        return identifier
    }
}
