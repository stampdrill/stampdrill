import Foundation
import Testing
@testable import StampdrillCore
@testable import Stamp

/// A bank with a check-then-act race: it reads the balance, waits, then writes.
final class RacyBank: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var balance = 100
    private(set) var created: [String] = []
    let delay: Duration

    init(delay: Duration = .milliseconds(20)) {
        self.delay = delay
    }

    func send(_ request: ResolvedRequest) async throws -> HTTPResponse {
        func respond(_ status: Int, _ body: String) -> HTTPResponse {
            HTTPResponse(url: request.url, statusCode: status, headers: [HTTPField("Content-Type", "application/json")], body: Data(body.utf8), duration: 0.005)
        }
        switch request.url.path {
        case "/withdraw":
            let seen = lock.withLock { balance }
            try await Task.sleep(for: delay)
            guard seen >= 100 else { return respond(409, #"{"error":"insufficient funds"}"#) }
            lock.withLock { balance = seen - 100 }
            return respond(200, #"{"balance":\#(seen - 100)}"#)
        case "/orders":
            let id = request.url.query ?? ""
            lock.withLock { created.append(id) }
            return respond(201, #"{"id":"\#(id)"}"#)
        default:
            return respond(200, #"{"ok":true}"#)
        }
    }
}

struct ConcurrencyTests {
    private let workspace = makeWorkspace([
        "bank.stamp": """
        plan DoubleSpend {
          concurrently 5 {
            sync "ready"
            run withdraw
            share lastActor = actor
          }
          expect count(results, r => r.status == 200) == 1, "only one withdrawal may succeed"
          expect shared.lastActor != null
        }

        ### Withdraw
        POST https://bank.example/withdraw

        { "amount": 100 }
        """,
    ])

    @Test func findsTheRaceCondition() async throws {
        let report = try await PlanRunner(workspace: workspace, transport: RacyBank()).run(PlanReference(path: "bank.stamp", name: "DoubleSpend"))
        let expectations = report.iterations[0].events.flatMap(\.expectations).filter { $0.source.hasPrefix("count") }
        #expect(expectations.first?.passed == false)
        #expect(expectations.first?.message == "only one withdrawal may succeed")
        guard case .step(let title, let actors, _) = report.iterations[0].events[0].kind else {
            Issue.record("expected the concurrent block")
            return
        }
        #expect(title == "5 at once")
        #expect(actors.count == 5)
    }

    @Test func parsesConcurrencyStatements() {
        let document = Document.parse("""
        plan Race {
          concurrently 3 { run a }
          share x = 1
          sync "go"
        }
        """)
        #expect(document.diagnostics.isEmpty)
        #expect(document.plans[0].body.map(\.source) == ["concurrently 3 {", "share x = 1", "sync \"go\""])
    }
}

struct LoadTests {
    @Test func parsesLoadSettings() throws {
        let document = Document.parse("""
        load Checkout {
          users 20
          ramp 10s
          duration 1m
          think 100ms..400ms
          seed checkout
          threshold p95 < 800ms
          threshold errors < 1%
          threshold rps >= 50
          setup { run logIn }
          scenario {
            run listPosts
          }
        }
        """)
        #expect(document.diagnostics.isEmpty)
        let plan = try #require(document.plans.first)
        let load = try #require(plan.load)
        #expect(load.users == 20)
        #expect(load.ramp == 10)
        #expect(load.duration == 60)
        #expect(load.thinkTime == 0.1...0.4)
        #expect(load.seed == "checkout")
        #expect(load.thresholds.map(\.metric) == [.p95, .errors, .rps])
        #expect(load.thresholds.map(\.value) == [800, 0.01, 50])
        #expect(plan.body.map(\.source) == ["run listPosts"])
        #expect(plan.setup.map(\.source) == ["run logIn"])
    }

    @Test func runsVirtualUsersWithSeededIDs() async throws {
        let workspace = makeWorkspace(["shop.stamp": """
        load Orders {
          users 4
          iterations 20
          seed shop
          threshold errors < 1%
          threshold requests >= 40
          scenario {
            run createOrder with orderId = uuid("order")
            expect body.id == uuid("order")
            run fetchOrder with orderId = uuid("order")
          }
        }

        ### Create order
        POST https://shop.example/orders?{{orderId}}

        ### Fetch order
        GET https://shop.example/orders?{{orderId}}
        """])
        let bank = RacyBank(delay: .zero)
        let report = try await LoadRunner(workspace: workspace, transport: bank).run(PlanReference(path: "shop.stamp", name: "Orders"))

        #expect(report.snapshot.requests == 40)
        #expect(report.snapshot.iterations == 20)
        #expect(report.snapshot.checksFailed == 0)
        #expect(report.snapshot.failedRequests == 0)
        // Twenty iterations, each creating and fetching its own order: 20 distinct ids, each used twice.
        #expect(Set(bank.created).count == 20)
        #expect(bank.created.count == 40)
        #expect(report.thresholds.first?.passed == true)
        #expect(report.snapshot.perRequest.map(\.name) == ["createOrder", "fetchOrder"])

        // The same seed gives the same ids next time.
        let again = RacyBank(delay: .zero)
        _ = try await LoadRunner(workspace: workspace, transport: again).run(PlanReference(path: "shop.stamp", name: "Orders"))
        #expect(Set(again.created) == Set(bank.created))
    }
}
