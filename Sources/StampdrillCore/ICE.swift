import Foundation
import Stamp

/// A STUN or TURN server, written the way WebRTC's `iceServers` take them:
/// `stun:stun.example.com:19302`, `turns:turn.example.com?transport=tcp`.
public struct ICEServer: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case stun
        case turn
    }

    public enum Transport: String, Sendable {
        case udp
        case tcp
        case tls
    }

    public var kind: Kind
    public var host: String
    public var port: UInt16
    public var transport: Transport

    public var isSecure: Bool { transport == .tls }
    public var address: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    public var scheme: String { kind.rawValue + (isSecure ? "s" : "") }

    /// Also stands in for the request's URL.
    public var url: URL {
        var text = "\(scheme)://\(address)"
        if transport == .tcp { text += "?transport=tcp" }
        return URL(string: text) ?? URL(string: "\(scheme)://invalid")!
    }

    public init(kind: Kind, host: String, port: UInt16? = nil, transport: Transport = .udp) {
        self.kind = kind
        self.host = host
        self.transport = transport
        self.port = port ?? (transport == .tls ? 5349 : 3478)
    }

    /// Reads a server; `kind` is the request's method when the text has no scheme.
    public init?(_ text: String, kind defaultKind: Kind) {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        var kind = defaultKind
        var secure = false
        if let colon = rest.firstIndex(of: ":"), let scheme = Optional(rest[..<colon].lowercased()),
           ["stun", "stuns", "turn", "turns"].contains(scheme)
        {
            kind = scheme.hasPrefix("stun") ? .stun : .turn
            secure = scheme.hasSuffix("s")
            rest = rest[rest.index(after: colon)...]
            if rest.hasPrefix("//") { rest = rest.dropFirst(2) }
        }

        var transport: Transport = secure ? .tls : .udp
        if let question = rest.firstIndex(of: "?") {
            let query = rest[rest.index(after: question)...].lowercased()
            rest = rest[..<question]
            if query.contains("transport=tcp"), !secure { transport = .tcp }
        }

        var port: UInt16?
        let host: String
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            host = String(rest[rest.index(after: rest.startIndex) ..< close])
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") {
                guard let number = UInt16(after.dropFirst()) else { return nil }
                port = number
            }
        } else if let colon = rest.lastIndex(of: ":") {
            host = String(rest[..<colon])
            guard let number = UInt16(rest[rest.index(after: colon)...]) else { return nil }
            port = number
        } else {
            host = String(rest)
        }
        guard !host.isEmpty, !host.contains("/"), !host.contains(" ") else { return nil }
        self.init(kind: kind, host: host, port: port, transport: transport)
    }
}

// MARK: Transport

/// A connection that carries whole STUN messages.
public protocol ICEChannel: Sendable {
    /// True for TCP and TLS, where retransmitting is the transport's job.
    var isReliable: Bool { get }
    /// The local side of the connection, like `192.168.1.20:61234`.
    var localAddress: String? { get async }
    func send(_ data: Data) async throws
    /// The next message, or nil when none arrives in time.
    func receive(timeout: TimeInterval) async throws -> Data?
    func close() async
}

public protocol ICETransport: Sendable {
    func open(_ server: ICEServer, timeout: TimeInterval, allowsInsecureConnections: Bool) async throws -> any ICEChannel
}

// MARK: Probe

/// Checks a STUN server with a Binding request, or a TURN server by
/// allocating a relay (and releasing it straight away).
public enum ICEProbe {
    public struct Outcome: Sendable {
        public var statusCode: Int
        public var report: Value
    }

