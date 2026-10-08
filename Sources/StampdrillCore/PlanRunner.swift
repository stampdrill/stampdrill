import Foundation
import Stamp

public struct PlanReference: Hashable, Codable, Sendable {
    public var path: String
    public var name: String

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

/// Something that happened while a plan ran, nested the way the plan is.
public struct PlanEvent: Identifiable, Sendable {
    public enum Kind: Sendable {
        case run(RunResult)
        case expectation(source: String, passed: Bool, message: String?)
        case print(String)
        case step(title: String, events: [PlanEvent], attempts: Int)
        case failure(String)
    }

    /// What a `concurrently` block adds to the steps it produces, so a report can
    /// show actors side by side instead of as plain nested steps.
    public enum Concurrency: Sendable, Hashable {
        case group(actors: Int)
        case actor(index: Int)
    }

    public let id = UUID()
    public var kind: Kind
    public var line: Int
    public var duration: TimeInterval = 0
    public var concurrency: Concurrency?

    public var passed: Bool {
        switch kind {
        case .run(let result): result.passed
        case .expectation(_, let passed, _): passed
        case .print: true
        case .step(_, let events, _): events.allSatisfy(\.passed)
        case .failure: false
        }
    }

    /// Every request result below this event.
    public var runs: [RunResult] {
        switch kind {
        case .run(let result): [result]
        case .step(_, let events, _): events.flatMap(\.runs)
        default: []
        }
    }

    public var expectations: [(source: String, passed: Bool, message: String?)] {
        switch kind {
        case .expectation(let source, let passed, let message): [(source, passed, message)]
        case .run(let result): result.assertions.map { ($0.source, $0.passed, $0.message) }
        case .step(_, let events, _): events.flatMap(\.expectations)
        default: []
        }
    }
}

public struct PlanIteration: Identifiable, Sendable {
    public let id = UUID()
    public var index: Int
    /// "user=emily, page=small · row 2"
    public var label: String
    public var selection: DimensionSelection
    public var row: [String: Value]
    public var events: [PlanEvent] = []
    public var startedAt = Date()
    public var duration: TimeInterval = 0

    public var passed: Bool { events.allSatisfy(\.passed) }
}

public struct PlanReport: Identifiable, Sendable {
    public let id = UUID()
    public var plan: PlanReference
    public var startedAt: Date
    public var duration: TimeInterval = 0
    public var iterations: [PlanIteration] = []

    public var passed: Bool { !iterations.isEmpty && iterations.allSatisfy(\.passed) }

    public var runs: [RunResult] { iterations.flatMap { $0.events.flatMap(\.runs) } }

    public var expectationCounts: (passed: Int, failed: Int) {
        let all = iterations.flatMap { $0.events.flatMap(\.expectations) }
        let passed = all.filter(\.passed).count
        return (passed, all.count - passed)
    }

    /// Response times per request name: min, average and 95th percentile, in seconds.
    public var timings: [(name: String, count: Int, min: Double, average: Double, p95: Double)] {
        let grouped = Dictionary(grouping: runs.compactMap { run in run.response.map { (run.reference.name, $0.duration) } }, by: \.0)
        return grouped.map { name, samples in
            let durations = samples.map(\.1).sorted()
            let p95 = durations[min(Int((Double(durations.count) * 0.95).rounded(.up)) - 1, durations.count - 1)]
            return (name, durations.count, durations.first ?? 0, durations.reduce(0, +) / Double(durations.count), p95)
        }
        .sorted { $0.name < $1.name }
    }
}

public enum PlanError: Error, LocalizedError, Sendable {
    case notFound(String)
    case invalidData(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let message), .invalidData(let message): message
        }
    }
}

/// Runs test plans. Every iteration gets its own session, so iterations
/// don't see each other's tokens or saved values and can run in parallel.
public struct PlanRunner: Sendable {
    public var workspace: Workspace
    public var selection: DimensionSelection
    public var overrides: [String: Value]
    public var defaultTimeout: TimeInterval
    public let transport: any HTTPTransport

