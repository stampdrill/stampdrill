public struct HeaderDraft: Hashable, Sendable {
    public var name: String
    public var value: String
    public var isEnabled: Bool

    public init(name: String, value: String, isEnabled: Bool = true) {
        self.name = name
        self.value = value
        self.isEnabled = isEnabled
    }
}

/// Structured edits to the requests of a file, applied to its text.
///
/// Like `EnvironmentEditor`, only the lines that change are rewritten: the
/// request line, the header block, the body, the script. Comments and
/// variables around them stay where they are.
public struct RequestEditor {
    public private(set) var text: String
    private let fileName: String?

    public init(text: String, fileName: String? = nil) {
        self.text = text
        self.fileName = fileName
    }

    public var document: Document { Document.parse(text, fileName: fileName) }

    // MARK: Request line

    public mutating func setRequestLine(method: String, target: String, of name: String) {
        guard let request = document.request(named: name) else { return }
        let version = request.httpVersion.map { " " + $0 } ?? ""
        let method = method.trimmingCharacters(in: .whitespaces).uppercased()
        replace(request.requestLine...request.requestLine, with: ["\(method.isEmpty ? "GET" : method) \(target.trimmingCharacters(in: .whitespaces))\(version)"])
    }

    // MARK: Headers

    public mutating func setHeaders(_ headers: [HeaderDraft], of name: String) {
        let document = document
        guard let request = document.request(named: name) else { return }
        let region = headerRegion(of: request, in: document)
        let comments = region.map { range in
            range.filter { document.lineKinds[$0 - 1] == .comment }.map { document.source.line($0) }
        } ?? []
        let lines = headers
            .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { ($0.isEnabled ? "" : "# ") + $0.name.trimmingCharacters(in: .whitespaces) + ": " + $0.value }
            + comments

        if let region {
            replace(region, with: lines)
        } else if !lines.isEmpty {
            insert(lines, after: request.requestLine)
        }
    }

    /// Lines after the request line that belong to the header block.
    private func headerRegion(of request: RequestBlock, in document: Document) -> ClosedRange<Int>? {
        var last = request.requestLine
        var line = request.requestLine + 1
        while line <= request.lines.upperBound {
            switch document.lineKinds[line - 1] {
            case .header, .disabledHeader, .comment, .invalid:
                last = line
                line += 1
            default:
                return last > request.requestLine ? (request.requestLine + 1)...last : nil
            }
        }
        return last > request.requestLine ? (request.requestLine + 1)...last : nil
    }

    // MARK: Body

    /// Replaces the body; nil or empty text removes it.
    public mutating func setBody(_ body: String?, of name: String) {
        let document = document
        guard let request = document.request(named: name) else { return }
        let lines = body.map { SourceText($0).lines } ?? []
        let isEmpty = lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }

        if let existing = request.body {
            if isEmpty {
                // Drop the blank line that separated headers from the body too.
                var start = existing.lines.lowerBound
                if start > 1, document.source.line(start - 1).trimmingCharacters(in: .whitespaces).isEmpty { start -= 1 }
                replace(start...existing.lines.upperBound, with: [])
            } else {
                replace(existing.lines, with: lines)
            }
            return
        }
        guard !isEmpty else { return }

