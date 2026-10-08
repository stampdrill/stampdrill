import Foundation
import Testing
@testable import StampdrillCore
import Stamp

/// The report a run writes: one file a browser draws from the elements it names,
/// and an XML parser reads without them.
@Suite("The HTML report a browser draws and a parser reads")
struct HTMLReportTests {
    private let transport = PlanStubTransport()
    private let tree = "/html/body/stamp-report"

    private func workspace(_ plan: String) -> Workspace {
        makeWorkspace([
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
            ### Item
            GET https://{{host}}/items/{{id ?? 1}}

            > assert status == 200
            """,
            "checkout.stamp": plan,
        ])
    }

    private func report(_ plan: String) async throws -> PlanReport {
        try await PlanRunner(workspace: workspace(plan), transport: transport)
            .run(PlanReference(path: "checkout.stamp", name: "Checkout"))
    }

    /// The guarantee the format rests on: the same bytes are a page and a tree.
    private func document(_ html: String) throws -> XMLDocument {
        try XMLDocument(xmlString: html, options: [.nodePreserveWhitespace])
    }

    @Test func itParsesAsXMLToo() async throws {
        let page = PlanReportExport.html(plans: [try await report("""
        plan Checkout {
          matrix region = *
          step "First item" { run item with id = 7 }
        }
        """)], generator: "stamp 9.9.9")

        #expect(page.hasPrefix("<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"en\">\n"))
        let parsed = try document(page)
        #expect(parsed.rootElement()?.name == "html")
        #expect(try parsed.nodes(forXPath: "/html/head/meta[@name='generator']/@content").first?.stringValue == "stamp 9.9.9")

        let root = try #require(try parsed.nodes(forXPath: tree).first as? XMLElement)
        #expect(root.attribute(forName: "version")?.stringValue == "1.0")
        #expect(root.attribute(forName: "generator")?.stringValue == "stamp 9.9.9")
        #expect(root.attribute(forName: "passed")?.stringValue == "true")
        // Durations are numbers, not "1.2 s": a report is compared by machines too.
        #expect(Int(root.attribute(forName: "ms")?.stringValue ?? "") != nil)
        // The sentence a reader gets when the elements never load.
        let note = try #require(try parsed.nodes(forXPath: "\(tree)/p").first?.stringValue)
        #expect(note.hasPrefix("Stampdrill test report: 1 plan, 2 requests, 2 checks, none failed,"))
    }

    @Test func itLoadsItsElementsFromWhereverTheyAreKept() async throws {
        let plan = try await report("""
        plan Checkout {
          run item
        }
        """)
        let page = PlanReportExport.html(plans: [plan], generator: "stamp")
        #expect(page.contains(#"<link rel="stylesheet" href="https://stampdrill.com/report/1.0/report.css" />"#))
        #expect(page.contains(#"<script type="module" src="https://stampdrill.com/report/1.0/report.js"></script>"#))

        let local = PlanReportExport.html(plans: [plan], generator: "stamp", assets: "./assets/")
        #expect(local.contains(#"<link rel="stylesheet" href="./assets/report.css" />"#))
        #expect(local.contains(#"<script type="module" src="./assets/report.js"></script>"#))
        #expect(!local.contains("stampdrill.com"), "a report kept elsewhere should not reach for the network")
    }

    @Test func itCountsWhatTheRunDid() async throws {
        let page = PlanReportExport.html(plans: [try await report("""
        plan Checkout {
          matrix region = *
          step "First item" {
            run item with id = 7
            expect body.id == 7
          }
        }
        """)], generator: "stamp")
        let root = try #require(try document(page).nodes(forXPath: tree).first as? XMLElement)

        #expect(root.attribute(forName: "plans")?.stringValue == "1")
        #expect(root.attribute(forName: "loads")?.stringValue == "0")
        #expect(root.attribute(forName: "failed")?.stringValue == "0")
        #expect(root.attribute(forName: "iterations")?.stringValue == "2")
        #expect(root.attribute(forName: "requests")?.stringValue == "2")
        #expect(root.attribute(forName: "checks")?.stringValue == "4")
        #expect(root.attribute(forName: "checks-failed")?.stringValue == "0")
    }

    @Test func itKeepsTheShapeOfThePlan() async throws {
        let page = PlanReportExport.html(plans: [try await report("""
        plan Checkout {
          matrix region = *
          step "First item" {
            run item with id = 7
            expect body.id == 7
          }
          print "done"
          run nothing
        }
        """)], generator: "stamp")
        let parsed = try document(page)

        #expect(try parsed.nodes(forXPath: "\(tree)/stamp-plan").count == 1)
        #expect(try parsed.nodes(forXPath: "\(tree)/stamp-plan/stamp-iteration").count == 2)
        #expect(try parsed.nodes(forXPath: "\(tree)/stamp-plan/stamp-iteration/stamp-step/stamp-request/stamp-check").count == 2)
        #expect(try parsed.nodes(forXPath: "\(tree)/stamp-plan/stamp-iteration/stamp-step/stamp-expect").count == 2)
        #expect(try parsed.nodes(forXPath: "\(tree)/stamp-plan/stamp-iteration/stamp-print").first?.stringValue == "done")
        #expect(try parsed.nodes(forXPath: "\(tree)/stamp-plan/stamp-iteration/stamp-failure").first?.stringValue == "no request named 'nothing'")
        #expect(try parsed.nodes(forXPath: "\(tree)/stamp-plan/stamp-timings/stamp-timing/@name").first?.stringValue == "item")
        #expect(try parsed.nodes(forXPath: "\(tree)/@passed").first?.stringValue == "false")

        let selection = try parsed.nodes(forXPath: "\(tree)/stamp-plan/stamp-iteration[1]/stamp-dimension/@value").compactMap(\.stringValue)
        #expect(selection == ["eu"])
    }

    @Test func itShowsTheActorsOfAConcurrentBlock() async throws {
        let workspace = makeWorkspace([
            "shop.stamp": """
            plan Race {
              concurrently 3 {
                sync "go"
                run withdraw
              }
            }

            ### Withdraw
            @name withdraw
            POST https://bank.example/withdraw
            """,
        ])
        let report = try await PlanRunner(workspace: workspace, transport: RacyBank(delay: .milliseconds(5)))
            .run(PlanReference(path: "shop.stamp", name: "Race"))
        let parsed = try document(PlanReportExport.html(plans: [report], generator: "stamp"))

        let group = try #require(try parsed.nodes(forXPath: "\(tree)/stamp-plan/stamp-iteration/stamp-concurrently").first as? XMLElement)
        #expect(group.attribute(forName: "actors")?.stringValue == "3")
        #expect(try parsed.nodes(forXPath: "\(tree)/stamp-plan/stamp-iteration/stamp-concurrently/stamp-actor").count == 3)
        #expect(try parsed.nodes(forXPath: "\(tree)/stamp-plan/stamp-iteration/stamp-concurrently/stamp-actor/@index").compactMap(\.stringValue) == ["0", "1", "2"])
        // Every request says when it started, which is what makes a lane chart possible.
        let offsets = try parsed.nodes(forXPath: "\(tree)/stamp-plan/stamp-iteration/stamp-concurrently/stamp-actor/stamp-request/@at").compactMap(\.stringValue)
        #expect(offsets.count == 3)
        #expect(offsets.allSatisfy { Int($0) != nil })
    }

    @Test func itCarriesALoadTestWithItsSeriesAndThresholds() async throws {
        let parsed = try document(PlanReportExport.html(loads: [try await loadReport()], generator: "stamp"))

        #expect(try parsed.nodes(forXPath: "\(tree)/@loads").first?.stringValue == "1")
        #expect(try parsed.nodes(forXPath: "\(tree)/stamp-load/@name").first?.stringValue == "Orders")
        #expect(try parsed.nodes(forXPath: "\(tree)/stamp-load/stamp-metrics/@requests").first?.stringValue == "6")
        #expect(try parsed.nodes(forXPath: "\(tree)/stamp-load/stamp-metrics/@error-rate").first?.stringValue == "0")
        #expect(try parsed.nodes(forXPath: "\(tree)/stamp-load/stamp-thresholds/stamp-threshold").count == 2)
        #expect(try parsed.nodes(forXPath: "\(tree)/stamp-load/stamp-thresholds/stamp-threshold[@metric='errors']/@passed").first?.stringValue == "true")
        #expect(try parsed.nodes(forXPath: "\(tree)/stamp-load/stamp-requests/stamp-request-stats/@name").first?.stringValue == "createOrder")
        // A chart needs a point for every second, each one a number.
        let series = try parsed.nodes(forXPath: "\(tree)/stamp-load/stamp-series/stamp-second/@requests").compactMap(\.stringValue)
        #expect(!series.isEmpty)
        #expect(series.allSatisfy { Int($0) != nil })
    }

    @Test func itSurvivesTextThatWouldBreakTheMarkup() async throws {
        let report = PlanReport(
            plan: PlanReference(path: "a<b.stamp", name: "Tags & \"quotes\""),
            startedAt: Date(),
            iterations: [PlanIteration(index: 0, label: "run", selection: [:], row: [:], events: [
                PlanEvent(kind: .expectation(source: "body.name == \"<ok>\"", passed: false, message: "expected\nover two lines"), line: 3),
            ])]
        )
        let page = PlanReportExport.html(plans: [report], generator: "stamp")
        let parsed = try document(page)

        #expect(try parsed.nodes(forXPath: "\(tree)/stamp-plan/@name").first?.stringValue == "Tags & \"quotes\"")
        #expect(try parsed.nodes(forXPath: "\(tree)/stamp-plan/stamp-iteration/stamp-expect/@source").first?.stringValue == "body.name == \"<ok>\"")
        // A raw newline in an attribute becomes a space when parsed; the entity keeps the shape.
        #expect(page.contains("expected&#10;over two lines"))
        #expect(try parsed.nodes(forXPath: "\(tree)/stamp-plan/stamp-iteration/stamp-expect/@message").first?.stringValue == "expected\nover two lines")
    }

    /// A custom element that closes itself swallows everything after it in HTML,
    /// however well the same file parses as XML.
    @Test func itNeverSelfClosesACustomElement() async throws {
        let page = PlanReportExport.html(
            plans: [try await report("""
            plan Checkout {
              step "First item" {
                run item with id = 7
                expect body.id == 7
              }
              print "done"
              run nothing
            }
            """)],
            loads: [try await loadReport()],
            generator: "stamp"
        )
        let tags = page.components(separatedBy: "<stamp-").dropFirst()
        #expect(!tags.isEmpty)
        let closed = tags.filter { tag in
            guard let end = tag.firstIndex(of: ">") else { return true }
            return tag[tag.index(before: end)] == "/"
        }
        #expect(closed.isEmpty, "a custom element was self-closed")
    }

    private func loadReport() async throws -> LoadReport {
        let workspace = makeWorkspace(["shop.stamp": """
        load Orders {
          users 2
          iterations 6
          threshold errors < 1%
          threshold requests >= 6
          scenario {
            run createOrder with orderId = uuid("order")
          }
        }

        ### Create order
        POST https://shop.example/orders?{{orderId}}
        """])
        return try await LoadRunner(workspace: workspace, transport: RacyBank(delay: .zero))
            .run(PlanReference(path: "shop.stamp", name: "Orders"))
    }
}
