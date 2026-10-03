import Stamp

/// Chosen value per dimension. A dimension missing from the selection means
/// "any": only variable sets that don't constrain it apply.
public typealias DimensionSelection = [String: String]

/// Dimensions and the variable sets keyed by them.
///
/// Every variable set whose conditions match the selection contributes its
/// variables. Broader sets are applied first so more specific ones win; sets
/// with the same specificity apply in the order they were declared.
public struct EnvironmentMatrix: Sendable {
    public struct Entry: Sendable {
        public var set: VariableSet
        /// File the set was declared in, relative to the workspace.
        public var origin: String
        /// Sets from personal files (`environment.local.stamp`) outrank shared ones.
        public var isLocal = false
    }

    public private(set) var dimensions: [DimensionDeclaration] = []
    public private(set) var entries: [Entry] = []

    public init() {}

    public init(document: Document, origin: String) {
        merge(document, origin: origin)
    }

    public mutating func merge(_ document: Document, origin: String, isLocal: Bool = false) {
        for dimension in document.dimensions where !dimensions.contains(where: { $0.name == dimension.name }) {
            dimensions.append(dimension)
        }
        entries.append(contentsOf: document.variableSets.map { Entry(set: $0, origin: origin, isLocal: isLocal) })
    }

    public func merging(_ document: Document, origin: String) -> EnvironmentMatrix {
        var copy = self
        copy.merge(document, origin: origin)
        return copy
    }

    public func dimension(named name: String) -> DimensionDeclaration? {
        dimensions.first { $0.name == name }
    }

    /// The first value of every dimension.
    public var defaultSelection: DimensionSelection {
        dimensions.reduce(into: [:]) { selection, dimension in
            selection[dimension.name] = dimension.values.first
        }
    }

    /// Drops unknown dimensions and values, and fills in defaults for
    /// dimensions the selection doesn't mention at all.
    public func normalized(_ selection: DimensionSelection, fillingDefaults: Bool = true) -> DimensionSelection {
        var result: DimensionSelection = [:]
        for dimension in dimensions {
            if let chosen = selection[dimension.name] {
                if dimension.values.contains(chosen) { result[dimension.name] = chosen }
            } else if fillingDefaults, let first = dimension.values.first {
                result[dimension.name] = first
            }
        }
        return result
    }

    public func applicableEntries(for selection: DimensionSelection) -> [Entry] {
        entries.enumerated()
            .filter { $0.element.set.matches(selection) }
            .sorted {
                ($0.element.isLocal ? 1 : 0, $0.element.set.specificity, $0.offset)
                    < ($1.element.isLocal ? 1 : 0, $1.element.set.specificity, $1.offset)
            }
            .map(\.element)
    }

    /// One context layer per applicable set, lowest priority first.
    public func layers(for selection: DimensionSelection) -> [Scope.Layer] {
        applicableEntries(for: selection).map { entry in
            var bindings: [String: ScopeBinding] = [:]
            for declaration in entry.set.declarations { bindings[declaration.name] = declaration.binding }
            return Scope.Layer("\(entry.origin) vars \(entry.set.label)", bindings)
        }
    }

    /// Conditions that refer to dimensions or values nobody declared.
    public var problems: [(entry: Entry, message: String)] {
        entries.flatMap { entry in
            entry.set.conditions.compactMap { condition -> (Entry, String)? in
                guard let dimension = dimension(named: condition.dimension) else {
                    return (entry, "unknown dimension '\(condition.dimension)'")
                }
                let unknown = condition.values.filter { !dimension.values.contains($0) }
                guard unknown.isEmpty else {
                    return (entry, "'\(condition.dimension)' has no value \(unknown.map { "'\($0)'" }.joined(separator: ", "))")
                }
                return nil
            }
        }
    }
}
