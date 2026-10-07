import Foundation
import Testing
@testable import Stamp

struct SourceTextTests {
    @Test func splitsLinesAndKeepsTrailingEmptyLine() {
        let source = SourceText("GET /a\nAccept: */*\n")
        #expect(source.lines == ["GET /a", "Accept: */*", ""])
        #expect(source.offset(ofLine: 2) == 7)
    }

    @Test func stripsCarriageReturns() {
        let source = SourceText("GET /a\r\nHost: x\r\n\r\nbody")
        #expect(source.lines == ["GET /a", "Host: x", "", "body"])
        #expect(source.offset(ofLine: 4) == 19)
    }

    @Test func mapsRangesToNSRange() {
        let source = SourceText("one\ntwo three")
        let range = SourceRange(line: 2, column: 4, length: 5)
        #expect(source.nsRange(for: range) == NSRange(location: 8, length: 5))
        #expect(source.nsRange(forLines: 1...1) == NSRange(location: 0, length: 4))
    }

    @Test func findsLocationForOffset() {
        let source = SourceText("ab\ncd\nef")
        #expect(source.location(atOffset: 4) == SourceLocation(line: 2, column: 1))
        #expect(source.location(atOffset: 0) == SourceLocation(line: 1, column: 0))
    }
}
