import Foundation

extension Scope {
    public func evaluate(_ expr: Expr) throws(EvaluationError) -> Value {
        switch expr {
        case .literal(let literal):
            switch literal {
            case .null: return .null
            case .bool(let b): return .bool(b)
            case .number(let n): return .number(n)
            case .string(let s): return .string(s)
            }

        case .identifier(let name):
            if name == "env", try lookup("env") == nil {
                return .object(environmentObject())
            }
            if name == "fake", try lookup("fake") == nil {
                return withRandom { random in
                    .object(ObjectValue(Faker.members.compactMap { member in Faker.value(member, using: &random).map { (member, $0) } }))
                }
            }
            return try value(of: name)

        case .member(.identifier("fake"), let name) where try lookup("fake") == nil:
            guard let value = withRandom({ Faker.value(name, using: &$0) }) else {
                throw EvaluationError("fake has no '\(name)'; try one of \(Faker.members.prefix(8).joined(separator: ", "))…")
            }
            return value

        case .member(.identifier("env"), let name) where try lookup("env") == nil:
            return try lookup(name) ?? .null

        case .member(let base, let name):
            return try member(name, of: evaluate(base))

        case .index(let base, let index):
            return try subscripted(evaluate(base), by: evaluate(index))

        case .call(.identifier("secret"), let arguments) where try lookup("secret") == nil:
            guard arguments.count == 1 else { throw EvaluationError("secret() takes one argument") }
            let value = try evaluate(arguments[0])
            markSecret(value.interpolated)
            return value

        case .call(.identifier(let name), let arguments) where try isIntrinsic(name):
            return try callIntrinsic(name, arguments)

        case .call(let callee, let arguments):
            let function = try evaluate(callee)
            switch function {
            case .function, .lambda: break
            default: throw EvaluationError("'\(callee)' is not a function")
            }
            var values: [Value] = []
            for argument in arguments { values.append(try evaluate(argument)) }
            return try call(function, values)

        case .lambda(let parameters, let body):
            return .lambda(Lambda(parameters: parameters, body: body))

        case .unary(.not, let operand):
            return .bool(!(try evaluate(operand).isTruthy))

        case .unary(.negate, let operand):
            guard case .number(let n) = try evaluate(operand) else {
                throw EvaluationError("cannot negate '\(operand)'")
            }
            return .number(-n)

        case .binary(let op, let lhs, let rhs):
            return try binary(op, lhs, rhs)

        case .conditional(let condition, let then, let otherwise):
            return try evaluate(condition).isTruthy ? evaluate(then) : evaluate(otherwise)

        case .array(let items):
            var values: [Value] = []
            for item in items { values.append(try evaluate(item)) }
            return .array(values)

        case .object(let entries):
            var object = ObjectValue()
            for entry in entries { object[entry.key] = try evaluate(entry.value) }
            return .object(object)
        }
    }

    private func isIntrinsic(_ name: String) throws(EvaluationError) -> Bool {
        guard Scope.intrinsicNames.contains(name) else { return false }
        return try lookup(name) == nil
    }

    private func environmentObject() -> ObjectValue {
        var object = ObjectValue()
        for name in visibleNames {
            if let value = try? lookup(name) { object[name] = value }
        }
        return object
    }

    private func member(_ name: String, of base: Value) throws(EvaluationError) -> Value {
        switch base {
        case .object(let object):
            return object[name] ?? .null
        case .dynamic(let object):
            return object.member(name) ?? .null
        case .null:
            return .null
        case .array(let items):
            switch name {
            case "length", "count": return .number(Double(items.count))
            case "first": return items.first ?? .null
            case "last": return items.last ?? .null
            default: break
            }
        case .string(let string):
            if name == "length" || name == "count" { return .number(Double(string.count)) }
        default:
            break
        }
        throw EvaluationError("\(base.typeName) has no property '\(name)'")
    }

