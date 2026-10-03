public enum UnaryOperator: String, Sendable {
    case not = "!"
    case negate = "-"
}

public enum BinaryOperator: String, Sendable {
    case add = "+"
    case subtract = "-"
    case multiply = "*"
    case divide = "/"
    case remainder = "%"
    case equal = "=="
    case notEqual = "!="
    case less = "<"
    case lessOrEqual = "<="
    case greater = ">"
    case greaterOrEqual = ">="
    case and = "&&"
    case or = "||"
    case coalesce = "??"
    case contains
    case matches
}

public enum LiteralValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
}

public struct ObjectEntry: Hashable, Sendable {
    public var key: String
    public var value: Expr
}

public indirect enum Expr: Hashable, Sendable {
    case literal(LiteralValue)
    case identifier(String)
    case member(Expr, String)
    case index(Expr, Expr)
    case call(Expr, [Expr])
    case unary(UnaryOperator, Expr)
    case binary(BinaryOperator, Expr, Expr)
    case conditional(Expr, Expr, Expr)
    case array([Expr])
    case object([ObjectEntry])
    /// `x => x.id` or `(a, b) => a + b`
    case lambda([String], Expr)
}

extension Expr: CustomStringConvertible {
    /// Canonical source form, used when reporting failed assertions.
    public var description: String {
        switch self {
        case .literal(.null): "null"
        case .literal(.bool(let b)): b ? "true" : "false"
        case .literal(.number(let n)): formatNumber(n)
        case .literal(.string(let s)): quoted(s)
        case .identifier(let name): name
        case .member(let base, let name): "\(base).\(name)"
        case .index(let base, let index): "\(base)[\(index)]"
        case .call(let callee, let args): "\(callee)(\(args.map(\.description).joined(separator: ", ")))"
        case .unary(let op, let operand): "\(op.rawValue)\(operand)"
        case .binary(let op, let lhs, let rhs): "\(lhs) \(op.rawValue) \(rhs)"
        case .conditional(let c, let a, let b): "\(c) ? \(a) : \(b)"
        case .array(let items): "[\(items.map(\.description).joined(separator: ", "))]"
        case .object(let entries): "{\(entries.map { "\(propertyName($0.key)): \($0.value)" }.joined(separator: ", "))}"
        case .lambda(let parameters, let body): parameters.count == 1 ? "\(parameters[0]) => \(body)" : "(\(parameters.joined(separator: ", "))) => \(body)"
        }
    }
}

func quoted(_ string: String) -> String {
    var result = "\""
    for scalar in string.unicodeScalars {
        switch scalar {
        case "\"": result += "\\\""
        case "\\": result += "\\\\"
        case "\n": result += "\\n"
        case "\t": result += "\\t"
        case "\r": result += "\\r"
        default: result.unicodeScalars.append(scalar)
        }
    }
    return result + "\""
}

func propertyName(_ key: String) -> String {
    let units = Array(key.utf16)
    guard let first = units.first, isIdentifierStart(first), units.allSatisfy(isIdentifierPart) else {
        return quoted(key)
    }
    return key
}

func formatNumber(_ number: Double) -> String {
    if number.isFinite, number == number.rounded(), abs(number) < 9_007_199_254_740_992 {
        return String(Int64(number))
    }
    return String(number)
}
