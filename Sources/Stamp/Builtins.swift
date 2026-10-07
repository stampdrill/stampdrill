#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Functions and constants every expression can use.
public enum Builtins {
    public static let standard: [String: Value] = {
        var values: [String: Value] = [:]
        for function in functions { values[function.name] = .function(function) }
        for (name, port) in ports { values[name] = .number(Double(port)) }
        values["contentType"] = contentTypes
        return values
    }()

    static let contentTypes: Value = [
            "json": "application/json",
            "xml": "application/xml",
            "form": "application/x-www-form-urlencoded",
            "multipart": "multipart/form-data",
            "text": "text/plain",
            "html": "text/html",
        ]

    /// Well-known ports, so hosts can be written as `localhost(TOMCAT)`.
    static let ports: [(String, Int)] = [
        ("HTTP", 80), ("WEB", 80), ("HTTPS", 443), ("WEB_PROXY", 8080), ("TOMCAT", 8080), ("NGINX", 8080),
        ("SYNAPSE", 8243), ("SYNAPSE_HTTP", 8280), ("SOLR", 8983), ("MYSQL", 3306), ("POSTGRES", 5432),
        ("MONGODB", 27017), ("REDIS", 6379), ("ZOOKEEPER", 2888),
    ]

    static let functions: [NativeFunction] = [
        NativeFunction("now") { _ in .string(Date().formatted(.iso8601)) },
        NativeFunction("timestamp") { _ in .number(Date().timeIntervalSince1970.rounded(.down)) },

        NativeFunction("json") { args throws(EvaluationError) in
            try arity(args, 1, in: "json")
            return .string(args[0].jsonString())
        },
        NativeFunction("parseJson") { args throws(EvaluationError) in
            try Value(json: try string(args, 0, in: "parseJson"))
        },
        NativeFunction("string") { args throws(EvaluationError) in
            try arity(args, 1, in: "string")
            return .string(args[0].interpolated)
        },
        NativeFunction("number") { args throws(EvaluationError) in
            try arity(args, 1, in: "number")
            switch args[0] {
            case .number: return args[0]
            case .bool(let b): return .number(b ? 1 : 0)
            case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces)).map(Value.number) ?? .null
            default: return .null
            }
        },
        NativeFunction("length") { args throws(EvaluationError) in
            try arity(args, 1, in: "length")
            switch args[0] {
            case .string(let s): return .number(Double(s.count))
            case .array(let a): return .number(Double(a.count))
            case .object(let o): return .number(Double(o.count))
            default: throw EvaluationError("length() needs a string, array or object")
            }
        },
        NativeFunction("keys") { args throws(EvaluationError) in
            guard args.count == 1, case .object(let object) = args[0] else {
                throw EvaluationError("keys() needs an object")
            }
            return .array(object.keys.map(Value.string))
        },

        NativeFunction("upper") { args throws(EvaluationError) in .string(try string(args, 0, in: "upper").uppercased()) },
        NativeFunction("lower") { args throws(EvaluationError) in .string(try string(args, 0, in: "lower").lowercased()) },
        NativeFunction("trim") { args throws(EvaluationError) in
            .string(try string(args, 0, in: "trim").trimmingCharacters(in: .whitespacesAndNewlines))
        },
        NativeFunction("replace") { args throws(EvaluationError) in
            let text = try string(args, 0, in: "replace")
            return .string(text.replacingOccurrences(of: try string(args, 1, in: "replace"), with: try string(args, 2, in: "replace")))
        },
        NativeFunction("split") { args throws(EvaluationError) in
            let text = try string(args, 0, in: "split")
            let separator = try string(args, 1, in: "split")
            return .array(text.components(separatedBy: separator).map(Value.string))
        },
        NativeFunction("join") { args throws(EvaluationError) in
            guard args.count == 2, case .array(let items) = args[0] else {
                throw EvaluationError("join() needs an array and a separator")
            }
            return .string(items.map(\.interpolated).joined(separator: args[1].interpolated))
        },

        NativeFunction("urlencode") { args throws(EvaluationError) in
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return .string(try string(args, 0, in: "urlencode").addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        },
        NativeFunction("base64") { args throws(EvaluationError) in
            .string(Data(try string(args, 0, in: "base64").utf8).base64EncodedString())
        },
        NativeFunction("base64decode") { args throws(EvaluationError) in
            let text = try string(args, 0, in: "base64decode")
            guard let data = Data(base64Encoded: base64Padded(text)) else {
                throw EvaluationError("base64decode() got invalid base64")
            }
            return .string(String(decoding: data, as: UTF8.self))
        },
        NativeFunction("sha256") { args throws(EvaluationError) in
            .string(hex(SHA256.hash(data: Data(try string(args, 0, in: "sha256").utf8))))
        },
        NativeFunction("hmacSha256") { args throws(EvaluationError) in
            let key = SymmetricKey(data: Data(try string(args, 0, in: "hmacSha256").utf8))
            let message = Data(try string(args, 1, in: "hmacSha256").utf8)
            return .string(hex(HMAC<SHA256>.authenticationCode(for: message, using: key)))
        },

        NativeFunction("getenv") { args throws(EvaluationError) in
            ProcessInfo.processInfo.environment[try string(args, 0, in: "getenv")].map(Value.string) ?? .null
        },

        NativeFunction("bearer") { args throws(EvaluationError) in
            try arity(args, 1, in: "bearer")
            let token = args[0].interpolated
            return .string(token.hasPrefix("Bearer ") ? token : "Bearer " + token)
        },
        NativeFunction("basic") { args throws(EvaluationError) in
            try arity(args, 2, in: "basic")
            let credentials = args[0].interpolated + ":" + args[1].interpolated
            return .string("Basic " + Data(credentials.utf8).base64EncodedString())
        },
        NativeFunction("onPort") { args throws(EvaluationError) in
            try arity(args, 2, in: "onPort")
            return .string(hostAndPort(args[0].interpolated, args[1]))
        },
        NativeFunction("localhost") { args throws(EvaluationError) in
            .string(hostAndPort("localhost", args.first ?? .null))
        },
    ]

}

private func arity(_ args: [Value], _ count: Int, in name: String) throws(EvaluationError) {
    guard args.count == count else {
        throw EvaluationError("\(name)() takes \(count) argument\(count == 1 ? "" : "s"), got \(args.count)")
    }
}

private func string(_ args: [Value], _ index: Int, in name: String) throws(EvaluationError) -> String {
    guard index < args.count else { throw EvaluationError("\(name)() is missing argument \(index + 1)") }
    switch args[index] {
    case .string(let s): return s
    case .number, .bool: return args[index].interpolated
    default: throw EvaluationError("\(name)() needs a string, got \(args[index].typeName)")
    }
}

private func number(_ args: [Value], _ index: Int, in name: String) throws(EvaluationError) -> Double {
    guard index < args.count else { throw EvaluationError("\(name)() is missing argument \(index + 1)") }
    guard case .number(let n) = args[index] else {
        throw EvaluationError("\(name)() needs a number, got \(args[index].typeName)")
    }
    return n
}

private func hostAndPort(_ host: String, _ port: Value) -> String {
    let text = port.interpolated
    return text.isEmpty || text == "80" ? host : host + ":" + text
}

private func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
}

func base64Padded(_ text: String) -> String {
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64 += "=" }
    return base64
}
