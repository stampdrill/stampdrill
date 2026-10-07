import Foundation

/// A position inside a source file.
///
/// Lines are 1-based. Columns are 0-based UTF-16 offsets into the line, so a
/// location maps directly onto an `NSRange` in a text view.
public struct SourceLocation: Hashable, Comparable, Sendable {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public static func < (lhs: SourceLocation, rhs: SourceLocation) -> Bool {
        (lhs.line, lhs.column) < (rhs.line, rhs.column)
    }
}

public struct SourceRange: Hashable, Sendable {
    public var start: SourceLocation
    public var end: SourceLocation

    public init(start: SourceLocation, end: SourceLocation) {
        self.start = start
        self.end = end
    }

    /// A range covering `length` UTF-16 units of a single line.
    public init(line: Int, column: Int = 0, length: Int) {
        start = SourceLocation(line: line, column: column)
        end = SourceLocation(line: line, column: column + max(length, 0))
    }
}

/// The text of a file split into lines, with the offsets needed to translate
/// between line/column positions and flat UTF-16 ranges.
public struct SourceText: Sendable {
    public let string: String
    public let lines: [String]
    private let lineOffsets: [Int]

    public init(_ string: String) {
        self.string = string

        var lines: [String] = []
        var offsets: [Int] = [0]
        var current: [UInt16] = []
        var offset = 0
        for unit in string.utf16 {
            offset += 1
            if unit == 0x0A {
                if current.last == 0x0D { current.removeLast() }
                lines.append(String(decoding: current, as: UTF16.self))
                current.removeAll(keepingCapacity: true)
                offsets.append(offset)
            } else {
                current.append(unit)
            }
        }
        if current.last == 0x0D { current.removeLast() }
        lines.append(String(decoding: current, as: UTF16.self))

        self.lines = lines
        self.lineOffsets = offsets
    }

    public var lineCount: Int { lines.count }

    public func line(_ number: Int) -> String {
        guard number >= 1, number <= lines.count else { return "" }
        return lines[number - 1]
    }

    /// UTF-16 offset of the first character of a 1-based line.
    public func offset(ofLine number: Int) -> Int {
        guard number >= 1 else { return 0 }
        guard number <= lineOffsets.count else { return string.utf16.count }
        return lineOffsets[number - 1]
    }

    public func nsRange(for range: SourceRange) -> NSRange {
        let start = offset(ofLine: range.start.line) + range.start.column
        let end = offset(ofLine: range.end.line) + range.end.column
        return NSRange(location: start, length: max(end - start, 0))
    }

    /// NSRange spanning whole lines, including the trailing line break of the last one.
    public func nsRange(forLines lines: ClosedRange<Int>) -> NSRange {
        let start = offset(ofLine: lines.lowerBound)
        let end = lines.upperBound < lineOffsets.count
            ? offset(ofLine: lines.upperBound + 1)
            : string.utf16.count
        return NSRange(location: start, length: end - start)
    }

    public func location(atOffset utf16Offset: Int) -> SourceLocation {
        var low = 0
        var high = lineOffsets.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineOffsets[mid] <= utf16Offset { low = mid } else { high = mid - 1 }
        }
        return SourceLocation(line: low + 1, column: utf16Offset - lineOffsets[low])
    }
}

public struct Diagnostic: Error, Hashable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable {
        case warning
        case error
    }

    public var severity: Severity
    public var message: String
    public var range: SourceRange

    public init(_ severity: Severity, _ message: String, at range: SourceRange) {
        self.severity = severity
        self.message = message
        self.range = range
    }

    public static func error(_ message: String, at range: SourceRange) -> Diagnostic {
        Diagnostic(.error, message, at: range)
    }

    public static func warning(_ message: String, at range: SourceRange) -> Diagnostic {
        Diagnostic(.warning, message, at: range)
    }

    public var description: String {
        "\(range.start.line):\(range.start.column + 1): \(severity.rawValue): \(message)"
    }
}
