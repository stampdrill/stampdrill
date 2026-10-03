import Foundation
import Testing
@testable import StampdrillCore
@testable import Stamp

struct PlanParserTests {
    @Test func parsesNestedPlans() throws {
        let document = Document.parse("""
        plan Checkout {
          matrix user = emily|michael, page = *
          data ./users.csv
          parallel 3
          retry 2 every 250ms
          timeout 1m
          tags smoke, auth

          setup { run logIn }

          step "Browse" {
            run listPosts with limit = 2, sort = "desc"
            expect status == 200, "listing failed"
            set first = body[0].id
          }

          for each id in [1, 2] {
            run getAPost with postId = id
          }

          if user == "emily" {
            print "admin"
          } else {
            wait 100ms
          }

          repeat 2 { run createAPost }

          teardown {
            run deleteAPost
          }
        }

        ### List posts
        GET https://example.com/posts
        """)

        #expect(document.diagnostics.isEmpty)
        #expect(document.requests.count == 1)
        let plan = try #require(document.plans.first)
        #expect(plan.name == "Checkout")
        #expect(plan.matrix == [.init(dimension: "user", values: ["emily", "michael"]), .init(dimension: "page", values: [])])
        #expect(plan.parallel == 3)
        #expect(plan.retries == 2)
        #expect(plan.retryDelay == 0.25)
        #expect(plan.timeout == 60)
        #expect(plan.tags == ["smoke", "auth"])
        #expect(plan.setup.map(\.source) == ["run logIn"])
        #expect(plan.teardown.map(\.source) == ["run deleteAPost"])
        #expect(plan.body.count == 4)
        #expect(plan.lines == 1...32)

        guard case .step(let title, let steps) = plan.body[0].kind, case .run(let name, let bindings) = steps[0].kind else {
            Issue.record("expected a step with a run")
            return
        }
        #expect(title == "Browse")
        #expect(name == "listPosts")
        #expect(bindings.map(\.name) == ["limit", "sort"])
        guard case .ifBlock(_, let then, let otherwise) = plan.body[2].kind else {
            Issue.record("expected an if block")
            return
        }
        #expect(then.count == 1)
        #expect(otherwise.first?.kind == .wait(0.1))
    }

    @Test func reportsPlanErrors() {
        let document = Document.parse("""
        plan Broken {
          matrix nonsense
          run
          step untitled {
          }
          explode
        }
        """)
        #expect(document.diagnostics.map(\.message) == [
            "expected 'matrix environment = qa|prod, region = *'",
            "expected run, expect, set, let, print, wait, share, sync, step, repeat, for each, concurrently or if",
            "expected 'step \"title\" {'",
            "expected run, expect, set, let, print, wait, share, sync, step, repeat, for each, concurrently or if",
        ])
    }

    @Test func requiresPlansBeforeRequests() {
        let document = Document.parse("""
        GET https://example.com

        > print 1
        plan Late {
        }
        """)
        #expect(!document.diagnostics.isEmpty)
    }
}

struct PlanRunnerTests {
    private let transport = PlanStubTransport()

    private func workspace(_ plan: String, data: [String: String] = [:]) -> Workspace {
        var files = [
            "environment.stamp": """
            dimension region = eu, us
            vars region=us {
              host = "us.example.com"
            }
            vars {
              host = "eu.example.com"
            }
            """,
            "api.stamp": """
            ### Log in
            POST https://{{host}}/login

            > set token = body.token

            ### Item
            GET https://{{host}}/items/{{id ?? 1}}
            Authorization: Bearer {{token ?? "none"}}

            > assert status == 200
            """,
            "checkout.stamp": plan,
        ]
        files.merge(data) { _, new in new }
        return makeWorkspace(files)
    }

