import Foundation
import Stamp

/// Measurements of a load test, as they stand at one moment.
public struct LoadSnapshot: Sendable {
    public struct Second: Sendable, Identifiable {
        public var second: Int
        public var requests: Int
        public var errors: Int
        /// Milliseconds.
        public var p95: Double
        public var users: Int
        public var id: Int { second }
    }

    public struct RequestStats: Sendable, Identifiable {
        public var name: String
        public var count: Int
        public var failures: Int
        /// Milliseconds.
        public var average: Double
        public var p95: Double
        public var id: String { name }
    }

    public var elapsed: TimeInterval = 0
    public var activeUsers = 0
    public var iterations = 0
    public var requests = 0
    public var failedRequests = 0
    public var checksPassed = 0
    public var checksFailed = 0
    /// Milliseconds.
    public var p50: Double = 0
    public var p90: Double = 0
    public var p95: Double = 0
    public var p99: Double = 0
    public var average: Double = 0
    public var maximum: Double = 0
    public var series: [Second] = []
    public var perRequest: [RequestStats] = []

    public init() {}

    public var requestsPerSecond: Double { elapsed > 0 ? Double(requests) / elapsed : 0 }
    public var errorRate: Double { requests > 0 ? Double(failedRequests) / Double(requests) : 0 }
    public var checkRate: Double { checksPassed + checksFailed > 0 ? Double(checksPassed) / Double(checksPassed + checksFailed) : 1 }

    public func measured(_ metric: LoadThreshold.Metric) -> Double {
        switch metric {
        case .p50: p50
        case .p90: p90
        case .p95: p95
        case .p99: p99
        case .avg: average
        case .max: maximum
        case .errors: errorRate
        case .rps: requestsPerSecond
        case .checks: checkRate
        case .requests: Double(requests)
        }
    }
}

public struct LoadReport: Sendable, Identifiable {
    public struct ThresholdResult: Sendable, Identifiable {
        public var threshold: LoadThreshold
        public var measured: Double
        public var passed: Bool
        public var id: String { threshold.source }
    }

    public let id = UUID()
    public var plan: PlanReference
    public var startedAt: Date
    public var snapshot: LoadSnapshot
    public var thresholds: [ThresholdResult]
    /// A sample of what went wrong, most frequent first.
    public var failures: [(message: String, count: Int)]

    public var passed: Bool {
        thresholds.allSatisfy(\.passed) && (thresholds.isEmpty ? snapshot.failedRequests == 0 && snapshot.checksFailed == 0 : true)
    }
}

/// Runs a `load` block: virtual users repeat the scenario while the clock or
/// the iteration budget lasts.
///
/// Each iteration runs in a fresh session copied from the setup's, with `vu`
/// (the virtual user), `iteration` (its count for that user) and `run` (the
/// iteration's number across the whole test) set. When the test has a `seed`,
/// `seed` becomes "<seed>-<run>", so `uuid("order")` names the same order in
/// every request of an iteration, and the same orders come back next time.
public struct LoadRunner: Sendable {
    public var workspace: Workspace
    public var selection: DimensionSelection
    public var overrides: [String: Value]
    public let transport: any HTTPTransport

    public init(workspace: Workspace, selection: DimensionSelection = [:], overrides: [String: Value] = [:], transport: any HTTPTransport) {
        self.workspace = workspace
        self.selection = selection
        self.overrides = overrides
        self.transport = transport
    }

