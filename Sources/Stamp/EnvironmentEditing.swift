/// Edits to the dimensions and variable sets of a file, made on its text.
///
/// Each edit touches only the lines it has to, so comments, blank lines and
/// the order people chose survive editing from the app.
public struct EnvironmentEditor {
    public private(set) var text: String

    public init(text: String) {
        self.text = text
    }

    private var document: Document { Document.parse(text) }

    // MARK: Dimensions

    /// Replaces the values of a dimension, adding it when it doesn't exist.
    public mutating func setDimension(_ name: String, values: [String]) {
        let line = "dimension \(name) = \(values.joined(separator: ", "))"
        let document = document
        if let existing = document.dimensions.first(where: { $0.name == name }) {
            replaceLines(existing.line...existing.line, with: [line])
        } else if let last = document.dimensions.last {
            insertLines([line], after: last.line)
        } else {
            insertLines([line, ""], after: leadingCommentEnd(document))
        }
    }

    /// Renames a dimension and every condition that mentions it.
    public mutating func renameDimension(_ name: String, to newName: String) {
        let document = document
        guard name != newName, let dimension = document.dimensions.first(where: { $0.name == name }) else { return }
        replaceLines(dimension.line...dimension.line, with: ["dimension \(newName) = \(dimension.values.joined(separator: ", "))"])
        for (index, set) in document.variableSets.enumerated() where set.conditions.contains(where: { $0.dimension == name }) {
            let conditions = set.conditions.map { $0.dimension == name ? VariableSet.Condition(dimension: newName, values: $0.values) : $0 }
            setConditions(conditions, forSetAt: index)
        }
    }

    public mutating func removeDimension(_ name: String) {
        guard let dimension = document.dimensions.first(where: { $0.name == name }) else { return }
        replaceLines(dimension.line...dimension.line, with: [])
    }

    // MARK: Variable sets

    /// Appends an empty `vars` block.
    public mutating func addSet(conditions: [VariableSet.Condition]) {
        var lines = source.lines
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        if !lines.isEmpty { lines.append("") }
        lines.append(Self.opening(conditions))
        lines.append("}")
        text = lines.joined(separator: "\n") + "\n"
    }

    public mutating func removeSet(at index: Int) {
        let document = document
        guard document.variableSets.indices.contains(index) else { return }
        var range = document.variableSets[index].lines
        // Take one blank line along so blocks don't drift apart.
        if range.upperBound < source.lineCount, source.line(range.upperBound + 1).trimmingCharacters(in: .whitespaces).isEmpty {
            range = range.lowerBound...(range.upperBound + 1)
        }
        replaceLines(range, with: [])
    }

    public mutating func setConditions(_ conditions: [VariableSet.Condition], forSetAt index: Int) {
        let document = document
        guard document.variableSets.indices.contains(index) else { return }
        let line = document.variableSets[index].lines.lowerBound
        replaceLines(line...line, with: [Self.opening(conditions)])
    }

    /// Sets a variable in a set. `source` is what goes after `=`: when it
    /// parses as an expression the entry is `name = source`, otherwise it is
    /// kept as text with `@name = source`.
    public mutating func setVariable(_ name: String, source: String, inSetAt index: Int) {
        let document = document
        guard document.variableSets.indices.contains(index) else { return }
        let set = document.variableSets[index]
        let entry = Self.entry(name: name, source: source)

        if let existing = set.declarations.first(where: { $0.name == name }) {
            let indentation = String(self.source.line(existing.line).prefix { $0 == " " || $0 == "\t" })
            replaceLines(existing.line...existing.line, with: [indentation + entry])
        } else {
            let indentation = set.declarations.first.map { String(self.source.line($0.line).prefix { $0 == " " || $0 == "\t" }) } ?? "  "
            insertLines([indentation + entry], after: set.lines.upperBound - 1)
        }
    }

    public mutating func removeVariable(_ name: String, fromSetAt index: Int) {
        let document = document
        guard document.variableSets.indices.contains(index),
              let existing = document.variableSets[index].declarations.first(where: { $0.name == name })
        else { return }
        replaceLines(existing.line...existing.line, with: [])
    }

