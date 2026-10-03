import Foundation
import Testing
@testable import StampdrillCore

struct ContentKindTests {
    @Test func detectsFromMediaType() {
        let body = Data("x".utf8)
        #expect(ContentKind.detect(contentType: "application/json; charset=utf-8", body: body) == .json)
        #expect(ContentKind.detect(contentType: "application/problem+json", body: body) == .json)
        #expect(ContentKind.detect(contentType: "image/svg+xml", body: body) == .svg)
        #expect(ContentKind.detect(contentType: "application/atom+xml", body: body) == .xml)
        #expect(ContentKind.detect(contentType: "text/html", body: body) == .html)
        #expect(ContentKind.detect(contentType: "image/webp", body: body) == .image)
        #expect(ContentKind.detect(contentType: "text/csv", body: body) == .csv)
        #expect(ContentKind.detect(contentType: "text/plain", body: Data()) == .empty)
    }

    @Test func sniffsWhenTheTypeIsMissing() {
        #expect(ContentKind.detect(contentType: nil, body: Data(#"{"a":1}"#.utf8)) == .json)
        #expect(ContentKind.detect(contentType: "application/octet-stream", body: Data([0x89, 0x50, 0x4E, 0x47, 0x0D])) == .image)
        #expect(ContentKind.detect(contentType: nil, body: Data("%PDF-1.7".utf8)) == .pdf)
        #expect(ContentKind.detect(contentType: nil, body: Data("<!DOCTYPE html><html>".utf8)) == .html)
        #expect(ContentKind.detect(contentType: nil, body: Data([0x00, 0x01, 0x02])) == .binary)
    }

    @Test func suggestsFileNames() {
        let response = HTTPResponse(
            url: URL(string: "https://example.com/files/report")!, statusCode: 200,
            headers: [HTTPField("Content-Type", "application/pdf")], body: Data("%PDF".utf8), duration: 0.1
        )
        #expect(response.suggestedFileName == "report.pdf")
        var attachment = response
        attachment.headers.append(HTTPField("Content-Disposition", #"attachment; filename="q3 results.pdf""#))
        #expect(attachment.suggestedFileName == "q3 results.pdf")
    }

    @Test func formatsXMLAndHex() {
        #expect(XMLFormatter.prettyPrinted("<a><b>1</b></a>")?.contains("\n") == true)
        #expect(HexDump.format(Data("Hi!".utf8)) == "00000000  " + "48 69 21".padding(toLength: 47, withPad: " ", startingAt: 0) + "  Hi!")
    }

    @Test func writesExchangeFiles() {
        var result = RunResult(reference: RequestReference(path: "Accounts/Auth.stamp", name: "logIn"), startedAt: Date(timeIntervalSince1970: 1_789_000_000))
        result.request = ResolvedRequest(
            name: "logIn", method: "POST", url: URL(string: "https://example.com/login")!,
            headers: [HTTPField("Content-Type", "application/json")], body: Data(#"{"password":"hunter2"}"#.utf8), secrets: ["hunter2"]
        )
        result.response = HTTPResponse(
            url: URL(string: "https://example.com/login")!, statusCode: 200,
            headers: [HTTPField("Content-Type", "application/json")], body: Data(#"{"ok":true}"#.utf8), duration: 0.132
        )
        result.assertions = [AssertionResult(source: "assert status == 200", line: 4, passed: true)]

        let text = ExchangeFile.text(for: result, title: "Log in")
        #expect(text.contains("POST https://example.com/login"))
        #expect(text.contains("\"password\": \"••••••\""))
        #expect(text.contains("<<< HTTP 200 OK"))
        #expect(text.contains("{\n  \"ok\": true\n}"))
        #expect(text.contains("# ✓ assert status == 200"))
        #expect(ExchangeFile.location(for: result, in: URL(fileURLWithPath: "/r")).path.hasPrefix("/r/Accounts/Auth/logIn/"))
    }
}
