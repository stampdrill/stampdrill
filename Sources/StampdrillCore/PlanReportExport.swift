import Foundation
import Stamp

/// Writes plan reports for CI systems and for people.
public enum PlanReportExport {
    // MARK: JUnit

    /// One test suite per iteration, one test case per step, request and top-level check.
    public static func junit(_ reports: [PlanReport]) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        let tests = reports.flatMap(\.iterations).map { testCases(in: $0.events).count }.reduce(0, +)
        let failures = reports.flatMap(\.iterations).map { testCases(in: $0.events).filter { !$0.passed }.count }.reduce(0, +)
        let time = reports.map(\.duration).reduce(0, +)
        xml += #"<testsuites name="stampdrill" tests="\#(tests)" failures="\#(failures)" time="\#(seconds(time))">"# + "\n"
        for report in reports {
            for iteration in report.iterations {
                let cases = testCases(in: iteration.events)
                let suiteName = escape("\(report.plan.name) [\(iteration.label)]")
                xml += #"  <testsuite name="\#(suiteName)" tests="\#(cases.count)" failures="\#(cases.filter { !$0.passed }.count)" time="\#(seconds(iteration.duration))" timestamp="\#(iteration.startedAt.formatted(.iso8601))">"# + "\n"
                for testCase in cases {
                    xml += #"    <testcase classname="\#(escape(report.plan.path))" name="\#(escape(testCase.name))" time="\#(seconds(testCase.duration))""#
                    if testCase.passed {
                        xml += "/>\n"
                    } else {
                        xml += ">\n"
                        xml += #"      <failure message="\#(escape(testCase.failures.first ?? "failed"))">\#(escape(testCase.failures.joined(separator: "\n")))</failure>"# + "\n"
                        xml += "    </testcase>\n"
                    }
                }
                xml += "  </testsuite>\n"
            }
        }
        xml += "</testsuites>\n"
        return xml
    }

    struct TestCase {
        var name: String
        var passed: Bool
        var duration: TimeInterval
        var failures: [String]
    }

    static func testCases(in events: [PlanEvent]) -> [TestCase] {
        events.compactMap { event in
            switch event.kind {
            case .step(let title, let children, let attempts):
                let failures = failureMessages(in: children)
                let name = attempts > 1 ? "\(title) (attempt \(attempts))" : title
                return TestCase(name: name, passed: failures.isEmpty, duration: event.duration, failures: failures)
            case .run(let result):
                return TestCase(name: "\(result.request?.method ?? "") \(result.reference.name)".trimmingCharacters(in: .whitespaces), passed: result.passed, duration: result.response?.duration ?? event.duration, failures: failureMessages(in: [event]))
            case .expectation(let source, let passed, let message):
                return TestCase(name: "expect \(source)", passed: passed, duration: 0, failures: passed ? [] : [message ?? source])
            case .failure(let message):
                return TestCase(name: "line \(event.line)", passed: false, duration: 0, failures: [message])
            case .print:
                return nil
            }
        }
    }

    public static func failureMessages(in events: [PlanEvent]) -> [String] {
        events.flatMap { event -> [String] in
            switch event.kind {
            case .run(let result):
                var messages = result.error.map { ["\(result.reference.name): \($0)"] } ?? []
                messages += result.assertions.filter { !$0.passed }.map { "\(result.reference.name): \($0.source)" + ($0.message.map { " (\($0))" } ?? "") }
                return messages
            case .expectation(let source, let passed, let message):
                return passed ? [] : ["expect \(source)" + (message.map { " (\($0))" } ?? "")]
            case .step(_, let children, _):
                return failureMessages(in: children)
            case .failure(let message):
                return [message]
            case .print:
                return []
            }
        }
    }

    // MARK: JSON

    public static func json(_ reports: [PlanReport]) -> String {
        let value: Value = .array(reports.map { report in
            [
                "plan": .string(report.plan.name),
                "file": .string(report.plan.path),
                "startedAt": .string(report.startedAt.formatted(.iso8601)),
                "duration": .number((report.duration * 1000).rounded()),
                "passed": .bool(report.passed),
                "iterations": .array(report.iterations.map { iteration in
                    [
                        "label": .string(iteration.label),
                        "passed": .bool(iteration.passed),
                        "duration": .number((iteration.duration * 1000).rounded()),
                        "events": .array(iteration.events.map(eventValue)),
                    ]
                }),
                "timings": .array(report.timings.map { timing in
                    [
                        "request": .string(timing.name),
                        "count": .number(Double(timing.count)),
                        "min": .number((timing.min * 1000).rounded()),
                        "average": .number((timing.average * 1000).rounded()),
                        "p95": .number((timing.p95 * 1000).rounded()),
                    ]
                }),
            ]
        })
        return value.jsonString(pretty: true) + "\n"
    }

    private static func eventValue(_ event: PlanEvent) -> Value {
        switch event.kind {
        case .run(let result):
            return [
                "type": "request",
                "name": .string(result.reference.name),
                "status": result.response.map { .number(Double($0.statusCode)) } ?? .null,
                "duration": result.response.map { .number(($0.duration * 1000).rounded()) } ?? .null,
                "passed": .bool(result.passed),
                "error": result.error.map(Value.string) ?? .null,
            ]
        case .expectation(let source, let passed, let message):
            return ["type": "expect", "source": .string(source), "passed": .bool(passed), "message": message.map(Value.string) ?? .null]
        case .step(let title, let children, let attempts):
            return ["type": "step", "title": .string(title), "attempts": .number(Double(attempts)), "passed": .bool(event.passed), "events": .array(children.map(eventValue))]
        case .print(let text):
            return ["type": "print", "text": .string(text)]
        case .failure(let message):
            return ["type": "failure", "message": .string(message), "line": .number(Double(event.line))]
        }
    }

    // MARK: HTML

    /// A single self-contained page, readable in any browser and easy to attach to a build.
    public static func html(_ reports: [PlanReport]) -> String {
        var body = ""
        for report in reports {
            let counts = report.expectationCounts
            body += """
            <section class="plan \(report.passed ? "passed" : "failed")">
              <header>
                <h2>\(escape(report.plan.name)) <span class="file">\(escape(report.plan.path))</span></h2>
                <p class="summary">\(report.passed ? "Passed" : "Failed") · \(report.iterations.count) iteration\(report.iterations.count == 1 ? "" : "s") · \(report.runs.count) requests · \(counts.passed) checks passed\(counts.failed > 0 ? ", \(counts.failed) failed" : "") · \(milliseconds(report.duration))</p>
              </header>

            """
            for iteration in report.iterations {
                body += """
                  <details class="iteration \(iteration.passed ? "passed" : "failed")"\(iteration.passed ? "" : " open")>
                    <summary><span class="dot"></span>\(escape(iteration.label))<span class="time">\(milliseconds(iteration.duration))</span></summary>
                    <ul>\(iteration.events.map(eventHTML).joined())</ul>
                  </details>

                """
            }
            if !report.timings.isEmpty {
                body += "  <table><thead><tr><th>Request</th><th>Runs</th><th>Min</th><th>Average</th><th>p95</th></tr></thead><tbody>"
                for timing in report.timings {
                    body += "<tr><td>\(escape(timing.name))</td><td>\(timing.count)</td><td>\(milliseconds(timing.min))</td><td>\(milliseconds(timing.average))</td><td>\(milliseconds(timing.p95))</td></tr>"
                }
                body += "</tbody></table>\n"
            }
            body += "</section>\n"
        }

        return """
        <!doctype html>
        <html lang="en">
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Stampdrill test report</title>
        <style>
        :root { color-scheme: light dark; --ok: #2f9e5a; --bad: #d64545; --muted: #8a8a8e; --line: rgba(128,128,128,.22); }
        body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0 auto; max-width: 960px; padding: 32px 24px; }
        h1 { font-size: 22px; margin: 0 0 24px; }
        h2 { font-size: 17px; margin: 0; }
        .file, .time, .summary { color: var(--muted); font-weight: normal; }
        .file { font-size: 13px; margin-left: 6px; }
        .plan { border: 1px solid var(--line); border-radius: 12px; padding: 16px 18px; margin-bottom: 20px; }
        .plan.failed { border-color: color-mix(in srgb, var(--bad) 45%, transparent); }
        .summary { margin: 4px 0 12px; }
        details { border-top: 1px solid var(--line); padding: 8px 0; }
        summary { cursor: pointer; display: flex; gap: 8px; align-items: center; font-weight: 600; }
        summary .time { margin-left: auto; font-weight: normal; }
        .dot { width: 8px; height: 8px; border-radius: 4px; background: var(--ok); display: inline-block; }
        .failed > summary .dot { background: var(--bad); }
        ul { list-style: none; margin: 6px 0 0 16px; padding: 0; }
        li { padding: 2px 0; }
        li.ok::before { content: "✓ "; color: var(--ok); }
        li.bad::before { content: "✗ "; color: var(--bad); }
        li.note { color: var(--muted); }
        code { font: 12.5px ui-monospace, SFMono-Regular, Menlo, monospace; }
        .detail { color: var(--muted); }
        table { width: 100%; border-collapse: collapse; margin-top: 12px; font-variant-numeric: tabular-nums; }
        th, td { text-align: left; padding: 4px 8px; border-bottom: 1px solid var(--line); }
        th { color: var(--muted); font-weight: 500; }
        </style>
        <h1>Stampdrill test report <span class="time">\(Date().formatted(date: .abbreviated, time: .shortened))</span></h1>
        \(body)
        </html>

        """
    }

    private static func eventHTML(_ event: PlanEvent) -> String {
        switch event.kind {
        case .run(let result):
            let status = result.response.map { "\($0.statusCode) · \(milliseconds($0.duration))" } ?? (result.error ?? "")
            var html = #"<li class="\#(result.passed ? "ok" : "bad")"><code>\#(escape(result.request?.method ?? "")) \#(escape(result.reference.name))</code> <span class="detail">\#(escape(status))</span>"#
            let failed = result.assertions.filter { !$0.passed }
            if !failed.isEmpty {
                html += "<ul>" + failed.map { #"<li class="bad"><code>\#(escape($0.source))</code> <span class="detail">\#(escape($0.message ?? ""))</span></li>"# }.joined() + "</ul>"
            }
            return html + "</li>"
        case .expectation(let source, let passed, let message):
            return #"<li class="\#(passed ? "ok" : "bad")"><code>expect \#(escape(source))</code> <span class="detail">\#(escape(message ?? ""))</span></li>"#
        case .step(let title, let children, let attempts):
            let retries = attempts > 1 ? #" <span class="detail">after \#(attempts) attempts</span>"# : ""
            return #"<li class="\#(event.passed ? "ok" : "bad")"><strong>\#(escape(title))</strong>\#(retries)<ul>\#(children.map(eventHTML).joined())</ul></li>"#
        case .print(let text):
            return #"<li class="note"><code>\#(escape(text))</code></li>"#
        case .failure(let message):
            return #"<li class="bad">\#(escape(message))</li>"#
        }
    }

    // MARK: Helpers

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.3f", interval)
    }

    private static func milliseconds(_ interval: TimeInterval) -> String {
        interval < 1 ? "\(Int((interval * 1000).rounded())) ms" : String(format: "%.2f s", interval)
    }
}