    public init(
        workspace: Workspace, selection: DimensionSelection = [:], overrides: [String: Value] = [:],
        defaultTimeout: TimeInterval = 30, transport: any HTTPTransport
    ) {
        self.workspace = workspace
        self.selection = selection
        self.overrides = overrides
        self.defaultTimeout = defaultTimeout
        self.transport = transport
    }

    public func plan(_ reference: PlanReference) -> (WorkspaceFile, TestPlan)? {
        guard let file = workspace.file(at: reference.path), let plan = file.document.plans.first(where: { $0.name == reference.name }) else {
            return nil
        }
        return (file, plan)
    }

    public func run(
        _ reference: PlanReference, onIteration: (@Sendable (PlanIteration) -> Void)? = nil
    ) async throws -> PlanReport {
        guard let (file, plan) = plan(reference) else {
            throw PlanError.notFound("no plan named '\(reference.name)' in \(reference.path)")
        }
        var report = PlanReport(plan: reference, startedAt: Date())
        let clock = ContinuousClock()
        let start = clock.now

        let combinations = matrixCombinations(plan.matrix, in: workspace.environment(for: file))
        let rows = try dataRows(plan, file: file)
        var work: [(index: Int, selection: DimensionSelection, row: [String: Value], label: String)] = []
        for combination in combinations {
            for (rowIndex, row) in rows.enumerated() {
                var labels = plan.matrix.compactMap { condition in combination[condition.dimension].map { "\(condition.dimension)=\($0)" } }
                if rows.count > 1 { labels.append("row \(rowIndex + 1)") }
                work.append((work.count, selection.merging(combination) { _, new in new }, row, labels.isEmpty ? "run" : labels.joined(separator: ", ")))
            }
        }

        let limit = max(plan.parallel, 1)
        let iterations = await withTaskGroup(of: PlanIteration.self) { group in
            var results: [PlanIteration] = []
            var next = 0
            func enqueue(_ item: (index: Int, selection: DimensionSelection, row: [String: Value], label: String)) {
                group.addTask {
                    let iteration = await runIteration(plan, file: file, index: item.index, selection: item.selection, row: item.row, label: item.label)
                    onIteration?(iteration)
                    return iteration
                }
            }
            while next < min(limit, work.count) {
                enqueue(work[next])
                next += 1
            }
            for await iteration in group {
                results.append(iteration)
                if next < work.count, !Task.isCancelled {
                    enqueue(work[next])
                    next += 1
                }
            }
            return results.sorted { $0.index < $1.index }
        }

        report.iterations = iterations
        let elapsed = clock.now - start
        report.duration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return report
    }

    // MARK: Iterations

    private func runIteration(
        _ plan: TestPlan, file: WorkspaceFile, index: Int, selection: DimensionSelection, row: [String: Value], label: String
    ) async -> PlanIteration {
        var iteration = PlanIteration(index: index, label: label, selection: selection, row: row)
        let clock = ContinuousClock()
        let start = clock.now
        let session = Session()
        let execution = Execution(
            runner: Runner(
                workspace: workspace, selection: selection, overrides: overrides.merging(row) { _, new in new },
                defaultTimeout: defaultTimeout, session: session, transport: transport
            ),
            file: file,
            plan: plan,
            deadline: plan.timeout.map { clock.now + .milliseconds(Int($0 * 1000)) },
            shared: SharedValues()
        )

        var events = await execution.run(plan.setup)
        if events.allSatisfy(\.passed) {
            events += await execution.run(plan.body)
        }
        events += await execution.run(plan.teardown)
        iteration.events = events
        let elapsed = clock.now - start
        iteration.duration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return iteration
    }

