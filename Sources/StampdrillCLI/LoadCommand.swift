import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StampdrillCore
import Stamp

/// `stampdrill load`: runs load tests with a live line and a summary.
struct LoadCommand {
    let arguments: Arguments
    let terminal: Terminal

    func execute() async throws -> Int32 {
        let t = terminal
        let target = try WorkspaceTarget(arguments.paths)
        var tests = target.files.flatMap { file in file.document.plans.filter { $0.load != nil }.map { (file, $0) } }
        if !arguments.names.isEmpty { tests = tests.filter { arguments.names.contains($0.1.name) } }
        if !arguments.tags.isEmpty { tests = tests.filter { !Set($0.1.tags).isDisjoint(with: arguments.tags) } }
        guard !tests.isEmpty else {
            terminal.error("no load tests found")
            return 2
        }

        var selection = target.workspace.environment.defaultSelection
        for (name, value) in arguments.dimensions { selection[name] = value == "*" ? nil : value }
        let runner = LoadRunner(
            workspace: target.workspace, selection: selection,
            overrides: Dictionary(arguments.variables.map { ($0.0, Value.string($0.1)) }) { _, last in last },
            transport: PlatformHTTPTransport(userAgent: "stampdrill")
        )

        var reports: [LoadReport] = []
        for (file, plan) in tests {
            let load = plan.load!
            let shape = load.iterations.map { "\($0) iterations" } ?? "\(formatDuration(load.duration ?? 30))"
            t.out(t.paint("▶ \(plan.name)", .bold) + t.paint("  \(file.relativePath) · \(load.users) users · \(shape)", .gray))
            let live = isatty(STDOUT_FILENO) == 1
            let report = try await runner.run(PlanReference(path: file.relativePath, name: plan.name)) { snapshot in
                guard live else { return }
                let line = String(format: "  %4.0fs  users %3d  requests %5d  rps %6.1f  p95 %5.0f ms  errors %5.1f%%",
                                  snapshot.elapsed, snapshot.activeUsers, snapshot.requests, snapshot.requestsPerSecond, snapshot.p95, snapshot.errorRate * 100)
                FileHandle.standardOutput.write(Data(("\r" + t.paint(line, .gray) + "\u{1B}[K").utf8))
            }
            if live { FileHandle.standardOutput.write(Data("\r\u{1B}[K".utf8)) }
            reports.append(report)
            printSummary(report)
        }

        if let path = arguments.stampXMLPath {
            let xml = PlanReportExport.stampXML(loads: reports, generator: "\(Stampdrill.name) \(Stampdrill.version)",
                                                stylesheet: arguments.stampXMLStylesheet ?? PlanReportExport.stampXMLStylesheet)
            try Data(xml.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            t.out(t.paint("wrote \(path)", .gray))
        }
        if let path = arguments.jsonPath {
            let text = reports.count == 1 ? reports[0].json : "[\n" + reports.map(\.json).joined(separator: ",\n") + "]\n"
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            t.out(t.paint("wrote \(path)", .gray))
        }
        return reports.allSatisfy(\.passed) ? 0 : 1
    }

    private func printSummary(_ report: LoadReport) {
        let t = terminal
        let s = report.snapshot
        t.out("  requests  \(s.requests) in \(formatDuration(s.elapsed)), \(String(format: "%.1f", s.requestsPerSecond))/s, \(s.failedRequests) failed (\(String(format: "%.1f", s.errorRate * 100))%)")
        t.out("  latency   p50 \(ms(s.p50))  p90 \(ms(s.p90))  p95 \(ms(s.p95))  p99 \(ms(s.p99))  max \(ms(s.maximum))")
        t.out("  checks    \(s.checksPassed) passed, \(s.checksFailed) failed · \(s.iterations) iterations")
        for stats in s.perRequest {
            t.out(t.paint("    \(stats.name.padding(toLength: 22, withPad: " ", startingAt: 0)) ×\(stats.count)  avg \(ms(stats.average))  p95 \(ms(stats.p95))\(stats.failures > 0 ? "  \(stats.failures) failed" : "")", .gray))
        }
        for result in report.thresholds {
            let measured = switch result.threshold.metric {
            case .errors, .checks: String(format: "%.2f%%", result.measured * 100)
            case .rps: String(format: "%.1f/s", result.measured)
            case .requests: String(Int(result.measured))
            default: ms(result.measured)
            }
            t.out("  " + (result.passed ? t.paint("✓", .green) : t.paint("✗", .red)) + " threshold \(result.threshold.source)  " + t.paint("(\(measured))", .gray))
        }
        for failure in report.failures.prefix(5) {
            t.out(t.paint("    ×\(failure.count) \(failure.message)", .red))
        }
        t.out((report.passed ? t.paint("✓ passed", .green, .bold) : t.paint("✗ failed", .red, .bold)))
        t.out()
    }

    private func ms(_ value: Double) -> String {
        "\(Int(value.rounded())) ms"
    }
}