    @Test func runsStepsAcrossTheMatrix() async throws {
        let workspace = workspace("""
        plan Items {
          matrix region = *
          parallel 2

          setup { run logIn }

          step "First item" {
            run item with id = 7
            expect status == 200
            expect body.id == 7
            set seen = body.region
          }

          for each id in [1, 2] {
            run item with id = id
            expect body.id == id
          }

          if region == "us" {
            print "in the US: " + seen
          }
        }
        """)
        let runner = PlanRunner(workspace: workspace, transport: transport)
        let report = try await runner.run(PlanReference(path: "checkout.stamp", name: "Items"))

        #expect(report.iterations.map(\.label) == ["region=eu", "region=us"])
        #expect(report.passed)
        #expect(report.runs.count == 8)
        #expect(report.expectationCounts == (passed: 14, failed: 0))
        let prints = report.iterations[1].events.compactMap { event -> String? in
            if case .print(let text) = event.kind { return text }
            return nil
        }
        #expect(prints == ["in the US: us"])
        #expect(report.timings.map(\.name) == ["item", "logIn"])
    }

    @Test func runsOnceForEveryDataRow() async throws {
        let workspace = workspace("""
        plan Rows {
          data ./items.csv
          step "Item" {
            run item
            expect body.id == id, "wrong item for " + label
          }
        }
        """, data: ["items.csv": "id,label\n1,first\n\"2\",\"second, with comma\"\n"])
        // makeWorkspace keeps files in memory, so point the data at a real file.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "id,label\n1,first\n\"2\",\"second, with comma\"\n".write(to: directory.appendingPathComponent("items.csv"), atomically: true, encoding: .utf8)
        var files = workspace.files
        for index in files.indices {
            files[index] = WorkspaceFile(url: directory.appendingPathComponent(files[index].relativePath), root: directory, text: files[index].text)
        }
        let real = Workspace(root: directory, files: files)

        let report = try await PlanRunner(workspace: real, transport: transport).run(PlanReference(path: "checkout.stamp", name: "Rows"))
        #expect(report.iterations.map(\.label) == ["row 1", "row 2"])
        #expect(report.iterations.map(\.row["label"]) == ["first", "second, with comma"])
        #expect(report.passed)
    }

    @Test func retriesFailingSteps() async throws {
        let flaky = PlanStubTransport(failuresBeforeSuccess: 2)
        let workspace = workspace("""
        plan Flaky {
          retry 2
          step "Eventually" {
            run item
            expect status == 200
          }
        }
        """)
        let report = try await PlanRunner(workspace: workspace, transport: flaky).run(PlanReference(path: "checkout.stamp", name: "Flaky"))
        guard case .step(_, _, let attempts) = report.iterations[0].events[0].kind else {
            Issue.record("expected a step")
            return
        }
        #expect(attempts == 3)
        #expect(report.passed)
    }

    @Test func reportsFailuresWithDetail() async throws {
        let workspace = workspace("""
        plan Failing {
          run item with id = 5
          expect body.id == 6
          run nothing
        }
        """)
        let report = try await PlanRunner(workspace: workspace, transport: transport).run(PlanReference(path: "checkout.stamp", name: "Failing"))
        #expect(!report.passed)
        #expect(report.iterations[0].events.flatMap(\.expectations).last?.message == "body.id is 5")
        guard case .failure(let message) = report.iterations[0].events.last?.kind else {
            Issue.record("expected a failure")
            return
        }
        #expect(message == "no request named 'nothing'")
    }

    @Test func parsesCSV() {
        #expect(CSV.parse("a,b\n1,\"x, \"\"y\"\"\"\n") == [["a", "b"], ["1", "x, \"y\""]])
    }
}

/// Answers /login with a token and /items/<id> with that id, echoing the host's region.
final class PlanStubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: Int

    init(failuresBeforeSuccess: Int = 0) {
        failures = failuresBeforeSuccess
    }

    func send(_ request: ResolvedRequest) async throws -> HTTPResponse {
        let region = request.url.host?.hasPrefix("us") == true ? "us" : "eu"
        let status: Int = lock.withLock {
            if failures > 0 { failures -= 1; return 503 }
            return 200
        }
        let body: String
        if request.url.path == "/login" {
            body = #"{"token":"t-\#(region)"}"#
        } else {
            let id = request.url.lastPathComponent
            body = #"{"id":\#(id),"region":"\#(region)"}"#
        }
        return HTTPResponse(url: request.url, statusCode: status, headers: [HTTPField("Content-Type", "application/json")], body: Data(body.utf8), duration: 0.01)
    }
}