    public func matrixCombinations(_ matrix: [VariableSet.Condition], in environment: EnvironmentMatrix) -> [DimensionSelection] {
        var combinations: [DimensionSelection] = [[:]]
        for condition in matrix {
            let values = condition.values.isEmpty ? (environment.dimension(named: condition.dimension)?.values ?? []) : condition.values
            guard !values.isEmpty else { continue }
            combinations = combinations.flatMap { combination in
                values.map { combination.merging([condition.dimension: $0]) { _, new in new } }
            }
        }
        return combinations
    }

    public func dataRows(_ plan: TestPlan, file: WorkspaceFile) throws -> [[String: Value]] {
        guard let template = plan.data else { return [[:]] }
        let scope = Scope(builtins: Builtins.standard)
        let path = try scope.render(template).trimmingCharacters(in: .whitespaces)
        let url = resolvePath(path, in: file.url.deletingLastPathComponent())
        guard let data = try? Data(contentsOf: url) else {
            throw PlanError.invalidData("plan '\(plan.name)': cannot read data file '\(path)'")
        }
        if url.pathExtension.lowercased() == "json" {
            guard case .array(let items) = try Value(json: data) else {
                throw PlanError.invalidData("plan '\(plan.name)': '\(path)' must hold an array of objects")
            }
            return items.map { item in
                guard case .object(let object) = item else { return ["item": item] }
                return Dictionary(uniqueKeysWithValues: object.map { ($0.key, $0.value) })
            }
        }
        let rows = CSV.parse(String(decoding: data, as: UTF8.self))
        guard let header = rows.first else { return [[:]] }
        let records = rows.dropFirst().filter { !$0.allSatisfy(\.isEmpty) }.map { cells in
            Dictionary(uniqueKeysWithValues: header.enumerated().map { index, name in
                let cell = index < cells.count ? cells[index] : ""
                return (name, Double(cell).map(Value.number) ?? .string(cell))
            })
        }
        return records.isEmpty ? [[:]] : records
    }
}

/// One iteration's state while it runs: its runner, plan variables and the
/// last response, which `expect` statements look at.
final class Execution: @unchecked Sendable {
    let runner: Runner
    let file: WorkspaceFile
    let plan: TestPlan
    let deadline: ContinuousClock.Instant?
    let shared: SharedValues
    /// Set for actors inside `concurrently`, so `sync` can line them up.
    let barrier: Barrier?
    var locals: [String: Value] = [:]
    var lastResponse: Value?

    init(runner: Runner, file: WorkspaceFile, plan: TestPlan, deadline: ContinuousClock.Instant?, shared: SharedValues, barrier: Barrier? = nil) {
        self.runner = runner
        self.file = file
        self.plan = plan
        self.deadline = deadline
        self.shared = shared
        self.barrier = barrier
    }

    func run(_ statements: [PlanStatement]) async -> [PlanEvent] {
        var events: [PlanEvent] = []
        for statement in statements {
            if Task.isCancelled { break }
            if let deadline, ContinuousClock().now > deadline {
                events.append(PlanEvent(kind: .failure("plan timed out"), line: statement.line))
                break
            }
            events += await execute(statement)
        }
        return events
    }

