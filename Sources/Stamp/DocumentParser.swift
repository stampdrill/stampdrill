import Foundation

/// Line-oriented parser for `.stamp` files.
///
/// A file is a preamble followed by request sections separated by `###`.
/// Within a section the order is fixed: declarations and directives, the
/// request line, headers, an empty line, the body, then `>` script lines.
struct DocumentParser {
    private enum State {
        case preamble
        case section
        case headers
        case body
        case script
    }

    private struct Section {
        var title: String?
        var startLine: Int
        var lastLine: Int
        var declarations: [Declaration] = []
        var directives: [Directive] = []
        var method: String?
        var target = Template(parts: [])
        var rawTarget = ""
        var httpVersion: String?
        var requestLine = 0
        var headers: [Header] = []
        var bodyLines: [(number: Int, text: String)] = []
        var script: [ScriptStatement] = []
    }

    private struct OpenVariableSet {
        var conditions: [VariableSet.Condition]
        var declarations: [Declaration] = []
        var startLine: Int
    }

    private let source: SourceText
    private var document: Document
    private var state = State.preamble
    private var section: Section?
    private var variableSet: OpenVariableSet?
    private var planParser: PlanParser?

    init(_ source: SourceText, fileName: String?) {
        self.source = source
        document = Document(source: source, fileName: fileName)
        document.lineKinds = Array(repeating: .blank, count: source.lineCount)
    }

    consuming func parse() -> Document {
        for (index, line) in source.lines.enumerated() {
            parseLine(line, number: index + 1)
        }
        if let open = variableSet {
            error("missing '}' to close 'vars'", line: open.startLine)
            closeVariableSet(at: source.lineCount)
        }
        if planParser != nil {
            planParser!.finish(at: source.lineCount)
            closePlan()
        }
        finishSection()
        checkNames()
        return document
    }

    // MARK: Lines

    private mutating func parseLine(_ line: String, number: Int) {
        let trimmed = Substring(line).trimmed

        if trimmed.hasPrefix("###") {
            if variableSet != nil {
                error("missing '}' to close 'vars'", line: variableSet!.startLine)
                closeVariableSet(at: number - 1)
            }
            finishSection()
            let title = trimmed.dropFirst(3).trimmed
            section = Section(title: title.isEmpty ? nil : String(title), startLine: number, lastLine: number)
            state = .section
            mark(number, .separator)
            return
        }

        if variableSet != nil {
            parseVariableSetLine(line, trimmed: trimmed, number: number)
            return
        }

        if planParser != nil {
            if !trimmed.isEmpty {
                mark(number, isComment(trimmed) ? .comment : .plan)
                if !isComment(trimmed) { planParser!.parse(line, trimmed: trimmed, number: number) }
            }
            if planParser!.isFinished { closePlan() }
            return
        }

        switch state {
        case .preamble, .section:
            parseDeclarationLine(line, trimmed: trimmed, number: number)
        case .headers:
            parseHeaderLine(line, trimmed: trimmed, number: number)
        case .body:
            if line.hasPrefix(">") {
                state = .script
                parseScriptLine(line, number: number)
            } else {
                section?.bodyLines.append((number, line))
                if !trimmed.isEmpty { section?.lastLine = number }
                mark(number, trimmed.isEmpty ? .blank : .body)
            }
        case .script:
            if trimmed.isEmpty {
                return
            } else if isComment(trimmed) {
                mark(number, .comment)
            } else if line.hasPrefix(">") {
                parseScriptLine(line, number: number)
            } else {
                error("expected a '>' script line; start a new request with '###'", line: number, in: line)
            }
        }
    }

