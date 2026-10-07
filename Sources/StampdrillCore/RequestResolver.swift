import Foundation
import Stamp

public struct ResolutionError: Error, Hashable, Sendable, CustomStringConvertible {
    public var message: String
    public var line: Int?

    public init(_ message: String, line: Int? = nil) {
        self.message = message
        self.line = line
    }

    public var description: String {
        line.map { "line \($0): \(message)" } ?? message
    }
}

/// Everything a request's variables can come from, besides the files.
public struct ResolutionInput: Sendable {
    public var selection: DimensionSelection
    /// Values stored by `set` and the responses of named requests.
    public var session: [String: Value]
    /// Values passed on the command line or pinned in the app; they win over everything.
    public var overrides: [String: Value]
    public var defaultTimeout: TimeInterval

    public init(
        selection: DimensionSelection = [:], session: [String: Value] = [:], overrides: [String: Value] = [:],
        defaultTimeout: TimeInterval = 30
    ) {
        self.selection = selection
        self.session = session
        self.overrides = overrides
        self.defaultTimeout = defaultTimeout
    }
}

public enum RequestResolver {
    /// Builds the variable scope for a request, lowest priority first:
    /// environment sets, file declarations, session, request declarations, overrides.
    public static func scope(
        for request: RequestBlock?, in file: WorkspaceFile, workspace: Workspace, input: ResolutionInput
    ) -> Scope {
        let environment = workspace.environment(for: file)
        let selection = environment.normalized(input.selection)
        var layers = environment.layers(for: selection)

        var dimensions: [String: ScopeBinding] = [:]
        for (name, value) in selection { dimensions[name] = .value(.string(value)) }
        layers.insert(Scope.Layer("dimensions", dimensions), at: 0)

        layers.append(Scope.Layer("files", fileFunctions(relativeTo: file.url.deletingLastPathComponent())))
        layers.append(Scope.Layer(file.relativePath, bindings(file.document.declarations)))
        layers.append(Scope.Layer("session", input.session.mapValues { .value($0) }))
        if let request {
            layers.append(Scope.Layer(request.displayName, bindings(request.declarations)))
        }
        layers.append(Scope.Layer("override", input.overrides.mapValues { .value($0) }))
        return Scope(layers: layers, builtins: Builtins.standard)
    }

    public static func resolve(
        _ request: RequestBlock, in file: WorkspaceFile, scope context: Scope, defaultTimeout: TimeInterval = 30
    ) throws(ResolutionError) -> ResolvedRequest {
        let target = try render(request.target, line: request.requestLine, in: context)
        var url: URL
        if request.isICE {
            guard let server = ICEServer(target, kind: request.method == "TURN" ? .turn : .stun) else {
                throw ResolutionError("'\(target)' is not a \(request.method) server; write it like \(request.method.lowercased()):example.com:3478", line: request.requestLine)
            }
            url = server.url
        } else if request.isMCP {
            guard let address = MCPServerAddress(target) else {
                throw ResolutionError("'\(target)' is not an MCP server; write a URL such as https://example.com/mcp, or stdio: followed by a command", line: request.requestLine)
            }
            url = address.url
        } else {
            url = try makeURL(target, line: request.requestLine, webSocket: request.isWebSocket)
        }

        var headers: [HTTPField] = []
        for header in request.headers where header.isEnabled {
            headers.append(HTTPField(header.name, try render(header.value, line: header.line, in: context)))
        }

        var body: Data?
        switch request.body?.content {
        case .text(_, let template)?:
            body = Data(try render(template, line: request.body!.lines.lowerBound, in: context).utf8)
        case .file(let path, _)?:
            let line = request.body!.lines.lowerBound
            let relative = try render(path, line: line, in: context)
            let bodyURL = resolvePath(relative, in: file.url.deletingLastPathComponent())
            do {
                body = try Data(contentsOf: bodyURL)
            } catch {
                throw ResolutionError("cannot read body file '\(relative)'", line: line)
            }
        case nil:
            break
        }

        var tokenRequest: OAuth2TokenRequest?
        switch file.document.auth(for: request) {
        case .oauth2(let settings)?:
            if !headers.contains(where: { $0.name.caseInsensitiveCompare("Authorization") == .orderedSame }) {
                tokenRequest = try makeTokenRequest(settings, line: request.requestLine, context: context)
            }
        case let auth?:
            try apply(auth, to: &headers, url: &url, line: request.requestLine, context: context)
        case nil:
            break
        }

        var method = request.method
        let bodyLine = request.body?.lines.lowerBound ?? request.requestLine
        func headerIndex(_ name: String) -> Int? {
            headers.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }

        if method == "GRAPHQL" {
            method = "POST"
            body = try BodyEncoding.graphQL(body.map { String(decoding: $0, as: UTF8.self) } ?? "", line: bodyLine)
            if headerIndex("Content-Type") == nil { headers.append(HTTPField("Content-Type", "application/json")) }
            if headerIndex("Accept") == nil { headers.append(HTTPField("Accept", "application/graphql-response+json, application/json")) }
        } else if case .text? = request.body?.content, let current = body, let typeIndex = headerIndex("Content-Type") {
            let type = headers[typeIndex].value.lowercased()
            let text = String(decoding: current, as: UTF8.self)
            let directory = file.url.deletingLastPathComponent()
            if type.hasPrefix("multipart/form-data"), let fields = BodyEncoding.formFields(text, relativeTo: directory) {
                let boundary = "stampdrill-" + UUID().uuidString.lowercased()
                body = try BodyEncoding.multipart(fields, boundary: boundary, line: bodyLine)
                headers[typeIndex].value = "multipart/form-data; boundary=\(boundary)"
            } else if type.hasPrefix("application/x-www-form-urlencoded"), let fields = BodyEncoding.formFields(text, relativeTo: directory),
                      fields.allSatisfy({ $0.file == nil })
            {
                body = BodyEncoding.urlEncoded(fields)
            }
        }

        if let body, !headers.contains(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }),
           let first = String(data: body.prefix(64), encoding: .utf8)?.first(where: { !$0.isWhitespace }),
           first == "{" || first == "["
        {
            headers.append(HTTPField("Content-Type", "application/json"))
        }

