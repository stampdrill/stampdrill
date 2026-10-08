import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StampdrillCore
import Stamp

/// `stampdrill test`: runs test plans and writes reports.
struct TestCommand {
    let arguments: Arguments
    let terminal: Terminal

    func execute() async throws -> Int32 {
        let t = terminal
        let target = try WorkspaceTarget(arguments.paths)
        let workspace = target.workspace

        var plans = target.files.flatMap { file in file.document.plans.filter { $0.load == nil }.map { (file, $0) } }
        if !arguments.names.isEmpty {
            plans = plans.filter { arguments.names.contains($0.1.name) }
        }
        if !arguments.tags.isEmpty {
            plans = plans.filter { !Set($0.1.tags).isDisjoint(with: arguments.tags) }
        }
        guard !plans.isEmpty else {
            terminal.error("no test plans found" + (arguments.tags.isEmpty ? "" : " tagged \(arguments.tags.joined(separator: ", "))"))
            return 2
        }
        for (file, _) in plans where file.document.hasErrors {
            printDiagnostics(file, terminal: t)
            return 2
        }

        var selection = workspace.environment.defaultSelection
        for (name, value) in arguments.dimensions {
            selection[name] = value == "*" ? nil : value
        }
        let runner = PlanRunner(
            workspace: workspace,
            selection: selection,
            overrides: Dictionary(arguments.variables.map { ($0.0, Value.string($0.1)) }) { _, last in last },
            transport: PlatformHTTPTransport(userAgent: "stampdrill")
        )

        var reports: [PlanReport] = []
        for (file, plan) in plans {
            t.out(t.paint("▶ \(plan.name)", .bold) + t.paint("  \(file.relativePath)", .gray))
            let report = try await runner.run(PlanReference(path: file.relativePath, name: plan.name)) { iteration in
                printIteration(iteration)
            }
            reports.append(report)
            let counts = report.expectationCounts
            let line = "\(report.iterations.count) iteration\(report.iterations.count == 1 ? "" : "s"), \(report.runs.count) requests, \(counts.passed + counts.failed) checks, \(formatDuration(report.duration))"
            t.out((report.passed ? t.paint("✓ ", .green, .bold) : t.paint("✗ ", .red, .bold)) + line)
            if arguments.verbose {
                for timing in report.timings {
                    t.out(t.paint("  \(timing.name.padding(toLength: 24, withPad: " ", startingAt: 0)) avg \(formatDuration(timing.average))  p95 \(formatDuration(timing.p95))  ×\(timing.count)", .gray))
                }
            }
            t.out()
        }

        try write(PlanReportExport.junit(reports), to: arguments.junitPath)
        try write(PlanReportExport.stampXML(plans: reports, generator: "\(Stampdrill.name) \(Stampdrill.version)",
                                           stylesheet: arguments.stampXMLStylesheet ?? PlanReportExport.stampXMLStylesheet),
                  to: arguments.stampXMLPath)
        try write(PlanReportExport.html(reports), to: arguments.htmlPath)
        try write(PlanReportExport.json(reports), to: arguments.jsonPath)

        let failed = reports.filter { !$0.passed }.count
        if failed > 0 {
            t.out(t.paint("✗ \(failed) of \(reports.count) plan\(reports.count == 1 ? "" : "s") failed", .red, .bold))
        } else {
            t.out(t.paint("✓ all \(reports.count) plan\(reports.count == 1 ? "" : "s") passed", .green, .bold))
        }
        return failed == 0 ? 0 : 1
    }

    private func printIteration(_ iteration: PlanIteration) {
        let t = terminal
        let mark = iteration.passed ? t.paint("✓", .green) : t.paint("✗", .red)
        t.out("  \(mark) \(iteration.label)  \(t.paint(formatDuration(iteration.duration), .dim))")
        guard !iteration.passed || arguments.verbose else { return }
        for message in PlanReportExport.failureMessages(in: iteration.events) {
            t.out("    " + t.paint(message, .red))
        }
    }

    private func write(_ text: String, to path: String?) throws {
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        terminal.out(terminal.paint("wrote \(path)", .gray))
    }
}
