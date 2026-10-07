import Foundation

/// Functions that need the scope itself: ones that call lambdas, and ones
/// that draw from the scope's (possibly seeded) random source. A variable
/// with the same name shadows them.
extension Scope {
    public static let intrinsicNames: Set<String> = [
        "uuid", "random", "randomInt", "randomFloat", "randomString", "oneOf", "shuffle",
        "person", "address", "organization", "mock",
        "map", "filter", "find", "all", "any", "count", "sortBy", "sum", "min", "max", "reduce", "flatMap",
        "groupBy", "unique", "range",
    ]

    func callIntrinsic(_ name: String, _ arguments: [Expr]) throws(EvaluationError) -> Value {
        var values: [Value] = []
        for argument in arguments { values.append(try evaluate(argument)) }

        func require(_ count: ClosedRange<Int>) throws(EvaluationError) {
            guard count.contains(values.count) else {
                let expected = count.lowerBound == count.upperBound ? "\(count.lowerBound)" : "\(count.lowerBound) to \(count.upperBound)"
                throw EvaluationError("\(name)() takes \(expected) argument\(count.upperBound == 1 ? "" : "s"), got \(values.count)")
            }
        }
        func list(_ index: Int) throws(EvaluationError) -> [Value] {
            switch values[index] {
            case .array(let items): return items
            case .object(let object): return object.map { Value.object(ObjectValue([("key", .string($0.key)), ("value", $0.value)])) }
            case .null: return []
            default: throw EvaluationError("\(name)() needs an array, got \(values[index].typeName)")
            }
        }
        func function(_ index: Int) throws(EvaluationError) -> Value {
            guard index < values.count else { throw EvaluationError("\(name)() needs a function like x => x.id") }
            switch values[index] {
            case .lambda, .function: return values[index]
            default: throw EvaluationError("\(name)() needs a function like x => x.id, got \(values[index].typeName)")
            }
        }
        func number(_ index: Int, default fallback: Double? = nil) throws(EvaluationError) -> Double {
            guard index < values.count else {
                if let fallback { return fallback }
                throw EvaluationError("\(name)() is missing argument \(index + 1)")
            }
            guard case .number(let n) = values[index] else { throw EvaluationError("\(name)() needs a number, got \(values[index].typeName)") }
            return n
        }

        switch name {
        // MARK: Random
        case "uuid":
            if let key = values.first {
                // The same key gives the same id for the same seed: create an
                // order with uuid("order") and fetch it later with uuid("order").
                var random = SeededRandom(seed: (seedText() ?? "") + "|uuid:" + key.interpolated)
                return .string(random.uuid())
            }
            return .string(withRandom { $0.uuid() })
        case "random":
            try require(1...1)
            let max = Int(try number(0))
            return .number(Double(max < 1 ? 0 : withRandom { $0.int(0...(max - 1)) }))
        case "randomInt":
            try require(2...2)
            let low = Int(try number(0)), high = Int(try number(1))
            guard low <= high else { throw EvaluationError("randomInt() needs min <= max") }
            return .number(Double(withRandom { $0.int(low...high) }))
        case "randomFloat":
            try require(2...3)
            let low = try number(0), high = try number(1), places = Int(try number(2, default: 2))
            let fraction = withRandom { Double($0.int(0...1_000_000)) / 1_000_000 }
            return .number((low + (high - low) * fraction).rounded(toPlaces: places))
        case "randomString":
            try require(1...2)
            let length = Int(try number(0))
            let alphabet = Array(values.count > 1 ? values[1].interpolated : "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            guard !alphabet.isEmpty else { return .string("") }
            return .string(String(withRandom { random in (0..<max(length, 0)).map { _ in random.pick(alphabet) } }))
        case "oneOf":
            let options = values.count == 1 ? try list(0) : values
            guard !options.isEmpty else { return .null }
            return withRandom { $0.pick(options) }
        case "shuffle":
            try require(1...1)
            let items = try list(0)
            return .array(withRandom { items.shuffled(using: &$0) })

        // MARK: Records
        case "person", "address", "organization":
            try require(0...1)
            if let key = values.first {
                // A key gives the same record every time, in every request.
                var random = SeededRandom(seed: (seedText().map { $0 + "|" } ?? "") + name + ":" + key.interpolated)
                return Faker.value(name, using: &random)!
            }
            return withRandom { Faker.value(name, using: &$0)! }
        case "mock":
            try require(1...2)
            if values.count == 2 {
                var random = SeededRandom(seed: (seedText().map { $0 + "|" } ?? "") + "mock:" + values[1].interpolated)
                return Mock.value(for: values[0], using: &random)
            }
            return withRandom { Mock.value(for: values[0], using: &$0) }

        // MARK: Collections
        case "map":
            try require(2...2)
            let transform = try function(1)
            var result: [Value] = []
            for item in try list(0) { result.append(try call(transform, [item])) }
            return .array(result)
        case "flatMap":
            try require(2...2)
            let transform = try function(1)
            var result: [Value] = []
            for item in try list(0) {
                let mapped = try call(transform, [item])
                if case .array(let inner) = mapped { result += inner } else { result.append(mapped) }
            }
            return .array(result)
        case "filter":
            try require(2...2)
            let predicate = try function(1)
            var result: [Value] = []
            for item in try list(0) where try call(predicate, [item]).isTruthy { result.append(item) }
            return .array(result)
        case "find":
            try require(2...2)
            let predicate = try function(1)
            for item in try list(0) where try call(predicate, [item]).isTruthy { return item }
            return .null
        case "all":
            try require(2...2)
            let predicate = try function(1)
            for item in try list(0) where !(try call(predicate, [item]).isTruthy) { return .bool(false) }
            return .bool(true)
        case "any":
            try require(2...2)
            let predicate = try function(1)
            for item in try list(0) where try call(predicate, [item]).isTruthy { return .bool(true) }
            return .bool(false)
        case "count":
            try require(1...2)
            let items = try list(0)
            guard values.count == 2 else { return .number(Double(items.count)) }
            let predicate = try function(1)
            var total = 0
            for item in items where try call(predicate, [item]).isTruthy { total += 1 }
            return .number(Double(total))
        case "sum":
            try require(1...2)
            var total = 0.0
            for item in try list(0) {
                let value = values.count == 2 ? try call(try function(1), [item]) : item
                guard case .number(let n) = value else { throw EvaluationError("sum() can only add numbers, got \(value.typeName)") }
                total += n
            }
            return .number(total)
        case "min", "max":
            try require(1...2)
            var best: (key: Value, item: Value)?
            for item in try list(0) {
                let key = values.count == 2 ? try call(try function(1), [item]) : item
                guard let current = best else { best = (key, item); continue }
                if try precedes(key, current.key) == (name == "min") { best = (key, item) }
            }
            return best?.item ?? .null
        case "sortBy":
            try require(2...2)
            let selector = try function(1)
            var keyed: [(Value, Value)] = []
            for item in try list(0) { keyed.append((try call(selector, [item]), item)) }
            var failure: EvaluationError?
            keyed.sort { lhs, rhs in
                do throws(EvaluationError) { return try precedes(lhs.0, rhs.0) } catch { failure = error; return false }
            }
            if let failure { throw failure }
            return .array(keyed.map(\.1))
        case "reduce":
            try require(3...3)
            let combine = try function(1)
            var accumulator = values[2]
            for item in try list(0) { accumulator = try call(combine, [accumulator, item]) }
            return accumulator
        case "groupBy":
            try require(2...2)
            let selector = try function(1)
            var groups = ObjectValue()
            for item in try list(0) {
                let key = try call(selector, [item]).interpolated
                if case .array(let existing)? = groups[key] { groups[key] = .array(existing + [item]) } else { groups[key] = .array([item]) }
            }
            return .object(groups)
        case "unique":
            try require(1...1)
            var seen: [Value] = []
            for item in try list(0) where !seen.contains(item) { seen.append(item) }
            return .array(seen)
        case "range":
            try require(1...2)
            let start = values.count == 2 ? Int(try number(0)) : 0
            let end = Int(try number(values.count == 2 ? 1 : 0))
            guard end - start <= 100_000 else { throw EvaluationError("range() is limited to 100000 numbers") }
            return .array(start < end ? (start..<end).map { .number(Double($0)) } : [])
        default:
            throw EvaluationError("unknown function '\(name)'")
        }
    }

    private func seedText() -> String? {
        guard let seed = try? lookup("seed"), seed != .null else { return nil }
        return seed.interpolated
    }

    /// Calls a Stamp function or a native one with already evaluated arguments.
    public func call(_ function: Value, _ arguments: [Value]) throws(EvaluationError) -> Value {
        switch function {
        case .function(let native):
            return try native(arguments)
        case .lambda(let lambda):
            guard callDepth < 32 else {
                throw EvaluationError("\(lambda.name ?? "function") calls itself too deeply")
            }
            var bindings: [String: ScopeBinding] = [:]
            for (index, parameter) in lambda.parameters.enumerated() {
                bindings[parameter] = .value(index < arguments.count ? arguments[index] : .null)
            }
            push(Layer(lambda.name ?? "function", bindings))
            callDepth += 1
            defer {
                callDepth -= 1
                pop()
            }
            return try evaluate(lambda.body)
        default:
            throw EvaluationError("\(function.typeName) is not a function")
        }
    }

    private func precedes(_ lhs: Value, _ rhs: Value) throws(EvaluationError) -> Bool {
        switch (lhs, rhs) {
        case let (.number(a), .number(b)): return a < b
        case let (.string(a), .string(b)): return a.localizedStandardCompare(b) == .orderedAscending
        case let (.bool(a), .bool(b)): return !a && b
        case (.null, .null): return false
        case (.null, _): return true
        case (_, .null): return false
        default: throw EvaluationError("cannot compare \(lhs.typeName) with \(rhs.typeName)")
        }
    }
}