    private func execute(_ statement: PlanStatement) async -> [PlanEvent] {
        let clock = ContinuousClock()
        let start = clock.now
        func timed(_ event: PlanEvent) -> PlanEvent {
            var event = event
            let elapsed = clock.now - start
            event.duration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return event
        }

        do throws(EvaluationError) {
            switch statement.kind {
            case .run(let name, let bindings):
                guard let reference = runner.workspace.request(named: name, near: file) else {
                    return [PlanEvent(kind: .failure("no request named '\(name)'"), line: statement.line)]
                }
                var runner = self.runner
                let scope = await self.scope()
                for binding in bindings {
                    runner.overrides[binding.name] = try scope.evaluate(binding.value)
                }
                for (name, value) in locals where runner.overrides[name] == nil {
                    runner.overrides[name] = value
                }
                let results = await runner.run(reference)
                if let last = results.last?.response {
                    lastResponse = Runner.value(of: last)
                }
                return results.map { timed(PlanEvent(kind: .run($0), line: statement.line)) }

            case .expect(let condition, let message):
                let scope = await self.scope()
                let passed = try scope.evaluate(condition).isTruthy
                var detail: String?
                if !passed {
                    if let message {
                        detail = try scope.evaluate(message).interpolated
                    } else if case .binary(_, let lhs, _) = condition, let actual = try? scope.evaluate(lhs) {
                        detail = "\(lhs) is \(actual.debugText)"
                    }
                }
                let source = String(statement.source.drop { !$0.isWhitespace }.drop(while: \.isWhitespace))
                return [PlanEvent(kind: .expectation(source: source, passed: passed, message: detail), line: statement.line)]

            case .set(let name, let expr):
                let value = try await scope().evaluate(expr)
                await runner.session.set(name, value)
                locals[name] = value
                return []

            case .let(let name, let expr):
                locals[name] = try await scope().evaluate(expr)
                return []

            case .print(let expr):
                return [PlanEvent(kind: .print(try await scope().evaluate(expr).interpolated), line: statement.line)]

            case .wait(let seconds):
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                return []

            case .step(let title, let body):
                var attempts = 0
                var events: [PlanEvent] = []
                repeat {
                    attempts += 1
                    if attempts > 1, plan.retryDelay > 0 {
                        try? await Task.sleep(for: .milliseconds(Int(plan.retryDelay * 1000)))
                    }
                    events = await run(body)
                } while !events.allSatisfy(\.passed) && attempts <= plan.retries && !Task.isCancelled
                return [timed(PlanEvent(kind: .step(title: title, events: events, attempts: attempts), line: statement.line))]

            case .repeatBlock(let countExpr, let body):
                guard case .number(let count) = try await scope().evaluate(countExpr) else {
                    return [PlanEvent(kind: .failure("'repeat' needs a number"), line: statement.line)]
                }
                var events: [PlanEvent] = []
                for index in 0..<max(Int(count), 0) {
                    locals["index"] = .number(Double(index))
                    events += await run(body)
                }
                return events

            case .forEach(let name, let listExpr, let body):
                guard case .array(let items) = try await scope().evaluate(listExpr) else {
                    return [PlanEvent(kind: .failure("'for each' needs a list"), line: statement.line)]
                }
                var events: [PlanEvent] = []
                for (index, item) in items.enumerated() {
                    locals[name] = item
                    locals["index"] = .number(Double(index))
                    events += await run(body)
                }
                return events

            case .ifBlock(let condition, let then, let otherwise):
                return await run(try await scope().evaluate(condition).isTruthy ? then : otherwise)

            case .share(let name, let expr):
                await shared.set(name, try await scope().evaluate(expr))
                return []

            case .sync(let label):
                guard let barrier else {
                    return [PlanEvent(kind: .failure("'sync' only works inside 'concurrently'"), line: statement.line)]
                }
                if await !barrier.arrive(label) {
                    return [PlanEvent(kind: .failure("sync \"\(label)\": not every actor arrived within \(Int(Barrier.timeout)) s"), line: statement.line)]
                }
                return []

            case .concurrently(let countExpr, let body):
                guard case .number(let requested) = try await scope().evaluate(countExpr), requested >= 1 else {
                    return [PlanEvent(kind: .failure("'concurrently' needs a number of actors"), line: statement.line)]
                }
                let count = min(Int(requested), 500)
                let barrier = Barrier(parties: count)
                let actors = await withTaskGroup(of: (Int, [PlanEvent], Value?).self) { group in
                    for index in 0..<count {
                        group.addTask { [self] in
                            let session = await Session(copying: runner.session)
                            let actorRunner = Runner(
                                workspace: runner.workspace, selection: runner.selection, overrides: runner.overrides,
                                defaultTimeout: runner.defaultTimeout, session: session, transport: runner.transport, webSockets: runner.webSockets, ice: runner.ice, mcp: runner.mcp
                            )
                            let actor = Execution(runner: actorRunner, file: file, plan: plan, deadline: deadline, shared: shared, barrier: barrier)
                            actor.locals = locals
                            actor.locals["actor"] = .number(Double(index))
                            // Everyone starts at the same moment.
                            _ = await barrier.arrive("start")
                            let events = await actor.run(body)
                            return (index, events, actor.lastResponse)
                        }
                    }
                    var collected: [(Int, [PlanEvent], Value?)] = []
                    for await entry in group { collected.append(entry) }
                    return collected.sorted { $0.0 < $1.0 }
                }
                locals["results"] = .array(actors.map { $0.2 ?? .null })
                let events = actors.map { index, events, _ in
                    PlanEvent(kind: .step(title: "actor \(index)", events: events, attempts: 1), line: statement.line, concurrency: .actor(index: index))
                }
                return [timed(PlanEvent(kind: .step(title: "\(count) at once", events: events, attempts: 1), line: statement.line, concurrency: .group(actors: count)))]
            }
        } catch {
            return [PlanEvent(kind: .failure("line \(statement.line): \(error.message)"), line: statement.line)]
        }
    }

