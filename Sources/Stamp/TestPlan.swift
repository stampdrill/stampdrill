import Foundation

/// A test plan: requests run in order, with checks between them, repeated
/// for dimension combinations and rows of data.
///
///     plan Checkout {
///       matrix user = emily|michael, page = *
///       data ./users.csv
///       parallel 2
///       retry 1 every 500ms
///       tags smoke
///
///       setup { run logIn }
///
///       step "List posts" {
///         run listPosts
///         expect status == 200
///         set first = body[0].id
///       }
///
///       teardown { run deleteAPost }
///     }
public struct TestPlan: Hashable, Sendable, Identifiable {
    public var name: String
    /// Set for `load` blocks, which run their scenario with many virtual users.
    public var load: LoadSettings?
    public var lines: ClosedRange<Int>
    /// Dimensions to run across; an empty list of values means all of them.
    public var matrix: [VariableSet.Condition] = []
    public var data: Template?
    public var parallel = 1
    public var retries = 0
    public var retryDelay: Double = 0
    public var timeout: Double?
    public var tags: [String] = []
    public var setup: [PlanStatement] = []
    public var body: [PlanStatement] = []
    public var teardown: [PlanStatement] = []

    public var id: String { name }
}

/// How a load test drives its scenario.
///
///     load Checkout {
///       users 20
///       ramp 10s
///       duration 1m
///       think 100ms..400ms
///       seed checkout
///       threshold p95 < 800ms
///       threshold errors < 1%
///       scenario { run listPosts }
///     }
public struct LoadSettings: Hashable, Sendable {
    public var users = 1
    public var ramp: Double = 0
    /// Seconds to keep going; when nil, `iterations` decides.
    public var duration: Double?
    /// Total scenario runs across all users.
    public var iterations: Int?
    public var thinkTime: ClosedRange<Double> = 0...0
    public var seed: String?
    public var thresholds: [LoadThreshold] = []

    public init() {}
}

public struct LoadThreshold: Hashable, Sendable, CustomStringConvertible {
    public enum Metric: String, Hashable, Sendable, CaseIterable {
        case p50, p90, p95, p99, avg, max, errors, rps, checks, requests
    }

    public enum Comparison: String, Hashable, Sendable {
        case less = "<"
        case lessOrEqual = "<="
        case greater = ">"
        case greaterOrEqual = ">="
    }

    public var metric: Metric
    public var comparison: Comparison
    /// Milliseconds for times, a fraction for percentages, a plain number otherwise.
    public var value: Double
    public var source: String

    public var description: String { source }

    public func holds(for measured: Double) -> Bool {
        switch comparison {
        case .less: measured < value
        case .lessOrEqual: measured <= value
        case .greater: measured > value
        case .greaterOrEqual: measured >= value
        }
    }
}

public struct PlanStatement: Hashable, Sendable {
    public indirect enum Kind: Hashable, Sendable {
        case run(String, with: [RunBinding])
        case expect(Expr, message: Expr?)
        case set(String, Expr)
        case `let`(String, Expr)
        case print(Expr)
        case wait(Double)
        case step(String, [PlanStatement])
        case repeatBlock(Expr, [PlanStatement])
        case forEach(String, Expr, [PlanStatement])
        case ifBlock(Expr, then: [PlanStatement], otherwise: [PlanStatement])
        /// Runs the body in this many actors at the same moment.
        case concurrently(Expr, [PlanStatement])
        /// Waits until every concurrent actor has reached the same label.
        case sync(String)
        /// Publishes a value to every actor and virtual user as `shared.name`.
        case share(String, Expr)
    }

    public var kind: Kind
    public var source: String
    public var line: Int
}

public struct RunBinding: Hashable, Sendable {
    public var name: String
    public var value: Expr
}

/// Parses `plan` blocks, fed one line at a time by `DocumentParser`.
struct PlanParser {
    private enum Block {
        case plan
        case setup
        case teardown
        case step(String, line: Int, source: String)
        case repeatBlock(Expr, line: Int, source: String)
        case forEach(String, Expr, line: Int, source: String)
        case ifThen(Expr, line: Int, source: String)
        case ifElse(Expr, then: [PlanStatement], line: Int, source: String)
        case concurrently(Expr, line: Int, source: String)
        case scenario
        /// A block whose opening line had an error; kept so braces still pair up.
        case invalid
    }

    private(set) var plan: TestPlan
    private var stack: [(block: Block, statements: [PlanStatement])] = [(.plan, [])]
    private(set) var diagnostics: [Diagnostic] = []

    init(name: String, line: Int, isLoad: Bool = false) {
        plan = TestPlan(name: name, lines: line...line)
        if isLoad { plan.load = LoadSettings() }
    }

    var isFinished: Bool { stack.isEmpty }

