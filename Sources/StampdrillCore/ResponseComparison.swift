import Foundation

/// What changed between two runs of the same request.
///
/// Reviewing a run against the one before it is the question people actually
/// ask of a response: not "what does it say" but "what moved". It is also what
/// you want when an agent wrote the assertions and you are deciding whether to
/// trust them.
public struct ResponseComparison: Sendable {
    public struct Change: Sendable, Identifiable {
        public var name: String
        public var before: String?
        public var after: String?
        public var id: String { name }

        public var kind: Kind {
            if before == nil { return .added }
            if after == nil { return .removed }
            return .changed
        }

        public enum Kind: Sendable { case added, removed, changed }
    }

    public struct Line: Sendable, Identifiable {
        public enum Kind: Sendable { case same, added, removed }
        public var kind: Kind
        public var text: String
        /// Line numbers in the older and newer body, when the line is in them.
        public var before: Int?
        public var after: Int?
        public var id: Int
    }

    public var statusBefore: Int?
    public var statusAfter: Int?
    public var durationBefore: TimeInterval?
    public var durationAfter: TimeInterval?
    public var sizeBefore: Int?
    public var sizeAfter: Int?
    /// Headers that appeared, disappeared or took a different value. Headers
    /// that change on every request are left out; they are noise, not news.
    public var headers: [Change] = []
    /// Assertions by name, so a check that started failing stands out.
    public var assertions: [Change] = []
    public var body: [Line] = []
    /// Set when the bodies can't be compared as text, such as two images.
    public var bodyNote: String?

    public var statusChanged: Bool { statusBefore != statusAfter }
    public var bodyChanged: Bool { body.contains { $0.kind != .same } }

    public var isUnchanged: Bool {
        !statusChanged && !bodyChanged && headers.isEmpty && assertions.isEmpty
    }

    /// Headers whose value differs on every response, so a diff of them says nothing.
    static let volatileHeaders: Set<String> = [
        "date", "age", "expires", "set-cookie", "etag", "last-modified", "x-request-id", "x-correlation-id",
        "x-trace-id", "cf-ray", "x-amz-request-id", "x-amz-id-2", "request-id", "x-runtime", "x-served-by",
        "x-timer", "x-cache", "x-cache-hits", "report-to", "nel", "content-security-policy-report-only",
        // Counters and traces: they move on every call and say nothing about the response.
        "x-ratelimit-reset", "x-ratelimit-remaining", "x-ratelimit-used", "ratelimit-reset", "ratelimit-remaining",
        "x-rate-limit-reset", "x-rate-limit-remaining", "x-response-time", "x-envoy-upstream-service-time",
        "server-timing", "traceparent", "tracestate", "x-amzn-trace-id", "x-github-request-id", "x-vercel-id",
        "x-fastly-request-id", "x-datadog-trace-id", "keep-alive", "x-powered-by-cache",
    ]

    public static func compare(_ older: RunResult, with newer: RunResult) -> ResponseComparison {
        var comparison = ResponseComparison()
        comparison.statusBefore = older.response?.statusCode
        comparison.statusAfter = newer.response?.statusCode
        comparison.durationBefore = older.response?.duration
        comparison.durationAfter = newer.response?.duration
        comparison.sizeBefore = older.response?.body.count
        comparison.sizeAfter = newer.response?.body.count
        comparison.headers = headerChanges(older.response?.headers ?? [], newer.response?.headers ?? [])
        comparison.assertions = assertionChanges(older.assertions, newer.assertions)

        switch (older.response, newer.response) {
        case (let old?, let new?):
            guard let oldText = old.formattedBody, let newText = new.formattedBody else {
                comparison.bodyNote = old.body == new.body
                    ? "Both bodies are \(old.kind.rawValue) and identical"
                    : "Both bodies are \(old.kind.rawValue); they differ but can't be shown as text"
                return comparison
            }
            comparison.body = diff(oldText, newText)
        case (nil, nil):
            comparison.bodyNote = "Neither run got a response"
        default:
            comparison.bodyNote = "One of the runs got no response"
        }
        return comparison
    }

    // MARK: Pieces

    static func headerChanges(_ older: [HTTPField], _ newer: [HTTPField]) -> [Change] {
        func table(_ fields: [HTTPField]) -> [String: String] {
            Dictionary(fields.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { "\($0), \($1)" })
        }
        let old = table(older), new = table(newer)
        var changes: [Change] = []
        for name in Set(old.keys).union(new.keys).sorted() where !volatileHeaders.contains(name) {
            guard old[name] != new[name] else { continue }
            changes.append(Change(name: name, before: old[name], after: new[name]))
        }
        return changes
    }

    static func assertionChanges(_ older: [AssertionResult], _ newer: [AssertionResult]) -> [Change] {
        func table(_ results: [AssertionResult]) -> [String: Bool] {
            Dictionary(results.map { ($0.source, $0.passed) }, uniquingKeysWith: { $0 && $1 })
        }
        let old = table(older), new = table(newer)
        var changes: [Change] = []
        for source in Set(old.keys).union(new.keys).sorted() {
            guard old[source] != new[source] else { continue }
            changes.append(Change(name: source, before: old[source].map(describe), after: new[source].map(describe)))
        }
        return changes
    }

    private static func describe(_ passed: Bool) -> String { passed ? "passed" : "failed" }

    // MARK: Text

    /// A unified line diff: the longest common subsequence, with the rest marked.
    ///
    /// Bodies are compared after formatting, so two JSON responses that differ
    /// only in whitespace read as unchanged.
    static func diff(_ older: String, _ newer: String) -> [Line] {
        let old = older.components(separatedBy: .newlines)
        let new = newer.components(separatedBy: .newlines)
        // Quadratic in the number of lines: fine for a response, and a huge one
        // is compared by its head so the window never grows without bound.
        let limit = 4000
        let oldLines = Array(old.prefix(limit)), newLines = Array(new.prefix(limit))

        var lengths = Array(repeating: Array(repeating: 0, count: newLines.count + 1), count: oldLines.count + 1)
        for i in stride(from: oldLines.count - 1, through: 0, by: -1) {
            for j in stride(from: newLines.count - 1, through: 0, by: -1) {
                lengths[i][j] = oldLines[i] == newLines[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var lines: [Line] = []
        var i = 0, j = 0, id = 0
        func append(_ kind: Line.Kind, _ text: String, before: Int?, after: Int?) {
            lines.append(Line(kind: kind, text: text, before: before, after: after, id: id))
            id += 1
        }
        while i < oldLines.count, j < newLines.count {
            if oldLines[i] == newLines[j] {
                append(.same, oldLines[i], before: i + 1, after: j + 1)
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                append(.removed, oldLines[i], before: i + 1, after: nil)
                i += 1
            } else {
                append(.added, newLines[j], before: nil, after: j + 1)
                j += 1
            }
        }
        while i < oldLines.count {
            append(.removed, oldLines[i], before: i + 1, after: nil)
            i += 1
        }
        while j < newLines.count {
            append(.added, newLines[j], before: nil, after: j + 1)
            j += 1
        }
        if old.count > limit || new.count > limit {
            append(.same, "… compared the first \(limit) lines", before: nil, after: nil)
        }
        return lines
    }

    /// The changed lines with a few unchanged ones around them, the way a diff is read.
    public func bodyHunks(context: Int = 3) -> [Line] {
        let changed = body.indices.filter { body[$0].kind != .same }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for index in changed {
            for offset in -context...context where body.indices.contains(index + offset) {
                keep.insert(index + offset)
            }
        }
        return body.indices.filter(keep.contains).map { body[$0] }
    }
}