    private mutating func parseDeclarationLine(_ line: String, trimmed: Substring, number: Int) {
        if trimmed.isEmpty { return }
        if isComment(trimmed) {
            mark(number, .comment)
            return
        }
        touch(number)

        if trimmed.hasPrefix("@") {
            parseAtLine(line, trimmed: trimmed, number: number)
        } else if let rest = trimmed.afterKeyword("let") {
            if let declaration = parseLet(line, rest: rest, number: number) {
                append(declaration)
                mark(number, .declaration)
            }
        } else if let rest = trimmed.afterKeyword("fn") {
            if let declaration = parseFunction(line, rest: rest, number: number) {
                append(declaration)
                mark(number, .declaration)
            }
        } else if let rest = trimmed.afterKeyword("dimension") {
            parseDimension(line, rest: rest, number: number)
        } else if let rest = trimmed.afterKeyword("plan") ?? trimmed.afterKeyword("load") {
            mark(number, .plan)
            let isLoad = trimmed.hasPrefix("load")
            let name = rest.prefix { $0.isIdentifierCharacter }
            guard section == nil else {
                error("plans must come before the first request of a file", line: number, in: line)
                return
            }
            guard name.isIdentifier, rest.dropFirst(name.count).trimmed == "{" else {
                error("expected '\(isLoad ? "load" : "plan") Name {'", line: number, in: line)
                return
            }
            planParser = PlanParser(name: String(name), line: number, isLoad: isLoad)
        } else if trimmed.hasPrefix("vars"), trimmed.dropFirst(4).first.map({ $0 == " " || $0 == "{" }) ?? false {
            parseVariableSetOpening(line, trimmed: trimmed, number: number)
        } else if let (method, target) = requestLineParts(trimmed) {
            parseRequestLine(line, method: method, target: target, number: number)
        } else if trimmed.hasPrefix(">") {
            error("a response script must follow a request", line: number, in: line)
        } else {
            error("expected a request line such as 'GET https://example.com'", line: number, in: line)
        }
    }

    private mutating func parseAtLine(_ line: String, trimmed: Substring, number: Int) {
        let afterAt = trimmed.dropFirst()
        let name = afterAt.prefix { $0.isIdentifierCharacter || $0 == "-" }
        let rest = afterAt.dropFirst(name.count).trimmed

        guard !name.isEmpty else {
            error("expected a name after '@'", line: number, in: line)
            return
        }

        if rest.hasPrefix("=") {
            guard name.isIdentifier else {
                error("'\(name)' is not a valid variable name", line: number, in: line)
                return
            }
            let value = rest.dropFirst().trimmingLeadingWhitespace().trimmingTrailingWhitespace()
            do {
                let template = try Template.parse(String(value), line: number, column: line.column(of: value))
                append(Declaration(name: String(name), value: .text(template), line: number))
                mark(number, .declaration)
            } catch {
                report(error, line: number)
            }
            return
        }

        mark(number, .directive)
        switch name {
        case "name":
            guard rest.isIdentifier else {
                error("'@name' needs an identifier, like '@name login'", line: number, in: line)
                return
            }
            append(Directive(kind: .name(String(rest)), line: number))
        case "timeout":
            guard let seconds = parseDuration(rest) else {
                error("'@timeout' needs a duration such as 30s, 1500ms or 2m", line: number, in: line)
                return
            }
            append(Directive(kind: .timeout(seconds), line: number))
        case "no-redirect":
            append(Directive(kind: .noRedirect, line: number))
        case "insecure":
            append(Directive(kind: .insecure, line: number))
        case "needs":
            let names = rest.split(separator: ",").map { $0.trimmed }
            guard !names.isEmpty, names.allSatisfy(\.isIdentifier) else {
                error("'@needs' takes request names separated by commas", line: number, in: line)
                return
            }
            append(Directive(kind: .needs(names.map(String.init)), line: number))
        case "auth":
            do {
                append(Directive(kind: .auth(try AuthParser.parse(rest, in: line, number: number)), line: number))
            } catch {
                report(error, line: number)
            }
        case "sampling":
            guard rest.hasPrefix("reply"), let template = template(rest.dropFirst(5).trimmed, number: number, in: line) else {
                error("'@sampling' needs a reply, like '@sampling reply Sunny, 24°C'", line: number, in: line)
                return
            }
            append(Directive(kind: .sampling(template), line: number))
        case "elicitation":
            if rest == "decline" {
                append(Directive(kind: .elicitation(.decline), line: number))
            } else if rest == "cancel" {
                append(Directive(kind: .elicitation(.cancel), line: number))
            } else if rest.hasPrefix("accept"), let template = template(rest.dropFirst(6).trimmed, number: number, in: line) {
                append(Directive(kind: .elicitation(.accept(template)), line: number))
            } else {
                error("'@elicitation' takes 'accept { … }', 'decline' or 'cancel'", line: number, in: line)
            }
        case "roots":
            let parts = rest.split(separator: ",").map { $0.trimmed }
            let templates = parts.compactMap { template($0, number: number, in: line) }
            guard !parts.isEmpty, templates.count == parts.count else {
                error("'@roots' takes URIs separated by commas, like '@roots file:///work/project'", line: number, in: line)
                return
            }
            append(Directive(kind: .roots(templates), line: number))
        default:
            document.diagnostics.append(.warning("unknown directive '@\(name)'", at: lineRange(number, line)))
        }
    }