    mutating func parse(_ line: String, trimmed: Substring, number: Int) {
        plan.lines = plan.lines.lowerBound...number

        // `setup { run logIn }` on one line is an opening, a statement and a closing.
        if trimmed.count > 1, trimmed.hasSuffix("}"), let open = trimmed.firstIndex(of: "{"),
           ["setup", "teardown", "step", "repeat", "for", "if", "concurrently", "scenario"].contains(where: { trimmed.hasPrefix($0) })
        {
            let opening = trimmed[...open]
            let inner = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)].trimmed
            parse(line, trimmed: opening, number: number)
            if !inner.isEmpty { parse(line, trimmed: inner, number: number) }
            parse(line, trimmed: "}", number: number)
            return
        }
        let error = { (message: String) in
            Diagnostic.error(message, at: SourceRange(line: number, column: line.column(of: trimmed), length: max(trimmed.utf16.count, 1)))
        }

        do throws(Diagnostic) {
            if trimmed == "}" {
                try close(number)
                return
            }
            if trimmed.hasPrefix("}"), let rest = trimmed.dropFirst().trimmed.afterKeyword("else"), rest.trimmed == "{" {
                guard case .ifThen(let condition, let start, let source)? = stack.last?.block else {
                    throw error("'else' must follow an 'if' block")
                }
                let then = stack.removeLast().statements
                stack.append((.ifElse(condition, then: then, line: start, source: source), []))
                return
            }

            let atTop = stack.count == 1
            if atTop, plan.load != nil, try parseLoadSetting(trimmed, error: error) {
                return
            }
            if atTop, plan.load != nil, trimmed == "scenario {" || trimmed == "scenario{" {
                stack.append((.scenario, []))
            } else if atTop, let rest = trimmed.afterKeyword("matrix") {
                plan.matrix = try matrix(rest, error: error)
            } else if atTop, let rest = trimmed.afterKeyword("data") {
                plan.data = try Template.parse(String(rest), line: number, column: line.column(of: rest))
            } else if atTop, let rest = trimmed.afterKeyword("parallel") {
                guard let count = Int(rest.trimmed), count > 0 else { throw error("'parallel' needs a positive number") }
                plan.parallel = min(count, 32)
            } else if atTop, let rest = trimmed.afterKeyword("retry") {
                let parts = rest.split(separator: " ", omittingEmptySubsequences: true)
                guard let count = parts.first.flatMap({ Int($0) }), count >= 0 else { throw error("expected 'retry 2' or 'retry 2 every 500ms'") }
                plan.retries = count
                if parts.count == 3, parts[1] == "every", let delay = duration(parts[2]) {
                    plan.retryDelay = delay
                } else if parts.count != 1 {
                    throw error("expected 'retry 2' or 'retry 2 every 500ms'")
                }
            } else if atTop, let rest = trimmed.afterKeyword("timeout") {
                guard let seconds = duration(rest.trimmed) else { throw error("'timeout' needs a duration such as 30s or 2m") }
                plan.timeout = seconds
            } else if atTop, let rest = trimmed.afterKeyword("tags") {
                plan.tags = rest.split(separator: ",").map { String($0.trimmed) }.filter { !$0.isEmpty }
            } else if atTop, trimmed == "setup {" || trimmed == "setup{" {
                stack.append((.setup, []))
            } else if atTop, trimmed == "teardown {" || trimmed == "teardown{" {
                stack.append((.teardown, []))
            } else if let rest = trimmed.afterKeyword("step"), rest.hasSuffix("{") {
                let title = rest.dropLast().trimmed
                guard title.count >= 2, title.first == "\"", title.last == "\"" else { throw error("expected 'step \"title\" {'") }
                stack.append((.step(String(title.dropFirst().dropLast()), line: number, source: String(trimmed)), []))
            } else if let rest = trimmed.afterKeyword("repeat"), rest.hasSuffix("{") {
                let count = rest.dropLast()
                stack.append((.repeatBlock(try ExprParser.parse(String(count), line: number, column: line.column(of: count)), line: number, source: String(trimmed)), []))
            } else if let rest = trimmed.afterKeyword("for"), let each = rest.afterKeyword("each"), each.hasSuffix("{") {
                let name = each.prefix { $0.isIdentifierCharacter }
                guard name.isIdentifier, let list = each.dropFirst(name.count).trimmed.afterKeyword("in") else {
                    throw error("expected 'for each item in list {'")
                }
                let expression = list.dropLast()
                stack.append((.forEach(String(name), try ExprParser.parse(String(expression), line: number, column: line.column(of: expression)), line: number, source: String(trimmed)), []))
            } else if let rest = trimmed.afterKeyword("concurrently"), rest.hasSuffix("{") {
                let count = rest.dropLast()
                stack.append((.concurrently(try ExprParser.parse(String(count), line: number, column: line.column(of: count)), line: number, source: String(trimmed)), []))
            } else if let rest = trimmed.afterKeyword("if"), rest.hasSuffix("{") {
                let condition = rest.dropLast()
                stack.append((.ifThen(try ExprParser.parse(String(condition), line: number, column: line.column(of: condition)), line: number, source: String(trimmed)), []))
            } else {
                append(try statement(line, trimmed: trimmed, number: number, error: error))
            }
        } catch {
            diagnostics.append(error)
            if trimmed.hasSuffix("{") { stack.append((.invalid, [])) }
        }
    }

    mutating func finish(at line: Int) {
        if !stack.isEmpty {
            diagnostics.append(.error("missing '}' to close plan '\(plan.name)'", at: SourceRange(line: plan.lines.lowerBound, length: 4)))
            while !stack.isEmpty { try? close(line) }
        }
    }

    private mutating func statement(
        _ line: String, trimmed: Substring, number: Int, error: (String) -> Diagnostic
    ) throws(Diagnostic) -> PlanStatement {
        let source = String(trimmed)
        func expression(_ text: Substring) throws(Diagnostic) -> Expr {
            try ExprParser.parse(String(text), line: number, column: line.column(of: text))
        }

        if let rest = trimmed.afterKeyword("run") {
            let name = rest.prefix { $0.isIdentifierCharacter }
            guard name.isIdentifier else { throw error("expected 'run requestName'") }
            var bindings: [RunBinding] = []
            let after = rest.dropFirst(name.count).trimmed
            if let with = after.afterKeyword("with") {
                var parser = try ExprParser(String(with), line: number, column: line.column(of: with))
                repeat {
                    let key = try parser.identifier()
                    guard parser.consume(.equal) else { throw error("expected 'name = value' after 'with'") }
                    bindings.append(RunBinding(name: key, value: try parser.expression()))
                } while parser.consume(.comma)
                try parser.expectEnd()
            } else if !after.isEmpty {
                throw error("expected 'with name = value' after the request name")
            }
            return PlanStatement(kind: .run(String(name), with: bindings), source: source, line: number)
        }
        if let rest = trimmed.afterKeyword("expect") ?? trimmed.afterKeyword("assert") {
            var parser = try ExprParser(String(rest), line: number, column: line.column(of: rest))
            let condition = try parser.expression()
            let message = parser.consume(.comma) ? try parser.expression() : nil
            try parser.expectEnd()
            return PlanStatement(kind: .expect(condition, message: message), source: source, line: number)
        }
        if let rest = trimmed.afterKeyword("set") ?? trimmed.afterKeyword("let") {
            let name = rest.prefix { $0.isIdentifierCharacter }
            let value = rest.dropFirst(name.count).trimmingLeadingWhitespace()
            guard name.isIdentifier, value.hasPrefix("=") else { throw error("expected '\(trimmed.prefix(3)) name = value'") }
            let expr = try expression(value.dropFirst())
            return PlanStatement(kind: trimmed.hasPrefix("set") ? .set(String(name), expr) : .let(String(name), expr), source: source, line: number)
        }
        if let rest = trimmed.afterKeyword("print") {
            return PlanStatement(kind: .print(try expression(rest)), source: source, line: number)
        }
        if let rest = trimmed.afterKeyword("share") {
            let name = rest.prefix { $0.isIdentifierCharacter }
            let value = rest.dropFirst(name.count).trimmingLeadingWhitespace()
            guard name.isIdentifier, value.hasPrefix("=") else { throw error("expected 'share name = value'") }
            return PlanStatement(kind: .share(String(name), try expression(value.dropFirst())), source: source, line: number)
        }
        if let rest = trimmed.afterKeyword("sync") {
            let label = rest.trimmed
            guard label.count >= 2, label.first == "\"", label.last == "\"" else { throw error("expected 'sync \"label\"'") }
            return PlanStatement(kind: .sync(String(label.dropFirst().dropLast())), source: source, line: number)
        }
        if let rest = trimmed.afterKeyword("wait") {
            guard let seconds = duration(rest.trimmed) else { throw error("'wait' needs a duration such as 500ms or 2s") }
            return PlanStatement(kind: .wait(seconds), source: source, line: number)
        }
        throw error("expected run, expect, set, let, print, wait, share, sync, step, repeat, for each, concurrently or if")
    }

    private mutating func append(_ statement: PlanStatement) {
        stack[stack.count - 1].statements.append(statement)
    }

    private mutating func close(_ line: Int) throws(Diagnostic) {
        guard let (block, statements) = stack.popLast() else {
            throw .error("unexpected '}'", at: SourceRange(line: line, length: 1))
        }
        switch block {
        case .plan:
            // A load test's steps come from its scenario block.
            if plan.load == nil || !statements.isEmpty { plan.body += statements }
        case .setup:
            plan.setup = statements
        case .teardown:
            plan.teardown = statements
        case .step(let title, let start, let source):
            append(PlanStatement(kind: .step(title, statements), source: source, line: start))
        case .repeatBlock(let count, let start, let source):
            append(PlanStatement(kind: .repeatBlock(count, statements), source: source, line: start))
        case .forEach(let name, let list, let start, let source):
            append(PlanStatement(kind: .forEach(name, list, statements), source: source, line: start))
        case .ifThen(let condition, let start, let source):
            append(PlanStatement(kind: .ifBlock(condition, then: statements, otherwise: []), source: source, line: start))
        case .ifElse(let condition, let then, let start, let source):
            append(PlanStatement(kind: .ifBlock(condition, then: then, otherwise: statements), source: source, line: start))
        case .concurrently(let count, let start, let source):
            append(PlanStatement(kind: .concurrently(count, statements), source: source, line: start))
        case .scenario:
            plan.body = statements
        case .invalid:
            break
        }
    }

    /// `users`, `ramp`, `duration`, `iterations`, `think`, `seed` and `threshold` lines.
    private mutating func parseLoadSetting(_ trimmed: Substring, error: (String) -> Diagnostic) throws(Diagnostic) -> Bool {
        guard var load = plan.load else { return false }
        defer { plan.load = load }
        if let rest = trimmed.afterKeyword("users") {
            guard let users = Int(rest.trimmed), users > 0 else { throw error("'users' needs a positive number") }
            load.users = min(users, 2000)
        } else if let rest = trimmed.afterKeyword("ramp") {
            guard let seconds = duration(rest.trimmed) else { throw error("'ramp' needs a duration such as 10s") }
            load.ramp = seconds
        } else if let rest = trimmed.afterKeyword("duration") {
            guard let seconds = duration(rest.trimmed), seconds > 0 else { throw error("'duration' needs a duration such as 1m") }
            load.duration = seconds
        } else if let rest = trimmed.afterKeyword("iterations") {
            guard let count = Int(rest.trimmed), count > 0 else { throw error("'iterations' needs a positive number") }
            load.iterations = count
        } else if let rest = trimmed.afterKeyword("think") {
            let parts = rest.trimmed.components(separatedBy: "..")
            guard let low = duration(parts[0]), let high = parts.count > 1 ? duration(parts[1]) : low, low <= high else {
                throw error("'think' needs a duration or a range such as 200ms..1s")
            }
            load.thinkTime = low...high
        } else if let rest = trimmed.afterKeyword("seed") {
            load.seed = String(rest.trimmed).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        } else if let rest = trimmed.afterKeyword("threshold") {
            load.thresholds.append(try threshold(rest, error: error))
        } else {
            return false
        }
        return true
    }

    private func threshold(_ text: Substring, error: (String) -> Diagnostic) throws(Diagnostic) -> LoadThreshold {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        let usage = "expected 'threshold p95 < 800ms', 'threshold errors < 1%' or 'threshold rps > 50'"
        guard parts.count == 3, let metric = LoadThreshold.Metric(rawValue: String(parts[0])),
              let comparison = LoadThreshold.Comparison(rawValue: String(parts[1]))
        else { throw error(usage) }
        var raw = String(parts[2])
        let value: Double
        switch metric {
        case .p50, .p90, .p95, .p99, .avg, .max:
            guard let seconds = duration(raw) else { throw error(usage) }
            value = seconds * 1000
        case .errors, .checks:
            let isPercent = raw.hasSuffix("%")
            if isPercent { raw.removeLast() }
            guard let number = Double(raw) else { throw error(usage) }
            value = isPercent || number > 1 ? number / 100 : number
        case .rps, .requests:
            guard let number = Double(raw) else { throw error(usage) }
            value = number
        }
        return LoadThreshold(metric: metric, comparison: comparison, value: value, source: String(text.trimmed))
    }

    private func matrix(_ text: Substring, error: (String) -> Diagnostic) throws(Diagnostic) -> [VariableSet.Condition] {
        var conditions: [VariableSet.Condition] = []
        for item in text.split(separator: ",") {
            let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmed }
            guard parts.count == 2, parts[0].isIdentifier || parts[0].allSatisfy({ $0.isLetter || $0 == "-" || $0 == "_" }) else {
                throw error("expected 'matrix environment = qa|prod, region = *'")
            }
            let values = parts[1] == "*" ? [] : parts[1].split(separator: "|").map { String($0.trimmed) }
            conditions.append(VariableSet.Condition(dimension: String(parts[0]), values: values))
        }
        return conditions
    }

    private func duration<S: StringProtocol>(_ text: S) -> Double? {
        let number = text.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number) else { return nil }
        switch text.dropFirst(number.count) {
        case "", "s": return value
        case "ms": return value / 1000
        case "m": return value * 60
        default: return nil
        }
    }
}