    public static func run(
        _ server: ICEServer, credentials: (username: String, password: String)?, transport: any ICETransport,
        timeout: TimeInterval, allowsInsecureConnections: Bool = false
    ) async throws -> Outcome {
        let channel = try await transport.open(server, timeout: timeout, allowsInsecureConnections: allowsInsecureConnections)
        defer { Task { await channel.close() } }
        let deadline = Date().addingTimeInterval(timeout)

        var report = ObjectValue()
        report["server"] = .string(server.address)
        report["transport"] = .string(server.transport.rawValue)
        if let local = await channel.localAddress { report["local"] = .string(local) }

        switch server.kind {
        case .stun:
            let request = STUNMessage(method: .binding, class: .request, attributes: [STUNMessage.text(.software, software)])
            let (response, rtt) = try await transaction(request, key: nil, over: channel, server: server, deadline: deadline)
            report["rtt"] = .number(rtt)
            return finish(response, report: &report)

        case .turn:
            let transportAttribute = STUNMessage.uint32(.requestedTransport, 17 << 24)
            var allocate = STUNMessage(method: .allocate, class: .request, attributes: [transportAttribute, STUNMessage.text(.software, software)])
            var (response, rtt) = try await transaction(allocate, key: nil, over: channel, server: server, deadline: deadline)
            var key: Data?

            for _ in 0..<2 {
                guard response.messageClass == .error, let code = response.errorCode?.code, code == 401 || code == 438,
                      let realm = response.string(.realm), let nonce = response.attribute(.nonce)
                else { break }
                report["realm"] = .string(realm)
                guard let credentials else {
                    report["error"] = ["code": 401, "reason": "The server needs credentials; add them with @auth basic"]
                    return Outcome(statusCode: 401, report: .object(report))
                }
                key = STUNMessage.longTermKey(username: credentials.username, realm: realm, password: credentials.password)
                allocate = STUNMessage(method: .allocate, class: .request, attributes: [
                    transportAttribute,
                    STUNMessage.text(.username, credentials.username),
                    STUNMessage.text(.realm, realm),
                    STUNMessage.Attribute(.nonce, nonce),
                    STUNMessage.text(.software, software),
                ])
                (response, rtt) = try await transaction(allocate, key: key, over: channel, server: server, deadline: deadline)
                report["authenticated"] = .bool(response.messageClass == .success)
            }
            report["rtt"] = .number(rtt)
            let outcome = finish(response, report: &report)

            // Give the relay back rather than leaving it until it expires.
            if response.messageClass == .success, let key, let realm = report["realm"]?.stringValue,
               let nonce = allocate.attribute(.nonce), let credentials
            {
                let release = STUNMessage(method: .refresh, class: .request, attributes: [
                    STUNMessage.uint32(.lifetime, 0),
                    STUNMessage.text(.username, credentials.username),
                    STUNMessage.text(.realm, realm),
                    STUNMessage.Attribute(.nonce, nonce),
                ])
                _ = try? await transaction(release, key: key, over: channel, server: server, deadline: Date().addingTimeInterval(1))
            }
            return outcome
        }
    }

    static let software = "Stampdrill"

    private static func finish(_ response: STUNMessage, report: inout ObjectValue) -> Outcome {
        func object(_ address: STUNMessage.Address) -> Value {
            ["address": .string(address.ip), "port": .number(Double(address.port)), "family": .string(address.isIPv6 ? "IPv6" : "IPv4")]
        }
        if let software = response.string(.software) { report["software"] = .string(software) }

        guard response.messageClass == .success else {
            let error = response.errorCode ?? (400, "Error response without a code")
            report["error"] = ["code": .number(Double(error.code)), "reason": .string(error.reason)]
            return Outcome(statusCode: error.code, report: .object(report))
        }
        if let mapped = response.mappedAddress {
            report["mapped"] = object(mapped)
            if let local = report["local"]?.stringValue {
                report["behindNAT"] = .bool(!local.hasPrefix(mapped.isIPv6 ? "[\(mapped.ip)]" : mapped.ip + ":"))
            }
        }
        if let relayed = response.relayedAddress { report["relayed"] = object(relayed) }
        if let lifetime = response.lifetime { report["lifetime"] = .number(Double(lifetime)) }
        return Outcome(statusCode: 200, report: .object(report))
    }

    /// Sends a request and waits for its answer, retransmitting over UDP.
    private static func transaction(
        _ request: STUNMessage, key: Data?, over channel: any ICEChannel, server: ICEServer, deadline: Date
    ) async throws -> (STUNMessage, Double) {
        let data = request.encoded(integrityKey: key)
        let started = Date()
        var interval: TimeInterval = 0.5

        while true {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let sentAt = Date()
            try await channel.send(data)
            let wait = channel.isReliable ? remaining : min(interval, remaining)
            let waitUntil = Date().addingTimeInterval(wait)

            while waitUntil.timeIntervalSinceNow > 0 {
                guard let raw = try await channel.receive(timeout: waitUntil.timeIntervalSinceNow) else { break }
                guard let response = try? STUNMessage(decoding: raw), response.transactionID == request.transactionID else { continue }
                let rtt = (Date().timeIntervalSince(channel.isReliable ? started : sentAt) * 1000).rounded()
                return (response, rtt)
            }
            interval *= 2
        }
        throw TransportError(message: "no answer from \(server.address) within \(formatTimeout(deadline.timeIntervalSince(started)))")
    }

    private static func formatTimeout(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : "\(Int(seconds.rounded())) s"
    }
}