        return ResolvedRequest(
            name: request.name,
            method: method,
            url: url,
            headers: headers,
            body: body,
            timeout: request.timeout ?? defaultTimeout,
            followsRedirects: request.followsRedirects,
            allowsInsecureConnections: request.allowsInsecureConnections,
            secrets: context.secrets,
            tokenRequest: tokenRequest
        )
    }

    private static func makeTokenRequest(
        _ settings: OAuth2Settings, line: Int, context: Scope
    ) throws(ResolutionError) -> OAuth2TokenRequest {
        var values: [String: String] = [:]
        for (name, template) in settings.parameters {
            values[name] = try render(template, line: line, in: context)
        }
        let url = try makeURL(values["token_url"] ?? "", line: line)
        var form = [HTTPField("grant_type", settings.grant.rawValue)]
        for name in OAuth2Settings.parameterNames where name != "token_url" {
            if let value = values[name], !value.isEmpty { form.append(HTTPField(name, value)) }
        }
        return OAuth2TokenRequest(url: url, form: form)
    }

    private static func apply(
        _ auth: AuthScheme, to headers: inout [HTTPField], url: inout URL, line: Int, context: Scope
    ) throws(ResolutionError) {
        func setHeader(_ name: String, _ value: String) {
            // A header written out in the request wins over @auth.
            guard !headers.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
            headers.append(HTTPField(name, value))
        }

        switch auth {
        case .none:
            break
        case .bearer(let token), .jwt(let token):
            let value = try render(token, line: line, in: context)
            setHeader("Authorization", value.hasPrefix("Bearer ") ? value : "Bearer " + value)
        case .basic(let username, let password):
            let credentials = try render(username, line: line, in: context) + ":" + render(password, line: line, in: context)
            setHeader("Authorization", "Basic " + Data(credentials.utf8).base64EncodedString())
        case .apiKey(let name, let value, .header):
            setHeader(name, try render(value, line: line, in: context))
        case .oauth2:
            break
        case .apiKey(let name, let value, .query):
            let rendered = try render(value, line: line, in: context)
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
            var items = components.queryItems ?? []
            guard !items.contains(where: { $0.name == name }) else { return }
            items.append(URLQueryItem(name: name, value: rendered))
            components.queryItems = items
            if let updated = components.url { url = updated }
        }
    }

    static func render(_ template: Template, line: Int, in context: Scope) throws(ResolutionError) -> String {
        do {
            return try context.render(template)
        } catch {
            throw ResolutionError(error.message, line: line)
        }
    }

    static func makeURL(_ text: String, line: Int, webSocket: Bool = false) throws(ResolutionError) -> URL {
        var text = text.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = (webSocket ? "ws://" : "http://") + text }
        if webSocket {
            if text.hasPrefix("https://") { text = "wss://" + text.dropFirst(8) }
            if text.hasPrefix("http://") { text = "ws://" + text.dropFirst(7) }
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), url.host != nil else {
            throw ResolutionError("'\(text)' is not a valid URL", line: line)
        }
        let allowed = webSocket ? ["ws", "wss"] : ["http", "https"]
        guard allowed.contains(scheme) else {
            throw ResolutionError("unsupported scheme '\(scheme)'" + (["ws", "wss"].contains(scheme) ? "; use 'WS' as the method" : ""), line: line)
        }
        return url
    }

    /// `readText` and `readJson`, resolving paths next to the file.
    private static func fileFunctions(relativeTo directory: URL) -> [String: ScopeBinding] {
        let read = { @Sendable (arguments: [Value], name: String) throws(EvaluationError) -> Data in
            guard arguments.count == 1 else { throw EvaluationError("\(name)() takes a path") }
            let path = arguments[0].interpolated
            let url = resolvePath(path, in: directory)
            guard let data = try? Data(contentsOf: url) else { throw EvaluationError("\(name)(): cannot read '\(path)'") }
            return data
        }
        return [
            "readText": .value(.function(NativeFunction("readText") { arguments throws(EvaluationError) in
                .string(String(decoding: try read(arguments, "readText"), as: UTF8.self))
            })),
            "readJson": .value(.function(NativeFunction("readJson") { arguments throws(EvaluationError) in
                try Value(json: try read(arguments, "readJson"))
            })),
        ]
    }

    private static func bindings(_ declarations: [Declaration]) -> [String: ScopeBinding] {
        var result: [String: ScopeBinding] = [:]
        for declaration in declarations { result[declaration.name] = declaration.binding }
        return result
    }
}
