import Foundation
import Testing
@testable import StampdrillCore

struct DataTableTests {
    @Test func readsCSV() throws {
        let csv = [#"name,city,"note, quoted""#, #"Ann,Berlin,"said ""hi""""#, "Bob,Erbil"].joined(separator: "\n")
        let table = try #require(DataTable.fromCSV(csv))
        #expect(table.columns == ["name", "city", "note, quoted"])
        #expect(table.rows == [["Ann", "Berlin", #"said "hi""#], ["Bob", "Erbil", ""]])
        #expect(table.path == nil)
    }

    @Test func detectsTheDelimiter() throws {
        let semicolons = try #require(DataTable.fromCSV("a;b\n1,5;2\n"))
        #expect(semicolons.columns == ["a", "b"])
        #expect(semicolons.rows == [["1,5", "2"]])
        let tabs = try #require(DataTable.fromCSV("a\tb\tb\n1\t2\t3"))
        #expect(tabs.columns == ["a", "b", "b 2"])
    }

    @Test func limitsRows() throws {
        let text = "n\n" + (1...10).map(String.init).joined(separator: "\n")
        let table = try #require(DataTable.fromCSV(text, limit: 4))
        #expect(table.rows.count == 4)
        #expect(table.omittedRowCount == 6)
    }

    @Test func readsArraysOfObjects() throws {
        let json = #"[{"id": 1, "name": "Ann", "address": {"city": "Berlin", "geo": {"lat": 1}}, "tags": ["a"]}, {"id": 2, "email": null}]"#
        let table = try #require(DataTable.fromJSON(Data(json.utf8)))
        #expect(table.columns == ["id", "name", "address.city", "address.geo", "tags", "email"])
        #expect(table.rows[0] == ["1", "Ann", "Berlin", #"{"lat":1}"#, #"["a"]"#, ""])
        #expect(table.rows[1] == ["2", "", "", "", "", "null"])
    }

    @Test func findsTheTableInsideAnObject() throws {
        let json = #"{"total": 3, "meta": {"page": 1}, "data": {"items": [{"a": 1}, {"a": 2}, {"a": 3}]}, "tags": [{"t": 1}]}"#
        let table = try #require(DataTable.fromJSON(Data(json.utf8)))
        #expect(table.path == "data.items")
        #expect(table.rows == [["1"], ["2"], ["3"]])
    }

    @Test func showsScalarArraysAsOneColumn() throws {
        let table = try #require(DataTable.fromJSON(Data(#"["husky", "corgi"]"#.utf8)))
        #expect(table.columns == ["value"])
        #expect(table.rows == [["husky"], ["corgi"]])
    }

    @Test func rejectsBodiesThatArentTables() {
        #expect(DataTable.fromJSON(Data(#"{"id": 1, "name": "Ann"}"#.utf8)) == nil)
        #expect(DataTable.fromJSON(Data("[]".utf8)) == nil)
        #expect(DataTable.fromCSV("") == nil)
    }

    @Test func recognisesCSVResponses() {
        let body = Data("a,b\n1,2".utf8)
        #expect(ContentKind.detect(contentType: "text/csv; charset=utf-8", body: body) == .csv)
        #expect(ContentKind.detect(contentType: "text/plain", body: body, url: URL(string: "https://example.com/data/gdp.csv")) == .csv)
        #expect(ContentKind.detect(contentType: "text/plain", body: body, url: URL(string: "https://example.com/readme.txt")) == .text)
    }
}
