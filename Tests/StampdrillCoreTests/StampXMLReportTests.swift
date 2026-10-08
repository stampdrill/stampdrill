import Foundation
import Testing
@testable import StampdrillCore
import Stamp

/// The report both a build server and a person read: valid XML, and a page once
/// the browser has applied the stylesheet named in the processing instruction.
@Suite("The stamp-xml report")
struct StampXMLReportTests {
    private let transport = PlanStubTransport()

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

    private func document(_ xml: String) throws -> XMLDocument {
        try XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace])
    }

    @Test func itNamesTheStylesheetAndParses() async throws {
        let xml = PlanReportExport.stampXML(plans: [try await report("""
        plan Checkout {
          matrix region = *
          step "First item" { run item with id = 7 }
        }
        """)], generator: "stamp 9.9.9")

        #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<?xml-stylesheet type=\"text/xsl\" href=\"https://stampdrill.com/report/0.1/style.xsl\"?>\n"))

        let root = try document(xml).rootElement()
        #expect(root?.name == "report")
        #expect(root?.attribute(forName: "version")?.stringValue == "0.1")
        #expect(root?.attribute(forName: "generator")?.stringValue == "stamp 9.9.9")
        #expect(root?.attribute(forName: "passed")?.stringValue == "true")
        // Durations are numbers, not "1.2 s": a report is compared by machines too.
        #expect(Int(root?.attribute(forName: "ms")?.stringValue ?? "") != nil)
    }

    @Test func itKeepsTheShapeOfThePlan() async throws {
        let xml = PlanReportExport.stampXML(plans: [try await report("""
        plan Checkout {
          matrix region = *
          step "First item" {
            run item with id = 7
            expect body.id == 7
          }
          print "done"
        }
        """)], generator: "stamp")
        let parsed = try document(xml)

        #expect(try parsed.nodes(forXPath: "/report/plan").count == 1)
        #expect(try parsed.nodes(forXPath: "/report/plan/iteration").count == 2)
        #expect(try parsed.nodes(forXPath: "/report/plan/iteration/step/request/check").count == 2)
        #expect(try parsed.nodes(forXPath: "/report/plan/iteration/step/expect").count == 2)
        #expect(try parsed.nodes(forXPath: "/report/plan/iteration/print").first?.stringValue == "done")
        #expect(try parsed.nodes(forXPath: "/report/plan/timings/timing/@name").first?.stringValue == "item")

        let selection = try parsed.nodes(forXPath: "/report/plan/iteration[1]/dimension/@value").compactMap(\.stringValue)
        #expect(selection == ["eu"])
        let summary = try #require(try parsed.nodes(forXPath: "/report/summary").first as? XMLElement)
        #expect(summary.attribute(forName: "iterations")?.stringValue == "2")
        #expect(summary.attribute(forName: "requests")?.stringValue == "2")
        #expect(summary.attribute(forName: "checksFailed")?.stringValue == "0")
    }

    @Test func itCarriesWhatFailedAndWhy() async throws {
        let xml = PlanReportExport.stampXML(plans: [try await report("""
        plan Checkout {
          run item with id = 5
          expect body.id == 6, "the wrong item came back"
          run nothing
        }
        """)], generator: "stamp")
        let parsed = try document(xml)

        #expect(try parsed.nodes(forXPath: "/report/@passed").first?.stringValue == "false")
        #expect(try parsed.nodes(forXPath: "/report/summary/@checksFailed").first?.stringValue == "1")
        #expect(try parsed.nodes(forXPath: "/report/plan/iteration/expect[@passed='false']/@message").first?.stringValue == "the wrong item came back")
        #expect(try parsed.nodes(forXPath: "/report/plan/iteration/failure").first?.stringValue == "no request named 'nothing'")
    }

    @Test func itSurvivesTextThatWouldBreakXML() async throws {
        let report = PlanReport(
            plan: PlanReference(path: "a<b.stamp", name: "Tags & \"quotes\""),
            startedAt: Date(),
            iterations: [PlanIteration(index: 0, label: "run", selection: [:], row: [:], events: [
                PlanEvent(kind: .expectation(source: "body.name == \"<ok>\"", passed: false, message: "expected\nover two lines"), line: 3),
            ])]
        )
        let xml = PlanReportExport.stampXML(plans: [report], generator: "stamp")
        let parsed = try document(xml)

        #expect(try parsed.nodes(forXPath: "/report/plan/@name").first?.stringValue == "Tags & \"quotes\"")
        #expect(try parsed.nodes(forXPath: "/report/plan/iteration/expect/@source").first?.stringValue == "body.name == \"<ok>\"")
        // A raw newline in an attribute becomes a space when parsed; the entity keeps the shape.
        #expect(try parsed.nodes(forXPath: "/report/plan/iteration/expect/@message").first?.stringValue == "expected\nover two lines")
    }

    @Test func itPointsWhereverTheStylesheetIsKept() async throws {
        let xml = PlanReportExport.stampXML(plans: [try await report("""
        plan Checkout {
          run item
        }
        """)], generator: "stamp", stylesheet: "./style.xsl")
        #expect(xml.contains(#"<?xml-stylesheet type="text/xsl" href="./style.xsl"?>"#))
    }

    @Test func itCarriesALoadTestWithItsSeriesAndThresholds() async throws {
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
        let report = try await LoadRunner(workspace: workspace, transport: RacyBank(delay: .zero))
            .run(PlanReference(path: "shop.stamp", name: "Orders"))
        let parsed = try document(PlanReportExport.stampXML(loads: [report], generator: "stamp"))

        #expect(try parsed.nodes(forXPath: "/report/summary/@loads").first?.stringValue == "1")
        #expect(try parsed.nodes(forXPath: "/report/load/@name").first?.stringValue == "Orders")
        #expect(try parsed.nodes(forXPath: "/report/load/metrics/@requests").first?.stringValue == "6")
        #expect(try parsed.nodes(forXPath: "/report/load/thresholds/threshold").count == 2)
        #expect(try parsed.nodes(forXPath: "/report/load/thresholds/threshold[@metric='errors']/@passed").first?.stringValue == "true")
        #expect(try parsed.nodes(forXPath: "/report/load/requests/request/@name").first?.stringValue == "createOrder")
        // A chart needs a point for every second, each one a number.
        let series = try parsed.nodes(forXPath: "/report/load/series/second/@requests").compactMap(\.stringValue)
        #expect(!series.isEmpty)
        #expect(series.allSatisfy { Int($0) != nil })
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
        let parsed = try document(PlanReportExport.stampXML(plans: [report], generator: "stamp"))

        let group = try #require(try parsed.nodes(forXPath: "/report/plan/iteration/concurrently").first as? XMLElement)
        #expect(group.attribute(forName: "actors")?.stringValue == "3")
        #expect(try parsed.nodes(forXPath: "/report/plan/iteration/concurrently/actor").count == 3)
        #expect(try parsed.nodes(forXPath: "/report/plan/iteration/concurrently/actor/@index").compactMap(\.stringValue) == ["0", "1", "2"])
        // Every request says when it started, which is what makes a lane chart possible.
        let offsets = try parsed.nodes(forXPath: "/report/plan/iteration/concurrently/actor/request/@at").compactMap(\.stringValue)
        #expect(offsets.count == 3)
        #expect(offsets.allSatisfy { Int($0) != nil })
    }

    #if canImport(Darwin)
    /// The stylesheet this repository publishes, applied to a real report.
    @Test func theStylesheetTurnsItIntoAPage() async throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url = url.deletingLastPathComponent() }
        // The published stylesheet is one file with the CSS inside it, put there by
        // website/build.py; the repository keeps the two parts apart.
        let folder = url.appendingPathComponent("Public/report/\(PlanReportExport.stampXMLVersion)")
        let template = try String(contentsOf: folder.appendingPathComponent("style.xsl.in"), encoding: .utf8)
        let css = try String(contentsOf: folder.appendingPathComponent("report.css"), encoding: .utf8)
        try #require(template.contains("/* REPORT_CSS */"), "style.xsl.in has nowhere to put the CSS")
        let stylesheet = template.replacingOccurrences(of: "/* REPORT_CSS */", with: css)

        let xml = PlanReportExport.stampXML(plans: [try await report("""
        plan Checkout {
          step "First item" {
            run item with id = 7
            expect body.id == 8, "the wrong item came back"
          }
        }
        """)], generator: "stamp 1.0")
        let page = try document(xml).object(byApplyingXSLTString: stylesheet, arguments: nil)
        let html = String(decoding: (page as? XMLDocument)?.xmlData ?? Data(), as: UTF8.self)

        #expect(html.contains("Stampdrill test report"))
        #expect(html.contains("failed"))
        #expect(html.contains("First item"))
        #expect(html.contains("the wrong item came back"))
        #expect(!html.contains("<report"), "the XML should be rendered, not printed")

        let load = try await LoadRunner(workspace: makeWorkspace(["shop.stamp": """
        load Orders {
          users 2
          iterations 4
          threshold errors < 1%
          scenario { run createOrder with orderId = uuid("order") }
        }

        ### Create order
        POST https://shop.example/orders?{{orderId}}
        """]), transport: RacyBank(delay: .zero)).run(PlanReference(path: "shop.stamp", name: "Orders"))
        let loadPage = try document(PlanReportExport.stampXML(loads: [load], generator: "stamp 1.0"))
            .object(byApplyingXSLTString: stylesheet, arguments: nil)
        let loadHTML = String(decoding: (loadPage as? XMLDocument)?.xmlData ?? Data(), as: UTF8.self)

        #expect(loadHTML.contains("<svg"), "a load test is charted, not just listed")
        #expect(loadHTML.contains("polyline"))
        #expect(loadHTML.contains("Requests a second"))
        #expect(loadHTML.contains("createOrder"))
        #expect(!loadHTML.contains("NaN"), "a chart coordinate was divided by zero")
    }
    #endif
}