        let anchor = headerRegion(of: request, in: document)?.upperBound ?? request.requestLine
        var inserted = [""] + lines
        if let firstScript = request.script.first?.line, firstScript == anchor + 1 {
            inserted.append("")
        }
        insert(inserted, after: anchor)
    }

    // MARK: Auth

    /// Sets the request's own `@auth`; nil removes it so the file's applies.
    public mutating func setAuth(_ arguments: String?, of name: String) {
        let document = document
        guard let request = document.request(named: name) else { return }
        let existing = request.directives.last { if case .auth = $0.kind { true } else { false } }
        let line = arguments.map { "@auth " + $0 }

        switch (existing, line) {
        case let (existing?, line?):
            replace(existing.line...existing.line, with: [line])
        case let (existing?, nil):
            replace(existing.line...existing.line, with: [])
        case let (nil, line?):
            insert([line], after: request.requestLine - 1)
        case (nil, nil):
            break
        }
    }

    // MARK: Script

    /// Replaces the `>` lines. Pass statements without the leading `>`.
    public mutating func setScript(_ statements: [String], of name: String) {
        let document = document
        guard let request = document.request(named: name) else { return }
        let lines = statements
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "> " + $0 }

        if let first = request.script.first?.line, let last = request.script.last?.line {
            if lines.isEmpty {
                var start = first
                if start > 1, document.source.line(start - 1).trimmingCharacters(in: .whitespaces).isEmpty { start -= 1 }
                replace(start...last, with: [])
            } else {
                replace(first...last, with: lines)
            }
        } else if !lines.isEmpty {
            let anchor = request.body?.lines.upperBound ?? headerRegion(of: request, in: document)?.upperBound ?? request.requestLine
            insert([""] + lines, after: anchor)
        }
    }

    /// Adds statements after the script, leaving what is already there as written.
    public mutating func appendScript(_ statements: [String], of name: String) {
        guard let request = document.request(named: name) else { return }
        guard let last = request.script.last?.line else { return setScript(statements, of: name) }
        let lines = statements
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "> " + $0 }
        guard !lines.isEmpty else { return }
        insert(lines, after: last)
    }

    // MARK: Sections

    public mutating func setTitle(_ title: String, of name: String) {
        let document = document
        guard let request = document.request(named: name) else { return }
        let line = "### " + title.trimmingCharacters(in: .whitespaces)
        if request.lines.lowerBound < request.requestLine, document.lineKinds[request.lines.lowerBound - 1] == .separator {
            replace(request.lines.lowerBound...request.lines.lowerBound, with: [line])
        } else {
            insert([line], after: request.lines.lowerBound - 1)
        }
    }

    /// Adds a request at the end of the file and returns its name.
    @discardableResult
    public mutating func appendRequest(title: String, method: String = "GET", target: String = "https://") -> String {
        var lines = SourceText(text).lines
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        if !lines.isEmpty { lines.append("") }
        lines += ["### " + title, "\(method) \(target)"]
        text = lines.joined(separator: "\n") + "\n"
        return document.requests.last?.name ?? ""
    }

    public mutating func removeRequest(named name: String) {
        let document = document
        guard let request = document.request(named: name) else { return }
        var end = request.lines.upperBound
        while end < document.source.lineCount, document.lineKinds[end] == .blank, document.request(atLine: end + 1) == nil {
            end += 1
        }
        replace(request.lines.lowerBound...end, with: [])
    }

    /// Copies a request right below itself and returns the copy's name.
    @discardableResult
    public mutating func duplicateRequest(named name: String) -> String? {
        let document = document
        guard let request = document.request(named: name) else { return nil }
        var lines = Array(document.source.lines[(request.lines.lowerBound - 1)..<request.lines.upperBound])
        let title = (request.title ?? request.name) + " copy"
        if document.lineKinds[request.lines.lowerBound - 1] == .separator {
            lines[0] = "### " + title
        } else {
            lines.insert("### " + title, at: 0)
        }
        // An explicit @name would clash with the original.
        lines = lines.map { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("@name ") ? "@name \(name)Copy" : line
        }
        insert([""] + lines, after: request.lines.upperBound)
        return Document.parse(text, fileName: fileName).requests.first { $0.index == request.index + 1 }?.name
    }

    // MARK: Helpers

    private mutating func replace(_ range: ClosedRange<Int>, with replacement: [String]) {
        var lines = SourceText(text).lines
        let lower = max(range.lowerBound - 1, 0)
        let upper = min(range.upperBound, lines.count)
        guard lower <= upper else { return }
        lines.replaceSubrange(lower..<upper, with: replacement)
        text = lines.joined(separator: "\n")
    }

    private mutating func insert(_ inserted: [String], after line: Int) {
        var lines = SourceText(text).lines
        lines.insert(contentsOf: inserted, at: min(max(line, 0), lines.count))
        text = lines.joined(separator: "\n")
    }
}
