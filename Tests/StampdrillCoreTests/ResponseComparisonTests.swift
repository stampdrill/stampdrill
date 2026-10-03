import Foundation
import Testing
@testable import StampdrillCore

@Suite("Comparing two runs")
struct ResponseComparisonTests {
    private func result(
        status: Int = 200, body: String = "", headers: [(String, String)] = [("Content-Type", "application/json")],
        duration: TimeInterval = 0.1, assertions: [AssertionResult] = []
    ) -> RunResult {
        var run = RunResult(reference: RequestReference(path: "a.stamp", name: "one"), startedAt: Date(timeIntervalSince1970: 0))
        run.response = HTTPResponse(
            url: URL(string: "https://example.com")!, statusCode: status,
            headers: headers.map { HTTPField($0.0, $0.1) }, body: Data(body.utf8), duration: duration
        )
        run.assertions = assertions
        return run
    }

    @Test func identicalRunsCompareAsUnchanged() {
        let body = #"{"id":1,"name":"Emily"}"#
        let comparison = ResponseComparison.compare(result(body: body), with: result(body: body))
        #expect(comparison.isUnchanged)
        #expect(!comparison.bodyChanged)
        #expect(comparison.headers.isEmpty)
    }

    @Test func formattingDifferencesAreNotChanges() {
        let older = result(body: #"{"id":1,"name":"Emily"}"#)
        let newer = result(body: "{\n  \"id\" : 1,\n     \"name\" :    \"Emily\"\n}")
        #expect(!ResponseComparison.compare(older, with: newer).bodyChanged)
    }

    @Test func aChangedValueShowsBothLines() {
        let comparison = ResponseComparison.compare(
            result(body: #"{"id":1,"total":10}"#), with: result(body: #"{"id":1,"total":99}"#)
        )
        #expect(comparison.bodyChanged)
        let removed = comparison.body.filter { $0.kind == .removed }.map(\.text).joined()
        let added = comparison.body.filter { $0.kind == .added }.map(\.text).joined()
        #expect(removed.contains("10"))
        #expect(added.contains("99"))
        #expect(comparison.body.contains { $0.kind == .same && $0.text.contains("\"id\"") })
    }

    @Test func statusAndSizeAreCarried() {
        let comparison = ResponseComparison.compare(
            result(status: 200, body: "ok"), with: result(status: 500, body: "no")
        )
        #expect(comparison.statusChanged)
        #expect(comparison.statusBefore == 200)
        #expect(comparison.statusAfter == 500)
        #expect(comparison.sizeBefore == 2)
    }

    @Test func headersThatChangeEveryTimeAreIgnored() {
        let older = result(headers: [("Content-Type", "application/json"), ("Date", "Mon, 1 Jan 2026 00:00:00 GMT"), ("ETag", "a")])
        let newer = result(headers: [("Content-Type", "application/json"), ("Date", "Tue, 2 Jan 2026 00:00:00 GMT"), ("ETag", "b")])
        #expect(ResponseComparison.compare(older, with: newer).headers.isEmpty)
    }

    @Test func aRealHeaderChangeIsReported() {
        let older = result(headers: [("Content-Type", "application/json"), ("X-Rate-Limit", "100")])
        let newer = result(headers: [("Content-Type", "text/plain")])
        let changes = ResponseComparison.compare(older, with: newer).headers
        #expect(changes.count == 2)
        #expect(changes.contains { $0.name == "content-type" && $0.kind == .changed })
        #expect(changes.contains { $0.name == "x-rate-limit" && $0.kind == .removed })
    }

    @Test func anAssertionThatStartedFailingStandsOut() {
        let passing = AssertionResult(source: "status == 200", line: 3, passed: true, message: nil)
        let failing = AssertionResult(source: "status == 200", line: 3, passed: false, message: "got 500")
        let changes = ResponseComparison.compare(
            result(assertions: [passing]), with: result(assertions: [failing])
        ).assertions
        #expect(changes.count == 1)
        #expect(changes[0].before == "passed")
        #expect(changes[0].after == "failed")
    }

    @Test func hunksKeepContextAroundChanges() {
        let older = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let newer = older.replacingOccurrences(of: "line 20", with: "line twenty")
        let comparison = ResponseComparison.compare(
            result(headers: [("Content-Type", "text/plain")], duration: 0.1).with(body: older),
            with: result(headers: [("Content-Type", "text/plain")], duration: 0.1).with(body: newer)
        )
        let hunks = comparison.bodyHunks(context: 2)
        #expect(hunks.count < comparison.body.count)
        #expect(hunks.contains { $0.text == "line twenty" && $0.kind == .added })
        #expect(hunks.contains { $0.text == "line 18" && $0.kind == .same })
        #expect(!hunks.contains { $0.text == "line 5" })
    }

    @Test func binaryBodiesSayWhyTheyAreNotShown() {
        var older = result(headers: [("Content-Type", "image/png")])
        var newer = older
        older.response?.body = Data([0x89, 0x50, 0x4E, 0x47, 1])
        newer.response?.body = Data([0x89, 0x50, 0x4E, 0x47, 2])
        let comparison = ResponseComparison.compare(older, with: newer)
        #expect(comparison.body.isEmpty)
        #expect(comparison.bodyNote?.contains("image") == true)
    }
}

private extension RunResult {
    func with(body: String) -> RunResult {
        var copy = self
        copy.response?.body = Data(body.utf8)
        return copy
    }
}

@Suite("Noisy headers")
struct VolatileHeaderTests {
    @Test func rateLimitCountersAndTracesAreIgnored() {
        let noisy = ["x-ratelimit-reset", "x-ratelimit-remaining", "server-timing", "x-amzn-trace-id", "x-vercel-id"]
        for name in noisy {
            #expect(ResponseComparison.volatileHeaders.contains(name), "\(name) should be treated as noise")
        }
    }

    @Test func meaningfulHeadersAreStillCompared() {
        for name in ["content-type", "location", "retry-after", "www-authenticate", "cache-control"] {
            #expect(!ResponseComparison.volatileHeaders.contains(name), "\(name) should still be compared")
        }
    }
}