    /// Variables for plan expressions: the environment, the session, the
    /// iteration's data row, plan locals and the last response on top.
    private func scope() async -> Scope {
        let input = ResolutionInput(selection: runner.selection, session: await runner.session.bindings, overrides: runner.overrides)
        let scope = RequestResolver.scope(for: nil, in: file, workspace: runner.workspace, input: input)
        var top: [String: ScopeBinding] = locals.mapValues { .value($0) }
        top["shared"] = .value(.object(ObjectValue(await shared.values.sorted { $0.key < $1.key })))
        if case .object(let fields)? = lastResponse {
            top["response"] = .value(lastResponse!)
            for (key, value) in fields where top[key] == nil { top[key] = .value(value) }
        }
        scope.push(Scope.Layer("plan", top))
        return scope
    }
}

/// Values published with `share`, visible to every actor and virtual user.
actor SharedValues {
    private(set) var values: [String: Value] = [:]

    func set(_ name: String, _ value: Value) {
        values[name] = value
    }
}

/// Holds actors at a label until all of them have arrived, then lets them go together.
actor Barrier {
    static let timeout: TimeInterval = 30

    let parties: Int
    private var waiting: [String: [CheckedContinuation<Bool, Never>]] = [:]

    init(parties: Int) {
        self.parties = parties
    }

    /// Returns false when the others didn't show up in time.
    func arrive(_ label: String) async -> Bool {
        await withCheckedContinuation { continuation in
            waiting[label, default: []].append(continuation)
            if waiting[label]!.count >= parties {
                release(label, arrived: true)
            } else if waiting[label]!.count == 1 {
                Task {
                    try? await Task.sleep(for: .seconds(Self.timeout))
                    self.release(label, arrived: false)
                }
            }
        }
    }

    private func release(_ label: String, arrived: Bool) {
        guard let continuations = waiting.removeValue(forKey: label) else { return }
        for continuation in continuations { continuation.resume(returning: arrived) }
    }
}

enum CSV {
    /// RFC 4180 style: commas (or `delimiter`), quoted fields with "" escapes, CRLF or LF.
    static func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            if quoted {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else {
                            quoted = false
                            if next == delimiter { row.append(field); field = "" }
                            else if next == "\n" || next == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
                            else { field.append(next) }
                        }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                quoted = true
            } else if character == delimiter {
                row.append(field)
                field = ""
            } else if character == "\n" || character == "\r\n" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.map { $0.map { $0.trimmingCharacters(in: .whitespaces) } }
    }
}