    /// A `{{ }}` template from part of a directive, reporting parse errors.
    private mutating func template(_ text: Substring, number: Int, in line: String) -> Template? {
        guard !text.isEmpty else { return nil }
        do {
            return try Template.parse(String(text), line: number, column: line.column(of: text))
        } catch {
            report(error, line: number)
            return nil
        }
    }

    private mutating func parseLet(_ line: String, rest: Substring, number: Int, form: String = "let name = expression") -> Declaration? {
        let name = rest.prefix { $0.isIdentifierCharacter }
        let afterName = rest.dropFirst(name.count).trimmingLeadingWhitespace()
        guard name.isIdentifier, afterName.hasPrefix("=") else {
            error("expected '\(form)'", line: number, in: line)
            return nil
        }
        let expression = afterName.dropFirst()
        do {
            let expr = try ExprParser.parse(String(expression), line: number, column: line.column(of: expression))
            return Declaration(name: String(name), value: .expression(expr), line: number)
        } catch {
            report(error, line: number)
            return nil
        }
    }

    /// `fn name(a, b) = expression`
    private mutating func parseFunction(_ line: String, rest: Substring, number: Int) -> Declaration? {
        let name = rest.prefix { $0.isIdentifierCharacter }
        var remainder = rest.dropFirst(name.count).trimmingLeadingWhitespace()
        guard name.isIdentifier, remainder.hasPrefix("("), let close = remainder.firstIndex(of: ")") else {
            error("expected 'fn name(parameters) = expression'", line: number, in: line)
            return nil
        }
        let parameters = remainder[remainder.index(after: remainder.startIndex)..<close]
            .split(separator: ",").map { $0.trimmed }
        guard parameters.allSatisfy(\.isIdentifier) else {
            error("parameters must be names separated by commas", line: number, in: line)
            return nil
        }
        remainder = remainder[remainder.index(after: close)...].trimmingLeadingWhitespace()
        guard remainder.hasPrefix("=") else {
            error("expected '=' after the parameters of '\(name)'", line: number, in: line)
            return nil
        }
        let body = remainder.dropFirst()
        do {
            let expr = try ExprParser.parse(String(body), line: number, column: line.column(of: body))
            return Declaration(name: String(name), value: .function(parameters.map(String.init), expr), line: number)
        } catch {
            report(error, line: number)
            return nil
        }
    }

    private mutating func parseDimension(_ line: String, rest: Substring, number: Int) {
        mark(number, .dimension)
        guard section == nil else {
            error("dimensions must be declared before the first request", line: number, in: line)
            return
        }
        let name = rest.prefix { $0.isIdentifierCharacter || $0 == "-" }
        let afterName = rest.dropFirst(name.count).trimmingLeadingWhitespace()
        let values = afterName.dropFirst().split(separator: ",").map { $0.trimmed }
        guard !name.isEmpty, afterName.hasPrefix("="), !values.isEmpty, values.allSatisfy(\.isDimensionValue) else {
            error("expected 'dimension name = value, value'", line: number, in: line)
            return
        }
        if document.dimensions.contains(where: { $0.name == name }) {
            error("dimension '\(name)' is already declared", line: number, in: line)
            return
        }
        document.dimensions.append(DimensionDeclaration(name: String(name), values: values.map(String.init), line: number))
    }

