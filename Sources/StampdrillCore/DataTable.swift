import Foundation
import Stamp

/// Rows and columns read from a CSV body, or from JSON shaped like a table:
/// an array of objects, or an object that holds one.
public struct DataTable: Equatable, Sendable {
    public var columns: [String]
    public var rows: [[String]]
    /// Where the rows were found inside a JSON body, like `products` or
    /// `data.items`; nil when the body itself is the table.
    public var path: String?
    /// Rows left out because the body had more than the limit.
    public var omittedRowCount = 0

    public init(columns: [String], rows: [[String]], path: String? = nil, omittedRowCount: Int = 0) {
        self.columns = columns
        self.rows = rows
        self.path = path
        self.omittedRowCount = omittedRowCount
    }

    public static let rowLimit = 20_000
    static let columnLimit = 250

    // MARK: CSV

    /// Reads comma, semicolon or tab separated text whose first row names the columns.
    public static func fromCSV(_ text: String, limit: Int = rowLimit) -> DataTable? {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r\n" }
        guard !firstLine.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let delimiter = [",", ";", "\t"].max { separators(of: $0, in: firstLine) < separators(of: $1, in: firstLine) } ?? ","

        var records = CSV.parse(text, delimiter: Character(delimiter))
        while let last = records.last, last.allSatisfy({ $0.isEmpty }) { records.removeLast() }
        guard let header = records.first, !header.isEmpty else { return nil }

        let columns = uniqueNames(header.prefix(columnLimit).enumerated().map { index, name in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "Column \(index + 1)" : trimmed
        })
        let body = records.dropFirst()
        let rows = body.prefix(limit).map { record -> [String] in
            var row = Array(record.prefix(columns.count))
            if row.count < columns.count { row += Array(repeating: "", count: columns.count - row.count) }
            return row
        }
        return DataTable(columns: columns, rows: rows, omittedRowCount: max(body.count - limit, 0))
    }

    /// Delimiters outside quotes, so a quoted "a, b" header doesn't count.
    private static func separators(of delimiter: String, in line: Substring) -> Int {
        var quoted = false
        var count = 0
        for character in line {
            if character == "\"" { quoted.toggle() }
            if !quoted, String(character) == delimiter { count += 1 }
        }
        return count
    }

    // MARK: JSON

    public static func fromJSON(_ data: Data, limit: Int = rowLimit) -> DataTable? {
        guard let value = try? Value(json: data), let (items, path) = rows(in: value) else { return nil }

        var columns: [String] = []
        var seen = Set<String>()
        var flattened: [[String: String]] = []
        for item in items.prefix(limit) {
            var fields: [String: String] = [:]
            flatten(item, prefix: nil, into: &fields) { name in
                if seen.insert(name).inserted, columns.count < columnLimit { columns.append(name) }
            }
            flattened.append(fields)
        }
        guard !columns.isEmpty else { return nil }
        let rows = flattened.map { fields in columns.map { fields[$0] ?? "" } }
        return DataTable(columns: columns, rows: rows, path: path, omittedRowCount: max(items.count - limit, 0))
    }

    /// The largest array of objects at the top or up to two levels down.
    private static func rows(in value: Value) -> ([Value], String?)? {
        func isTable(_ items: [Value]) -> Bool {
            guard !items.isEmpty else { return false }
            let objects = items.filter { if case .object = $0 { true } else { false } }.count
            return objects * 2 >= items.count
        }

        switch value {
        case .array(let items) where isTable(items):
            return (items, nil)
        case .array(let items) where !items.isEmpty && items.allSatisfy({ !$0.isContainer }):
            return (items.map { ["value": $0] }, nil)
        case .object(let object):
            var best: ([Value], String)?
            func search(_ object: ObjectValue, prefix: String?, depth: Int) {
                for (key, child) in object {
                    let path = prefix.map { "\($0).\(key)" } ?? key
                    switch child {
                    case .array(let items) where isTable(items):
                        if items.count > (best?.0.count ?? 0) { best = (items, path) }
                    case .object(let nested) where depth < 1:
                        search(nested, prefix: path, depth: depth + 1)
                    default:
                        break
                    }
                }
            }
            search(object, prefix: nil, depth: 0)
            return best.map { ($0.0, $0.1) }
        default:
            return nil
        }
    }

    /// Nested objects become `address.city` columns one level deep; anything
    /// deeper, and arrays, is shown as compact JSON.
    private static func flatten(_ value: Value, prefix: String?, into fields: inout [String: String], column: (String) -> Void) {
        guard case .object(let object) = value else {
            column("value")
            fields["value"] = text(value)
            return
        }
        for (key, child) in object {
            let name = prefix.map { "\($0).\(key)" } ?? key
            if case .object = child, prefix == nil {
                flatten(child, prefix: name, into: &fields, column: column)
            } else {
                column(name)
                fields[name] = text(child)
            }
        }
    }

    private static func text(_ value: Value) -> String {
        switch value {
        case .string(let string): string
        case .null: "null"
        case .array, .object: value.jsonString()
        default: value.interpolated
        }
    }

    private static func uniqueNames(_ names: [String]) -> [String] {
        var counts: [String: Int] = [:]
        return names.map { name in
            counts[name, default: 0] += 1
            return counts[name]! == 1 ? name : "\(name) \(counts[name]!)"
        }
    }
}

private extension Value {
    var isContainer: Bool {
        switch self {
        case .array, .object: true
        default: false
        }
    }
}