    public func run(_ reference: PlanReference, onUpdate: (@Sendable (LoadSnapshot) -> Void)? = nil) async throws -> LoadReport {
        guard let file = workspace.file(at: reference.path),
              let plan = file.document.plans.first(where: { $0.name == reference.name }), let load = plan.load
        else {
            throw PlanError.notFound("no load test named '\(reference.name)' in \(reference.path)")
        }

        let startedAt = Date()
        let clock = ContinuousClock()
        let start = clock.now
        let metrics = LoadMetrics(start: startedAt)
        let shared = SharedValues()

        // Setup runs once; every iteration starts from its session.
        let setupSession = Session()
        let setupRunner = Runner(workspace: workspace, selection: selection, overrides: overrides, session: setupSession, transport: transport)
        let setup = Execution(runner: setupRunner, file: file, plan: plan, deadline: nil, shared: shared)
        let setupEvents = await setup.run(plan.setup)
        await metrics.record(setupEvents, countRequests: false)
        let setupLocals = setup.locals

        let duration = load.duration ?? (load.iterations == nil ? 30 : nil)
        let deadline = duration.map { start + .milliseconds(Int($0 * 1000)) }
        let budget = IterationBudget(limit: load.iterations)

        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                onUpdate?(await metrics.snapshot())
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for vu in 0..<load.users {
                group.addTask {
                    if load.ramp > 0, load.users > 1 {
                        try? await Task.sleep(for: .milliseconds(Int(load.ramp * 1000 * Double(vu) / Double(load.users))))
                    }
                    await metrics.userStarted()
                    var iteration = 0
                    var random = SeededRandom(seed: (load.seed ?? UUID().uuidString) + "-think-\(vu)")
                    while !Task.isCancelled {
                        if let deadline, clock.now >= deadline { break }
                        guard let run = await budget.claim() else { break }

                        var iterationOverrides = overrides
                        iterationOverrides["vu"] = .number(Double(vu))
                        iterationOverrides["iteration"] = .number(Double(iteration))
                        iterationOverrides["run"] = .number(Double(run))
                        if let seed = load.seed {
                            iterationOverrides["seed"] = .string("\(seed)-\(run)")
                        }
                        let session = await Session(copying: setupSession)
                        let runner = Runner(workspace: workspace, selection: selection, overrides: iterationOverrides, session: session, transport: transport)
                        let execution = Execution(runner: runner, file: file, plan: plan, deadline: nil, shared: shared)
                        execution.locals = setupLocals
                        let events = await execution.run(plan.body)
                        await metrics.record(events, countRequests: true)
                        await metrics.iterationFinished()
                        iteration += 1

                        if load.thinkTime.upperBound > 0 {
                            let span = load.thinkTime.upperBound - load.thinkTime.lowerBound
                            let pause = load.thinkTime.lowerBound + span * Double(random.int(0...1000)) / 1000
                            try? await Task.sleep(for: .milliseconds(Int(pause * 1000)))
                        }
                    }
                    await metrics.userStopped()
                }
            }
        }
        ticker.cancel()

        let teardownRunner = Runner(workspace: workspace, selection: selection, overrides: overrides, session: await Session(copying: setupSession), transport: transport)
        let teardown = Execution(runner: teardownRunner, file: file, plan: plan, deadline: nil, shared: shared)
        await metrics.record(await teardown.run(plan.teardown), countRequests: false)

        let snapshot = await metrics.snapshot()
        onUpdate?(snapshot)
        let thresholds = load.thresholds.map { threshold in
            let measured = snapshot.measured(threshold.metric)
            return LoadReport.ThresholdResult(threshold: threshold, measured: measured, passed: threshold.holds(for: measured))
        }
        return LoadReport(plan: reference, startedAt: startedAt, snapshot: snapshot, thresholds: thresholds, failures: await metrics.failureSummary())
    }
}

/// Numbers iterations across users, and stops handing them out at the limit.
private actor IterationBudget {
    let limit: Int?
    private var used = 0

    init(limit: Int?) {
        self.limit = limit
    }

    func claim() -> Int? {
        if let limit, used >= limit { return nil }
        used += 1
        return used - 1
    }
}