    private mutating func parseVariableSetOpening(_ line: String, trimmed: Substring, number: Int) {
        mark(number, .variableSetOpen)
        guard trimmed.hasSuffix("{") else {
            error("expected '{' at the end of 'vars'", line: number, in: line)
            return
        }
        guard section == nil else {
            error("variable sets must be declared before the first request", line: number, in: line)
            return
        }
        var conditions: [VariableSet.Condition] = []
        let list = trimmed.dropFirst(4).dropLast().trimmed
        for item in list.split(separator: ",") {
            let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmed }
            guard parts.count == 2, !parts[0].isEmpty else {
                error("expected conditions like 'environment=qa, region=eu|us'", line: number, in: line)
                return
            }
            if parts[1] == "*" { continue }
            let values = parts[1].split(separator: "|").map { $0.trimmed }
            guard values.allSatisfy(\.isDimensionValue) else {
                error("invalid value for '\(parts[0])'", line: number, in: line)
                return
            }
            conditions.append(.init(dimension: String(parts[0]), values: values.map(String.init)))
        }
        variableSet = OpenVariableSet(conditions: conditions, startLine: number)
    }

    private mutating func parseVariableSetLine(_ line: String, trimmed: Substring, number: Int) {
        if trimmed.isEmpty { return }
        if isComment(trimmed) {
            mark(number, .comment)
            return
        }
        if trimmed == "}" {
            mark(number, .variableSetClose)
            closeVariableSet(at: number)
            return
        }
        mark(number, .variableSetEntry)

        if trimmed.hasPrefix("@") {
            let name = trimmed.dropFirst().prefix { $0.isIdentifierCharacter }
            let rest = trimmed.dropFirst(name.count + 1).trimmingLeadingWhitespace()
            guard name.isIdentifier, rest.hasPrefix("=") else {
                error("expected '@name = text'", line: number, in: line)
                return
            }
            let value = rest.dropFirst().trimmingLeadingWhitespace().trimmingTrailingWhitespace()
            do {
                let template = try Template.parse(String(value), line: number, column: line.column(of: value))
                variableSet?.declarations.append(Declaration(name: String(name), value: .text(template), line: number))
            } catch {
                report(error, line: number)
            }
            return
        }

        if let rest = trimmed.afterKeyword("fn") {
            if let declaration = parseFunction(line, rest: rest, number: number) {
                variableSet?.declarations.append(declaration)
            }
        } else if let declaration = parseLet(line, rest: trimmed.afterKeyword("let") ?? trimmed, number: number, form: "name = expression") {
            variableSet?.declarations.append(declaration)
        }
    }

    private mutating func closePlan() {
        guard let parser = planParser else { return }
        planParser = nil
        document.plans.append(parser.plan)
        for diagnostic in parser.diagnostics { report(diagnostic, line: diagnostic.range.start.line) }
    }

    private mutating func closeVariableSet(at line: Int) {
        guard let open = variableSet else { return }
        variableSet = nil
        document.variableSets.append(
            VariableSet(conditions: open.conditions, declarations: open.declarations, lines: open.startLine...max(line, open.startLine))
        )
    }

    private mutating func parseRequestLine(_ line: String, method: Substring, target: Substring, number: Int) {
        if section == nil {
            section = Section(startLine: number, lastLine: number)
        } else if section?.method != nil {
            error("a section can only contain one request; separate requests with '###'", line: number, in: line)
            return
        }
        mark(number, .requestLine)

        var target = target
        var version: String?
        if let space = target.lastIndex(of: " "), target[target.index(after: space)...].hasPrefix("HTTP/") {
            version = String(target[target.index(after: space)...])
            target = target[..<space].trimmingTrailingWhitespace()
        }

        do {
            section?.target = try Template.parse(String(target), line: number, column: line.column(of: target), dollarVariables: true)
        } catch {
            report(error, line: number)
        }
        section?.method = String(method)
        section?.rawTarget = String(target)
        section?.httpVersion = version
        section?.requestLine = number
        section?.lastLine = number
        state = .headers
    }

    private mutating func parseHeaderLine(_ line: String, trimmed: Substring, number: Int) {
        if trimmed.isEmpty {
            state = .body
            return
        }
        if line.hasPrefix(">") {
            state = .script
            parseScriptLine(line, number: number)
            return
        }
        touch(number)

        if isComment(trimmed) {
            let commented = trimmed.hasPrefix("//") ? trimmed.dropFirst(2) : trimmed.dropFirst()
            if let header = headerParts(commented.trimmingLeadingWhitespace()) {
                addHeader(line, name: header.name, value: header.value, enabled: false, number: number)
                mark(number, .disabledHeader)
            } else {
                mark(number, .comment)
            }
            return
        }

        guard let header = headerParts(trimmed) else {
            error("expected a header 'Name: value' or an empty line before the body", line: number, in: line)
            return
        }
        addHeader(line, name: header.name, value: header.value, enabled: true, number: number)
        mark(number, .header)
    }

    private mutating func addHeader(_ line: String, name: Substring, value: Substring, enabled: Bool, number: Int) {
        do {
            let template = try Template.parse(String(value), line: number, column: line.column(of: value), dollarVariables: true)
            section?.headers.append(Header(name: String(name), value: template, rawValue: String(value), isEnabled: enabled, line: number))
        } catch {
            if enabled { report(error, line: number) }
        }
    }

    private mutating func parseScriptLine(_ line: String, number: Int) {
        mark(number, .script)
        touch(number)
        let statement = Substring(line).dropFirst().trimmed
        let column = line.column(of: statement)

        do throws(Diagnostic) {
            if let rest = statement.afterKeyword("assert") {
                var parser = try ExprParser(String(rest), line: number, column: line.column(of: rest))
                let condition = try parser.expression()
                let message = parser.consume(.comma) ? try parser.expression() : nil
                try parser.expectEnd()
                append(ScriptStatement(kind: .assert(condition, message: message), source: String(statement), line: number))
            } else if let rest = statement.afterKeyword("send") {
                let expr = try ExprParser.parse(String(rest), line: number, column: line.column(of: rest))
                append(ScriptStatement(kind: .send(expr), source: String(statement), line: number))
            } else if statement == "receive" || statement.afterKeyword("receive") != nil {
                let rest = statement.afterKeyword("receive")?.trimmed ?? ""
                guard rest.isEmpty || parseDuration(rest) != nil else {
                    throw .error("expected 'receive' or 'receive 5s'", at: SourceRange(line: number, column: column, length: statement.utf16.count))
                }
                append(ScriptStatement(kind: .receive(timeout: rest.isEmpty ? nil : parseDuration(rest)), source: String(statement), line: number))
            } else if statement == "close" {
                append(ScriptStatement(kind: .close, source: String(statement), line: number))
            } else if let rest = statement.afterKeyword("wait") {
                guard let seconds = parseDuration(rest.trimmed) else {
                    throw .error("'wait' needs a duration such as 500ms or 2s", at: SourceRange(line: number, column: column, length: statement.utf16.count))
                }
                append(ScriptStatement(kind: .wait(seconds), source: String(statement), line: number))
            } else if let rest = statement.afterKeyword("print") {
                let expr = try ExprParser.parse(String(rest), line: number, column: line.column(of: rest))
                append(ScriptStatement(kind: .print(expr), source: String(statement), line: number))
            } else if let rest = statement.afterKeyword("set") ?? statement.afterKeyword("let") ?? statement.afterKeyword("save") {
                let keyword = statement.prefix { $0.isLetter }
                let isSet = keyword != "let"
                let name = rest.prefix { $0.isIdentifierCharacter }
                let afterName = rest.dropFirst(name.count).trimmingLeadingWhitespace()
                guard name.isIdentifier, afterName.hasPrefix("=") else {
                    throw .error("expected '\(keyword) name = expression'", at: SourceRange(line: number, column: column, length: statement.utf16.count))
                }
                let valueText = afterName.dropFirst()
                let expr = try ExprParser.parse(String(valueText), line: number, column: line.column(of: valueText))
                let kind: ScriptStatement.Kind = switch keyword {
                case "save": .save(String(name), expr)
                case "set": .set(String(name), expr)
                default: .let(String(name), expr)
                }
                _ = isSet
                append(ScriptStatement(kind: kind, source: String(statement), line: number))
            } else if let expr = try? ExprParser.parse(String(statement), line: number, column: column), case .call = expr {
                append(ScriptStatement(kind: .evaluate(expr), source: String(statement), line: number))
            } else {
                throw .error("expected 'assert', 'set', 'save', 'let', 'print', a function call, or for WebSockets and MCP 'send', 'receive', 'wait', 'close'", at: SourceRange(line: number, column: column, length: max(statement.utf16.count, 1)))
            }
        } catch {
            report(error, line: number)
        }
    }

    // MARK: Sections

    private mutating func finishSection() {
        defer {
            section = nil
            state = .preamble
        }
        guard var current = section else { return }

        guard let method = current.method else {
            if !current.declarations.isEmpty || !current.directives.isEmpty {
                document.diagnostics.append(.warning("this section has no request line", at: lineRange(current.startLine, source.line(current.startLine))))
            }
            return
        }

        let index = document.requests.count
        var request = RequestBlock(
            index: index,
            title: current.title,
            name: "",
            lines: current.startLine...current.lastLine,
            declarations: current.declarations,
            directives: current.directives,
            method: method,
            target: current.target,
            rawTarget: current.rawTarget,
            httpVersion: current.httpVersion,
            requestLine: current.requestLine,
            headers: current.headers,
            body: makeBody(&current),
            script: current.script
        )
        request.name = requestName(for: request, index: index)
        document.requests.append(request)
    }

    private mutating func makeBody(_ section: inout Section) -> Body? {
        var lines = section.bodyLines
        while let last = lines.last, last.text.allSatisfy(\.isWhitespace) { lines.removeLast() }
        while let first = lines.first, first.text.allSatisfy(\.isWhitespace) { lines.removeFirst() }
        guard let first = lines.first, let last = lines.last else { return nil }

        let range = first.number...last.number
        let firstTrimmed = Substring(first.text).trimmed
        if lines.count == 1, firstTrimmed.hasPrefix("< ") {
            let path = firstTrimmed.dropFirst(2).trimmed
            do {
                let template = try Template.parse(String(path), line: first.number, column: first.text.column(of: path))
                return Body(content: .file(path: template, rawPath: String(path)), lines: range)
            } catch {
                report(error, line: first.number)
                return nil
            }
        }

        var parts: [Template.Part] = []
        for (offset, line) in lines.enumerated() {
            if offset > 0 { parts.append(.text("\n")) }
            do {
                parts.append(contentsOf: try Template.parse(line.text, line: line.number).parts)
            } catch {
                report(error, line: line.number)
                parts.append(.text(line.text))
            }
        }
        let text = lines.map(\.text).joined(separator: "\n")
        return Body(content: .text(text, Template(parts: merge(parts))), lines: range)
    }

    private func requestName(for request: RequestBlock, index: Int) -> String {
        for directive in request.directives {
            if case .name(let name) = directive.kind { return name }
        }
        if let title = request.title?.stampIdentifier { return title }
        if let file = document.fileName.map({ ($0 as NSString).deletingPathExtension }), let base = file.stampIdentifier {
            return index == 0 ? base : base + String(index + 1)
        }
        return "request\(index + 1)"
    }

    private mutating func checkNames() {
        var seen: Set<String> = []
        for request in document.requests where !seen.insert(request.name).inserted {
            document.diagnostics.append(.warning(
                "another request is already named '\(request.name)'; use '@name' to tell them apart",
                at: lineRange(request.requestLine, source.line(request.requestLine))
            ))
        }
    }

    // MARK: Helpers

    private mutating func append(_ declaration: Declaration) {
        if section != nil {
            section?.declarations.append(declaration)
        } else {
            document.declarations.append(declaration)
        }
    }

    private mutating func append(_ directive: Directive) {
        if section != nil {
            section?.directives.append(directive)
        } else {
            document.directives.append(directive)
        }
    }

    private mutating func append(_ statement: ScriptStatement) {
        section?.script.append(statement)
        section?.lastLine = statement.line
    }

    private mutating func touch(_ line: Int) {
        section?.lastLine = line
    }

    private mutating func mark(_ line: Int, _ kind: LineKind) {
        document.lineKinds[line - 1] = kind
    }

    private mutating func error(_ message: String, line: Int, in text: String? = nil) {
        mark(line, .invalid)
        document.diagnostics.append(.error(message, at: lineRange(line, text ?? source.line(line))))
    }

    private mutating func report(_ diagnostic: Diagnostic, line: Int) {
        if diagnostic.severity == .error { mark(line, .invalid) }
        document.diagnostics.append(diagnostic)
    }

    private func lineRange(_ line: Int, _ text: String) -> SourceRange {
        let content = Substring(text).trimmed
        return SourceRange(line: line, column: text.column(of: content), length: content.utf16.count)
    }

    private func isComment(_ trimmed: Substring) -> Bool {
        (trimmed.hasPrefix("#") && !trimmed.hasPrefix("###")) || trimmed.hasPrefix("//")
    }

    private func requestLineParts(_ trimmed: Substring) -> (Substring, Substring)? {
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("{{") {
            return ("GET", trimmed)
        }
        if trimmed.hasPrefix("ws://") || trimmed.hasPrefix("wss://") {
            return ("WS", trimmed)
        }
        for (scheme, method) in [("stun:", "STUN"), ("stuns:", "STUN"), ("turn:", "TURN"), ("turns:", "TURN")] where trimmed.hasPrefix(scheme) {
            return (Substring(method), trimmed)
        }
        let method = trimmed.prefix { $0.isASCII && ($0.isUppercase || $0 == "-") }
        guard !method.isEmpty, method.first!.isLetter else { return nil }
        let rest = trimmed.dropFirst(method.count)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let target = rest.trimmed
        return target.isEmpty ? nil : (method, target)
    }

    private func headerParts(_ text: Substring) -> (name: Substring, value: Substring)? {
        let name = text.prefix { $0.isHeaderNameCharacter }
        guard !name.isEmpty, text.dropFirst(name.count).first == ":" else { return nil }
        let value = text.dropFirst(name.count + 1).trimmingLeadingWhitespace().trimmingTrailingWhitespace()
        return (name, value)
    }

    private func parseDuration(_ text: Substring) -> Double? {
        let number = text.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number) else { return nil }
        switch text.dropFirst(number.count).trimmed {
        case "", "s": return value
        case "ms": return value / 1000
        case "m": return value * 60
        default: return nil
        }
    }

    private func merge(_ parts: [Template.Part]) -> [Template.Part] {
        var merged: [Template.Part] = []
        for part in parts {
            if case .text(let next) = part, case .text(let previous)? = merged.last {
                merged[merged.count - 1] = .text(previous + next)
            } else {
                merged.append(part)
            }
        }
        return merged
    }
}

