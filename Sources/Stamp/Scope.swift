import Foundation

/// Where a variable comes from and what it is bound to.
public enum ScopeBinding: Sendable, Equatable {
    case value(Value)
    case expression(Expr)
    case text(Template)
}

/// Variables available while evaluating, organised in layers.
///
/// Later layers shadow earlier ones: the environment sits below the file,
/// the file below the request, and so on. Bindings are evaluated lazily and
/// cached. While a binding is being evaluated, a reference to its own name
/// skips to the layers below it, which is what makes
/// `@token = Bearer {{token}}` wrap an environment value instead of looping.
public final class Scope {
    public struct Layer: Sendable {
        public var label: String
        public var bindings: [String: ScopeBinding]

        public init(_ label: String, _ bindings: [String: ScopeBinding] = [:]) {
            self.label = label
            self.bindings = bindings
        }
    }

    private struct Frame: Hashable {
        var name: String
        var layer: Int
    }

    public private(set) var layers: [Layer]
    public let builtins: [String: Value]
    /// Every value passed through `secret(...)`, so output can be masked.
    public private(set) var secrets: Set<String> = []

    private var cache: [Frame: Value] = [:]
    private var frames: [Frame] = []

    public init(layers: [Layer] = [], builtins: [String: Value] = [:]) {
        self.layers = layers
        self.builtins = builtins
    }

    public func push(_ layer: Layer) {
        layers.append(layer)
        cache.removeAll()
    }

    public func pop() {
        guard !layers.isEmpty else { return }
        layers.removeLast()
        cache.removeAll()
    }

    /// How deep function calls are nested, to stop runaway recursion.
    var callDepth = 0

    private var generator: SeededRandom?

    /// The random source for fake data. It is seeded from the `seed`
    /// variable when there is one, so the same values come back every run.
    func withRandom<T>(_ body: (inout SeededRandom) -> T) -> T {
        if generator == nil {
            if let seed = try? lookup("seed"), seed != .null {
                generator = SeededRandom(seed: seed.interpolated)
            } else {
                generator = .unseeded()
            }
        }
        return body(&generator!)
    }

    /// Binds a value in the top layer, creating one if needed.
    public func assign(_ name: String, _ value: Value) {
        if layers.isEmpty { layers.append(Layer("local")) }
        layers[layers.count - 1].bindings[name] = .value(value)
        cache.removeAll()
    }

    public func markSecret(_ text: String) {
        if !text.isEmpty { secrets.insert(text) }
    }

    /// The label of the layer a name currently resolves from.
    public func source(of name: String) -> String? {
        layers.last { $0.bindings[name] != nil }?.label ?? (builtins[name] != nil ? "builtin" : nil)
    }

    /// Every name visible from the top of the stack, shadowed names once.
    public var visibleNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for layer in layers.reversed() {
            for name in layer.bindings.keys.sorted() where seen.insert(name).inserted {
                names.append(name)
            }
        }
        return names
    }

    public func lookup(_ name: String) throws(EvaluationError) -> Value? {
        let enclosing = frames.last { $0.name == name }
        let upper = (enclosing?.layer ?? layers.count) - 1

        for index in stride(from: upper, through: 0, by: -1) {
            guard let binding = layers[index].bindings[name] else { continue }
            return try resolve(Frame(name: name, layer: index), binding)
        }
        if let builtin = builtins[name] { return builtin }
        if enclosing != nil {
            throw EvaluationError("'\(name)' refers to itself")
        }
        return nil
    }

    public func value(of name: String) throws(EvaluationError) -> Value {
        guard let value = try lookup(name) else {
            throw EvaluationError("unknown variable '\(name)'", undefinedName: name)
        }
        return value
    }

    private func resolve(_ frame: Frame, _ binding: ScopeBinding) throws(EvaluationError) -> Value {
        if let cached = cache[frame] { return cached }
        guard !frames.contains(frame) else {
            throw EvaluationError("'\(frame.name)' refers to itself")
        }
        frames.append(frame)
        defer { frames.removeLast() }

        let value: Value
        do {
            switch binding {
            case .value(let v): value = v
            case .expression(let expr): value = try evaluate(expr)
            case .text(let template): value = .string(try render(template))
            }
        } catch where error.undefinedName == nil && !error.message.hasPrefix("in '") {
            throw EvaluationError("in '\(frame.name)': \(error.message)")
        }
        cache[frame] = value
        return value
    }
}