    private func subscripted(_ base: Value, by index: Value) throws(EvaluationError) -> Value {
        switch (base, index) {
        case (.null, _):
            return .null
        case let (.array(items), .number(n)):
            guard let i = Int(exactly: n) else { throw EvaluationError("array index must be a whole number") }
            let position = i < 0 ? items.count + i : i
            return items.indices.contains(position) ? items[position] : .null
        case let (.string(string), .number(n)):
            guard let i = Int(exactly: n) else { throw EvaluationError("string index must be a whole number") }
            let characters = Array(string)
            let position = i < 0 ? characters.count + i : i
            return characters.indices.contains(position) ? .string(String(characters[position])) : .null
        case (.object, .string(let key)), (.dynamic, .string(let key)):
            return try member(key, of: base)
        default:
            throw EvaluationError("cannot index \(base.typeName) with \(index.typeName)")
        }
    }

    private func binary(_ op: BinaryOperator, _ lhsExpr: Expr, _ rhsExpr: Expr) throws(EvaluationError) -> Value {
        switch op {
        case .and:
            guard try evaluate(lhsExpr).isTruthy else { return .bool(false) }
            return .bool(try evaluate(rhsExpr).isTruthy)
        case .or:
            if try evaluate(lhsExpr).isTruthy { return .bool(true) }
            return .bool(try evaluate(rhsExpr).isTruthy)
        case .coalesce:
            do {
                let lhs = try evaluate(lhsExpr)
                if lhs != .null { return lhs }
            } catch where error.undefinedName != nil {
                // An unset variable falls through to the default.
            }
            return try evaluate(rhsExpr)
        default:
            break
        }

        let lhs = try evaluate(lhsExpr)
        let rhs = try evaluate(rhsExpr)

        switch (op, lhs, rhs) {
        case (.equal, _, _): return .bool(lhs == rhs)
        case (.notEqual, _, _): return .bool(lhs != rhs)

        case let (.add, .number(a), .number(b)): return .number(a + b)
        case (.add, .string, _), (.add, _, .string): return .string(lhs.interpolated + rhs.interpolated)
        case let (.add, .array(a), .array(b)): return .array(a + b)
        case let (.add, .object(a), .object(b)):
            var merged = a
            for (key, value) in b { merged[key] = value }
            return .object(merged)

        case let (.subtract, .number(a), .number(b)): return .number(a - b)
        case let (.multiply, .number(a), .number(b)): return .number(a * b)
        case let (.divide, .number(a), .number(b)):
            guard b != 0 else { throw EvaluationError("division by zero") }
            return .number(a / b)
        case let (.remainder, .number(a), .number(b)):
            guard b != 0 else { throw EvaluationError("division by zero") }
            return .number(a.truncatingRemainder(dividingBy: b))

        case let (.less, .number(a), .number(b)): return .bool(a < b)
        case let (.lessOrEqual, .number(a), .number(b)): return .bool(a <= b)
        case let (.greater, .number(a), .number(b)): return .bool(a > b)
        case let (.greaterOrEqual, .number(a), .number(b)): return .bool(a >= b)
        case let (.less, .string(a), .string(b)): return .bool(a < b)
        case let (.lessOrEqual, .string(a), .string(b)): return .bool(a <= b)
        case let (.greater, .string(a), .string(b)): return .bool(a > b)
        case let (.greaterOrEqual, .string(a), .string(b)): return .bool(a >= b)

        case let (.contains, .string(a), .string(b)): return .bool(a.contains(b))
        case let (.contains, .array(a), _): return .bool(a.contains(rhs))
        case let (.contains, .object(a), .string(key)): return .bool(a[key] != nil)

        case let (.matches, .string(a), .string(pattern)):
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                throw EvaluationError("invalid regular expression \(quoted(pattern))")
            }
            let range = NSRange(a.startIndex..., in: a)
            return .bool(regex.firstMatch(in: a, range: range) != nil)

        default:
            throw EvaluationError("cannot apply '\(op.rawValue)' to \(lhs.typeName) and \(rhs.typeName)")
        }
    }
}