private actor LoadMetrics {
    struct Sample {
        var name: String
        var offset: TimeInterval
        var duration: Double
        var failed: Bool
    }

    let start: Date
    private var samples: [Sample] = []
    private var checksPassed = 0
    private var checksFailed = 0
    private var iterations = 0
    private var activeUsers = 0
    private var usersBySecond: [Int: Int] = [:]
    private var failures: [String: Int] = [:]

    init(start: Date) {
        self.start = start
    }

    func userStarted() {
        activeUsers += 1
        usersBySecond[currentSecond] = max(usersBySecond[currentSecond] ?? 0, activeUsers)
    }

    func userStopped() {
        activeUsers -= 1
    }

    func iterationFinished() {
        iterations += 1
    }

    private var currentSecond: Int { Int(Date().timeIntervalSince(start)) }

    func record(_ events: [PlanEvent], countRequests: Bool) {
        for run in events.flatMap(\.runs) where countRequests {
            let failed = run.error != nil || (run.response.map { $0.statusCode >= 400 } ?? true)
            samples.append(Sample(
                name: run.reference.name,
                offset: run.startedAt.timeIntervalSince(start),
                duration: (run.response?.duration ?? 0) * 1000,
                failed: failed
            ))
            if let error = run.error {
                failures["\(run.reference.name): \(error)", default: 0] += 1
            } else if let status = run.response?.statusCode, status >= 400 {
                failures["\(run.reference.name): HTTP \(status)", default: 0] += 1
            }
        }
        for expectation in events.flatMap(\.expectations) {
            if expectation.passed {
                checksPassed += 1
            } else {
                checksFailed += 1
                failures[expectation.source + (expectation.message.map { " (\($0))" } ?? ""), default: 0] += 1
            }
        }
        for message in PlanReportExport.failureMessages(in: events.filter { if case .failure = $0.kind { true } else { false } }) {
            failures[message, default: 0] += 1
        }
        usersBySecond[currentSecond] = max(usersBySecond[currentSecond] ?? 0, activeUsers)
    }

    func failureSummary() -> [(message: String, count: Int)] {
        failures.sorted { $0.value > $1.value }.prefix(20).map { ($0.key, $0.value) }
    }

    func snapshot() -> LoadSnapshot {
        var snapshot = LoadSnapshot()
        snapshot.elapsed = Date().timeIntervalSince(start)
        snapshot.activeUsers = activeUsers
        snapshot.iterations = iterations
        snapshot.requests = samples.count
        snapshot.failedRequests = samples.filter(\.failed).count
        snapshot.checksPassed = checksPassed
        snapshot.checksFailed = checksFailed

        let durations = samples.map(\.duration).sorted()
        snapshot.p50 = percentile(durations, 0.50)
        snapshot.p90 = percentile(durations, 0.90)
        snapshot.p95 = percentile(durations, 0.95)
        snapshot.p99 = percentile(durations, 0.99)
        snapshot.average = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
        snapshot.maximum = durations.last ?? 0

        let bySecond = Dictionary(grouping: samples) { Int($0.offset) }
        let lastSecond = max(Int(snapshot.elapsed), bySecond.keys.max() ?? 0)
        var users = 0
        snapshot.series = (0...max(lastSecond, 0)).map { second in
            let bucket = bySecond[second] ?? []
            users = usersBySecond[second] ?? users
            return .init(
                second: second, requests: bucket.count, errors: bucket.filter(\.failed).count,
                p95: percentile(bucket.map(\.duration).sorted(), 0.95), users: users
            )
        }
        snapshot.perRequest = Dictionary(grouping: samples, by: \.name).map { name, bucket in
            let sorted = bucket.map(\.duration).sorted()
            return .init(
                name: name, count: bucket.count, failures: bucket.filter(\.failed).count,
                average: sorted.reduce(0, +) / Double(max(sorted.count, 1)), p95: percentile(sorted, 0.95)
            )
        }
        .sorted { $0.name < $1.name }
        return snapshot
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(Int((Double(sorted.count) * fraction).rounded(.up)) - 1, sorted.count - 1)
        return sorted[max(index, 0)]
    }
}

extension LoadReport {
    public var json: String {
        let s = snapshot
        let value: Value = [
            "test": .string(plan.name),
            "file": .string(plan.path),
            "startedAt": .string(startedAt.formatted(.iso8601)),
            "passed": .bool(passed),
            "duration": .number((s.elapsed * 1000).rounded()),
            "requests": .number(Double(s.requests)),
            "failedRequests": .number(Double(s.failedRequests)),
            "iterations": .number(Double(s.iterations)),
            "rps": .number(s.requestsPerSecond.rounded(toPlaces: 2)),
            "latency": ["p50": .number(s.p50.rounded()), "p90": .number(s.p90.rounded()), "p95": .number(s.p95.rounded()), "p99": .number(s.p99.rounded()), "avg": .number(s.average.rounded()), "max": .number(s.maximum.rounded())],
            "checks": ["passed": .number(Double(s.checksPassed)), "failed": .number(Double(s.checksFailed))],
            "thresholds": .array(thresholds.map { ["threshold": .string($0.threshold.source), "measured": .number($0.measured.rounded(toPlaces: 3)), "passed": .bool($0.passed)] }),
            "series": .array(s.series.map { ["second": .number(Double($0.second)), "requests": .number(Double($0.requests)), "errors": .number(Double($0.errors)), "p95": .number($0.p95.rounded()), "users": .number(Double($0.users))] }),
            "requestsByName": .array(s.perRequest.map { ["name": .string($0.name), "count": .number(Double($0.count)), "failures": .number(Double($0.failures)), "avg": .number($0.average.rounded()), "p95": .number($0.p95.rounded())] }),
            "failures": .array(failures.map { ["message": .string($0.message), "count": .number(Double($0.count))] }),
        ]
        return value.jsonString(pretty: true) + "\n"
    }
}
