import Foundation

/// A runtime value produced by evaluating an expression.
public enum Value: Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([Value])
    case object(ObjectValue)
    case function(NativeFunction)
    /// An object whose members are computed on access.
    case dynamic(DynamicObject)
    /// A function written in Stamp, with `fn` or `x => …`.
    case lambda(Lambda)
}

public struct Lambda: Hashable, Sendable {
    public var name: String?
    public var parameters: [String]
    public var body: Expr

    public init(name: String? = nil, parameters: [String], body: Expr) {
        self.name = name
        self.parameters = parameters
        self.body = body
    }
}

public struct NativeFunction: Sendable {
    public let name: String
    let body: @Sendable ([Value]) throws(EvaluationError) -> Value

    public init(_ name: String, _ body: @escaping @Sendable ([Value]) throws(EvaluationError) -> Value) {
        self.name = name
        self.body = body
    }

    public func callAsFunction(_ arguments: [Value]) throws(EvaluationError) -> Value {
        try body(arguments)
    }
}

public struct DynamicObject: Sendable {
    public let name: String
    public let memberNames: [String]
    let resolve: @Sendable (String) -> Value?

    public init(_ name: String, members: [String], _ resolve: @escaping @Sendable (String) -> Value?) {
        self.name = name
        self.memberNames = members
        self.resolve = resolve
    }

    public func member(_ name: String) -> Value? { resolve(name) }
}

/// A JSON-like object that remembers the order its keys were inserted in.
public struct ObjectValue: Sendable, Equatable, Sequence {
    public private(set) var keys: [String] = []
    private var storage: [String: Value] = [:]

    public init() {}

    public init(_ pairs: [(String, Value)]) {
        for (key, value) in pairs { self[key] = value }
    }

    public subscript(key: String) -> Value? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public func makeIterator() -> some IteratorProtocol<(key: String, value: Value)> {
        keys.lazy.map { (key: $0, value: storage[$0]!) }.makeIterator()
    }

    public static func == (lhs: ObjectValue, rhs: ObjectValue) -> Bool {
        lhs.storage == rhs.storage
    }
}

extension Value: Equatable {
    public static func == (lhs: Value, rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.number(a), .number(b)): a == b
        case let (.string(a), .string(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.object(a), .object(b)): a == b
        case let (.function(a), .function(b)): a.name == b.name
        case let (.dynamic(a), .dynamic(b)): a.name == b.name
        case let (.lambda(a), .lambda(b)): a == b
        default: false
        }
    }
}

extension Value: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: Value...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, Value)...) { self = .object(ObjectValue(elements)) }
    public init(nilLiteral: ()) { self = .null }
}

extension Value {
    public var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object, .dynamic: "object"
        case .function, .lambda: "function"
        }
    }

    public var isTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let b): b
        case .number(let n): n != 0 && !n.isNaN
        case .string(let s): !s.isEmpty
        default: true
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var objectValue: ObjectValue? {
        if case .object(let object) = self { return object }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var arrayValue: [Value]? {
        if case .array(let items) = self { return items }
        return nil
    }

    /// The text a value becomes when it is interpolated into a request.
    public var interpolated: String {
        switch self {
        case .null: ""
        case .bool(let b): b ? "true" : "false"
        case .number(let n): formatNumber(n)
        case .string(let s): s
        case .array, .object: jsonString()
        case .function(let f): "\(f.name)()"
        case .dynamic(let d): d.name
        case .lambda(let l): "\(l.name ?? "fn")(\(l.parameters.joined(separator: ", ")))"
        }
    }

    /// A short rendering used in diagnostics and the console.
    public var debugText: String {
        switch self {
        case .string(let s): quoted(s)
        default: interpolated
        }
    }
}

extension Value {
    /// The value written as Stamp source, for saving it back into a file.
    public var sourceLiteral: String {
        switch self {
        case .string(let s): quoted(s)
        case .number, .bool, .null: interpolated
        case .array, .object: jsonString()
        case .function(let f): quoted(f.name)
        case .dynamic(let d): quoted(d.name)
        case .lambda(let l): "(\(l.parameters.joined(separator: ", "))) => \(l.body)"
        }
    }
}
