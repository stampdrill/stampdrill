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

    /// The version of the report format. It is also in the address the page loads
    /// its elements from, so a report written today keeps rendering the way it did today.
    public static let reportVersion = "1.0"
    public static let reportAssets = "https://stampdrill.com/report/\(reportVersion)/"

    /// One file for both readers: a machine parses the elements, a browser defines
    /// them from the module the page names and draws the page.
    ///
    /// The markup carries measurements and nothing about how they look. Test plans,
    /// the actors of a `concurrently` block and load tests all go in the same
    /// document, so one run is one file. It parses as HTML and as XML.
    public static func html(
        plans: [PlanReport] = [],
        loads: [LoadReport] = [],
        generator: String,
        assets: String = reportAssets
    ) -> String {
        let counts = plans.map(\.expectationCounts)
        let checksPassed = counts.map(\.passed).reduce(0, +) + loads.map(\.snapshot.checksPassed).reduce(0, +)
        let checksFailed = counts.map(\.failed).reduce(0, +) + loads.map(\.snapshot.checksFailed).reduce(0, +)
        let requests = plans.map(\.runs.count).reduce(0, +) + loads.map(\.snapshot.requests).reduce(0, +)
        let failed = plans.filter { !$0.passed }.count + loads.filter { !$0.passed }.count
        let iterations = plans.flatMap(\.iterations).count
        let started = (plans.map(\.startedAt) + loads.map(\.startedAt)).min() ?? Date()
        let duration = plans.map(\.duration).reduce(0, +) + loads.map(\.snapshot.elapsed).reduce(0, +)

        var page = "<!DOCTYPE html>\n"
        page += #"<html xmlns="http://www.w3.org/1999/xhtml" lang="en">"# + "\n"
        page += "<head>\n"
        page += #"<meta charset="utf-8" />"# + "\n"
        page += #"<meta name="viewport" content="width=device-width, initial-scale=1" />"# + "\n"
        page += #"<meta name="generator" content="\#(attribute(generator))" />"# + "\n"
        page += "<title>Stampdrill test report</title>\n"
        page += #"<link rel="stylesheet" href="\#(attribute(assets))report.css" />"# + "\n"
        page += #"<script type="module" src="\#(attribute(assets))report.js"></script>"# + "\n"
        // Until the elements are defined, only the sentence below shows; after that, only the page.
        page += """
        <style>
        stamp-report:not(:defined) > :not(.stamp-note) { display: none; }
        stamp-report:defined > .stamp-note { display: none; }
        .stamp-note { max-width: 42rem; margin: 3rem auto; padding: 0 1.5rem; color: #5d6270;
          font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
        </style>
        </head>
        <body>

        """
        page += #"<stamp-report version="\#(reportVersion)" generator="\#(attribute(generator))" started-at="\#(stamp(started))" ms="\#(wholeMilliseconds(duration))" passed="\#(flag(failed == 0))" plans="\#(plans.count)" loads="\#(loads.count)" failed="\#(failed)" iterations="\#(iterations)" requests="\#(requests)" checks="\#(checksPassed + checksFailed)" checks-failed="\#(checksFailed)">"# + "\n"
        page += #"<p class="stamp-note">\#(escape(note(plans: plans.count, loads: loads.count, requests: requests, checks: checksPassed + checksFailed, checksFailed: checksFailed, failed: failed, duration: duration, assets: assets)))</p>"# + "\n"
        page += plans.map(planHTML).joined()
        page += loads.map(loadHTML).joined()
        page += "</stamp-report>\n"
        page += "</body>\n</html>\n"
        return page
    }

    /// What the file says when nothing loads: the same numbers, in a sentence.
    private static func note(
        plans: Int, loads: Int, requests: Int, checks: Int, checksFailed: Int,
        failed: Int, duration: TimeInterval, assets: String
    ) -> String {
        var pieces: [String] = []
        if plans > 0 { pieces.append("\(plans) plan\(plans == 1 ? "" : "s")") }
        if loads > 0 { pieces.append("\(loads) load test\(loads == 1 ? "" : "s")") }
        pieces.append("\(requests) request\(requests == 1 ? "" : "s")")
        pieces.append("\(checks) check\(checks == 1 ? "" : "s")")
        if checksFailed > 0 {
            pieces.append("\(checksFailed) failed")
        } else if failed > 0 {
            pieces.append("\(failed) of \(plans + loads) failed")
        } else {
            pieces.append("none failed")
        }
        pieces.append(milliseconds(duration))
        return "Stampdrill test report: \(pieces.joined(separator: ", ")). This page draws itself with "
            + "elements from \(assets); without them, every number is still in the markup of this file."
    }

    private static func planHTML(_ report: PlanReport) -> String {
        let counts = report.expectationCounts
        var html = #"  <stamp-plan name="\#(attribute(report.plan.name))" file="\#(attribute(report.plan.path))" passed="\#(flag(report.passed))" started-at="\#(stamp(report.startedAt))" ms="\#(wholeMilliseconds(report.duration))" iterations="\#(report.iterations.count)" requests="\#(report.runs.count)" checks="\#(counts.passed + counts.failed)" checks-failed="\#(counts.failed)">"# + "\n"
        for iteration in report.iterations {
            html += #"    <stamp-iteration index="\#(iteration.index)" label="\#(attribute(iteration.label))" passed="\#(flag(iteration.passed))" started-at="\#(stamp(iteration.startedAt))" ms="\#(wholeMilliseconds(iteration.duration))">"# + "\n"
            for (name, value) in iteration.selection.sorted(by: { $0.key < $1.key }) {
                html += #"      <stamp-dimension name="\#(attribute(name))" value="\#(attribute(value))"></stamp-dimension>"# + "\n"
            }
            html += iteration.events.map { eventHTML($0, since: iteration.startedAt, indent: "      ") }.joined()
            html += "    </stamp-iteration>\n"
        }
        if !report.timings.isEmpty {
            html += "    <stamp-timings>\n"
            for timing in report.timings {
                html += #"      <stamp-timing name="\#(attribute(timing.name))" count="\#(timing.count)" min="\#(wholeMilliseconds(timing.min))" average="\#(wholeMilliseconds(timing.average))" p95="\#(wholeMilliseconds(timing.p95))"></stamp-timing>"# + "\n"
            }
            html += "    </stamp-timings>\n"
        }
        return html + "  </stamp-plan>\n"
    }

    /// A load test: the totals, the thresholds that decided it, the second by
    /// second series a chart is drawn from, and what went wrong.
    private static func loadHTML(_ report: LoadReport) -> String {
        let s = report.snapshot
        var html = #"  <stamp-load name="\#(attribute(report.plan.name))" file="\#(attribute(report.plan.path))" passed="\#(flag(report.passed))" started-at="\#(stamp(report.startedAt))" ms="\#(wholeMilliseconds(s.elapsed))" users="\#(s.series.map(\.users).max() ?? s.activeUsers)" iterations="\#(s.iterations)">"# + "\n"
        html += #"    <stamp-metrics requests="\#(s.requests)" failed="\#(s.failedRequests)" error-rate="\#(number(s.errorRate))" rps="\#(number(s.requestsPerSecond))" checks="\#(s.checksPassed + s.checksFailed)" checks-failed="\#(s.checksFailed)" p50="\#(number(s.p50))" p90="\#(number(s.p90))" p95="\#(number(s.p95))" p99="\#(number(s.p99))" avg="\#(number(s.average))" max="\#(number(s.maximum))"></stamp-metrics>"# + "\n"
        if !report.thresholds.isEmpty {
            html += "    <stamp-thresholds>\n"
            for result in report.thresholds {
                html += #"      <stamp-threshold metric="\#(result.threshold.metric.rawValue)" comparison="\#(attribute(result.threshold.comparison.rawValue))" value="\#(number(result.threshold.value))" measured="\#(number(result.measured))" passed="\#(flag(result.passed))" source="\#(attribute(result.threshold.source))"></stamp-threshold>"# + "\n"
            }
            html += "    </stamp-thresholds>\n"
        }
        if !s.series.isEmpty {
            html += "    <stamp-series>\n"
            for second in s.series {
                html += #"      <stamp-second at="\#(second.second)" requests="\#(second.requests)" errors="\#(second.errors)" p95="\#(number(second.p95))" users="\#(second.users)"></stamp-second>"# + "\n"
            }
            html += "    </stamp-series>\n"
        }
        if !s.perRequest.isEmpty {
            html += "    <stamp-requests>\n"
            for stats in s.perRequest {
                html += #"      <stamp-request-stats name="\#(attribute(stats.name))" count="\#(stats.count)" failures="\#(stats.failures)" average="\#(number(stats.average))" p95="\#(number(stats.p95))"></stamp-request-stats>"# + "\n"
            }
            html += "    </stamp-requests>\n"
        }
        if !report.failures.isEmpty {
            html += "    <stamp-failures>\n"
            for failure in report.failures {
                html += #"      <stamp-load-failure count="\#(failure.count)">\#(escape(failure.message))</stamp-load-failure>"# + "\n"
            }
            html += "    </stamp-failures>\n"
        }
        return html + "  </stamp-load>\n"
    }

    private static func eventHTML(_ event: PlanEvent, since: Date, indent: String) -> String {
        switch event.kind {
        case .run(let result):
            var html = #"\#(indent)<stamp-request name="\#(attribute(result.reference.name))" method="\#(attribute(result.request?.method ?? ""))""#
            if let response = result.response {
                html += #" url="\#(attribute(response.url.absoluteString))" status="\#(response.statusCode)" ms="\#(wholeMilliseconds(response.duration))""#
            }
            // Where this request sits in the iteration, so actors that fired together look like it.
            html += #" at="\#(max(0, wholeMilliseconds(result.startedAt.timeIntervalSince(since))))" passed="\#(flag(result.passed))""#
            if let error = result.error { html += #" error="\#(attribute(error))""# }
            guard !result.assertions.isEmpty else { return html + "></stamp-request>\n" }
            html += ">\n"
            for assertion in result.assertions {
                html += #"\#(indent)  <stamp-check source="\#(attribute(assertion.source))" line="\#(assertion.line)" passed="\#(flag(assertion.passed))""#
                html += assertion.message.map { #" message="\#(attribute($0))""# } ?? ""
                html += "></stamp-check>\n"
            }
            return html + "\(indent)</stamp-request>\n"
        case .expectation(let source, let passed, let message):
            var html = #"\#(indent)<stamp-expect source="\#(attribute(source))" line="\#(event.line)" passed="\#(flag(passed))""#
            html += message.map { #" message="\#(attribute($0))""# } ?? ""
            return html + "></stamp-expect>\n"
        case .step(let title, let children, let attempts):
            let inner = children.map { eventHTML($0, since: since, indent: indent + "  ") }.joined()
            switch event.concurrency {
            case .group(let actors):
                let html = #"\#(indent)<stamp-concurrently title="\#(attribute(title))" actors="\#(actors)" passed="\#(flag(event.passed))" ms="\#(wholeMilliseconds(event.duration))">"# + "\n"
                return html + inner + "\(indent)</stamp-concurrently>\n"
            case .actor(let index):
                let html = #"\#(indent)<stamp-actor index="\#(index)" passed="\#(flag(event.passed))" ms="\#(wholeMilliseconds(event.duration))">"# + "\n"
                return html + inner + "\(indent)</stamp-actor>\n"
            case nil:
                let html = #"\#(indent)<stamp-step title="\#(attribute(title))" attempts="\#(attempts)" passed="\#(flag(event.passed))" ms="\#(wholeMilliseconds(event.duration))">"# + "\n"
                return html + inner + "\(indent)</stamp-step>\n"
            }
        case .print(let text):
            return "\(indent)<stamp-print>\(escape(text))</stamp-print>\n"
        case .failure(let message):
            return #"\#(indent)<stamp-failure line="\#(event.line)">\#(escape(message))</stamp-failure>"# + "\n"
        }
    }

    /// Whole milliseconds: small enough to read, precise enough to compare runs.
    private static func wholeMilliseconds(_ interval: TimeInterval) -> Int {
        Int((interval * 1000).rounded())
    }

    /// A measurement with two decimals at most, and no trailing zeros to read past.
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    private static func flag(_ value: Bool) -> String { value ? "true" : "false" }

    private static func stamp(_ date: Date) -> String { date.formatted(.iso8601) }

    /// Attribute text, with the line breaks kept: a parser turns a raw newline
    /// inside an attribute into a space, so an assertion message would lose its shape.
    private static func attribute(_ text: String) -> String {
        escape(text)
            .replacingOccurrences(of: "\r\n", with: "&#10;")
            .replacingOccurrences(of: "\n", with: "&#10;")
            .replacingOccurrences(of: "\r", with: "&#10;")
            .replacingOccurrences(of: "\t", with: "&#9;")
    }

    // MARK: Helpers

    private static func escape(_ text: String) -> String {
        clean(text)
            .replacingOccurrences(of: "&", with: "&amp;")
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

    /// Characters XML 1.0 has no way to carry, dropped rather than written out broken.
    private static func clean(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0 == "\n" || $0 == "\r" || $0 == "\t" || ($0.value >= 0x20 && $0.value != 0xFFFE && $0.value != 0xFFFF) })
    }
}