extension Character {
    var isIdentifierCharacter: Bool {
        isASCII && (isLetter || isNumber || self == "_" || self == "$")
    }

    var isHeaderNameCharacter: Bool {
        isASCII && (isLetter || isNumber || "!$%&'*+-.^_`|~".contains(self))
    }
}

extension StringProtocol {
    var isIdentifier: Bool {
        guard let first, first.isIdentifierCharacter, !first.isNumber else { return false }
        return allSatisfy(\.isIdentifierCharacter)
    }

    var isDimensionValue: Bool {
        !isEmpty && allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }
}

extension Substring {
    var trimmed: Substring {
        trimmingLeadingWhitespace().trimmingTrailingWhitespace()
    }

    func trimmingLeadingWhitespace() -> Substring {
        drop { $0 == " " || $0 == "\t" }
    }

    func trimmingTrailingWhitespace() -> Substring {
        var result = self
        while let last = result.last, last == " " || last == "\t" { result.removeLast() }
        return result
    }

    /// The text after `keyword` when the line starts with it as a whole word.
    func afterKeyword(_ keyword: String) -> Substring? {
        guard hasPrefix(keyword) else { return nil }
        let rest = dropFirst(keyword.count)
        guard let next = rest.first, next == " " || next == "\t" else { return nil }
        return rest.trimmingLeadingWhitespace()
    }
}

extension String {
    /// UTF-16 column at which a substring of this string starts.
    func column(of substring: Substring) -> Int {
        utf16.distance(from: startIndex, to: substring.startIndex)
    }
}