    /// Renames a variable in every set.
    public mutating func renameVariable(_ name: String, to newName: String) {
        guard name != newName else { return }
        for set in document.variableSets {
            guard let declaration = set.declarations.first(where: { $0.name == name }) else { continue }
            let source = Self.valueSource(of: declaration, in: self.source)
            let indentation = String(self.source.line(declaration.line).prefix { $0 == " " || $0 == "\t" })
            let prefix = if case .text = declaration.value { "@" } else { "" }
            replaceLines(declaration.line...declaration.line, with: [indentation + prefix + newName + " = " + source])
        }
    }

    // MARK: Combinations

    /// The set whose conditions are exactly `conditions`, in any order.
    public func setIndex(where conditions: [VariableSet.Condition]) -> Int? {
        let wanted = Self.normalized(conditions)
        return document.variableSets.firstIndex { Self.normalized($0.conditions) == wanted }
    }

    /// Sets a variable for one combination of dimension values, adding the
    /// `vars` block for that combination the first time.
    public mutating func setVariable(_ name: String, source: String, where conditions: [VariableSet.Condition]) {
        if setIndex(where: conditions) == nil { addSet(conditions: conditions) }
        guard let index = setIndex(where: conditions) else { return }
        setVariable(name, source: source, inSetAt: index)
    }

    /// Removes a variable from one combination, and the block once it is empty.
    public mutating func removeVariable(_ name: String, where conditions: [VariableSet.Condition]) {
        guard let index = setIndex(where: conditions) else { return }
        removeVariable(name, fromSetAt: index)
        if let emptied = setIndex(where: conditions), document.variableSets[emptied].declarations.isEmpty,
           !hasComments(in: document.variableSets[emptied])
        {
            removeSet(at: emptied)
        }
    }

    public mutating func renameVariable(_ name: String, to newName: String, where conditions: [VariableSet.Condition]) {
        guard name != newName, let index = setIndex(where: conditions),
              let declaration = document.variableSets[index].declarations.first(where: { $0.name == name })
        else { return }
        let source = self.source
        let indentation = String(source.line(declaration.line).prefix { $0 == " " || $0 == "\t" })
        let prefix = if case .text = declaration.value { "@" } else { "" }
        replaceLines(declaration.line...declaration.line, with: [indentation + prefix + newName + " = " + Self.valueSource(of: declaration, in: source)])
    }

    private func hasComments(in set: VariableSet) -> Bool {
        let kinds = document.lineKinds
        return set.lines.contains { kinds.indices.contains($0 - 1) && kinds[$0 - 1] == .comment }
    }

    private static func normalized(_ conditions: [VariableSet.Condition]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for condition in conditions where !condition.values.isEmpty {
            result[condition.dimension, default: []].formUnion(condition.values)
        }
        return result
    }

    /// The text after `=` of an entry, as written.
    public static func valueSource(of declaration: Declaration, in source: SourceText) -> String {
        let line = source.line(declaration.line)
        guard let equals = line.firstIndex(of: "=") else { return "" }
        return String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Helpers

    private var source: SourceText { SourceText(text) }

    static func opening(_ conditions: [VariableSet.Condition]) -> String {
        let list = conditions
            .filter { !$0.values.isEmpty }
            .map { "\($0.dimension)=\($0.values.joined(separator: "|"))" }
            .joined(separator: ", ")
        return list.isEmpty ? "vars {" : "vars \(list) {"
    }

    static func entry(name: String, source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        if (try? ExprParser.parse(trimmed)) != nil {
            return "\(name) = \(trimmed)"
        }
        return "@\(name) = \(trimmed)"
    }

    private func leadingCommentEnd(_ document: Document) -> Int {
        var line = 0
        for (index, kind) in document.lineKinds.enumerated() {
            guard kind == .comment || kind == .blank else { break }
            if kind == .comment { line = index + 1 }
        }
        return line == 0 ? 0 : line + 1
    }

    private mutating func replaceLines(_ range: ClosedRange<Int>, with replacement: [String]) {
        var lines = source.lines
        let lower = max(range.lowerBound - 1, 0)
        let upper = min(range.upperBound, lines.count)
        lines.replaceSubrange(lower..<upper, with: replacement)
        text = lines.joined(separator: "\n")
    }

    /// Inserts after the 1-based `line`; 0 inserts at the top.
    private mutating func insertLines(_ inserted: [String], after line: Int) {
        var lines = source.lines
        lines.insert(contentsOf: inserted, at: min(max(line, 0), lines.count))
        text = lines.joined(separator: "\n")
    }
}
