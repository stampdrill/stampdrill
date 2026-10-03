import Foundation
import Testing
@testable import StampdrillCore
@testable import Stamp

struct STUNMessageTests {
    private func bytes(_ hex: String) -> Data {
        let digits = hex.filter(\.isHexDigit)
        return Data(stride(from: 0, to: digits.count, by: 2).map {
            let start = digits.index(digits.startIndex, offsetBy: $0)
            return UInt8(digits[start ..< digits.index(start, offsetBy: 2)], radix: 16)!
        })
    }

    /// RFC 5769, 2.2: an IPv4 Binding response.
    @Test func decodesTheRFCSampleResponse() throws {
        let transactionID = bytes("b7 e7 a7 01 bc 34 d6 86 fa 87 df ae")
        let response = STUNMessage(method: .binding, class: .success, transactionID: transactionID, attributes: [
            STUNMessage.Attribute(.xorMappedAddress, bytes("00 01 a1 47 e1 12 a6 43")),
        ])
        let decoded = try STUNMessage(decoding: response.encoded())
        #expect(decoded.method == .binding)
        #expect(decoded.messageClass == .success)
        #expect(decoded.mappedAddress == STUNMessage.Address(ip: "192.0.2.1", port: 32853, isIPv6: false))
    }

    /// RFC 5769, 2.3: the same response over IPv6.
    @Test func decodesIPv6Addresses() throws {
        let transactionID = bytes("b7 e7 a7 01 bc 34 d6 86 fa 87 df ae")
        let response = STUNMessage(method: .binding, class: .success, transactionID: transactionID, attributes: [
            STUNMessage.Attribute(.xorMappedAddress, bytes("00 02 a1 47 01 13 a9 fa a5 d3 f1 79 bc 25 f4 b5 be d2 b9 d9")),
        ])
        let decoded = try STUNMessage(decoding: response.encoded())
        #expect(decoded.mappedAddress?.ip == "2001:db8:1234:5678:11:2233:4455:6677")
        #expect(decoded.mappedAddress?.port == 32853)
    }

    @Test func signsAndChecksIntegrity() throws {
        let key = STUNMessage.longTermKey(username: "alice", realm: "example.org", password: "secret")
        let message = STUNMessage(method: .allocate, class: .request, attributes: [
            STUNMessage.text(.username, "alice"), STUNMessage.text(.realm, "example.org"),
        ])
        let wire = message.encoded(integrityKey: key)
        #expect(wire.count % 4 == 0)
        #expect(STUNMessage.hasValidIntegrity(wire, key: key))
        #expect(!STUNMessage.hasValidIntegrity(wire, key: STUNMessage.longTermKey(username: "alice", realm: "example.org", password: "wrong")))
        let decoded = try STUNMessage(decoding: wire)
        #expect(decoded.string(.username) == "alice")
    }

    @Test func readsErrorCodes() throws {
        let message = STUNMessage(method: .allocate, class: .error, attributes: [STUNMessage.errorCode(438, "Stale Nonce")])
        let decoded = try STUNMessage(decoding: message.encoded())
        #expect(decoded.errorCode?.code == 438)
        #expect(decoded.errorCode?.reason == "Stale Nonce")
    }

    @Test func rejectsOtherTraffic() {
        let decoded = try? STUNMessage(decoding: Data("GET / HTTP/1.1\r\n\r\n".utf8))
        #expect(decoded == nil)
    }

    @Test func readsServerURLs() {
        #expect(ICEServer("stun:stun.l.google.com:19302", kind: .stun) == ICEServer(kind: .stun, host: "stun.l.google.com", port: 19302))
        #expect(ICEServer("turns:turn.example.com", kind: .stun) == ICEServer(kind: .turn, host: "turn.example.com", port: 5349, transport: .tls))
        #expect(ICEServer("turn:turn.example.com?transport=tcp", kind: .turn)?.transport == .tcp)
        #expect(ICEServer("[2001:db8::1]:3479", kind: .stun)?.host == "2001:db8::1")
        #expect(ICEServer("stun://stun.example.com:3478", kind: .stun)?.port == 3478)
        #expect(ICEServer("stun:example.com:http", kind: .stun) == nil)
    }
}

/// A TURN server in memory that insists on long-term credentials.
final class FakeTURNServer: ICETransport, ICEChannel, @unchecked Sendable {
    let username = "alice"
    let password = "wonderland"
    let realm = "turn.example.com"
    private let lock = NSLock()
    private var outbox: [Data] = []
    private(set) var released = false
    private(set) var received: [STUNMessage] = []

    var isReliable: Bool { true }
    var localAddress: String? { get async { "10.0.0.2:50000" } }

    func open(_ server: ICEServer, timeout: TimeInterval, allowsInsecureConnections: Bool) async throws -> any ICEChannel {
        self
    }

    func send(_ data: Data) async throws {
        let request = try STUNMessage(decoding: data)
        let key = STUNMessage.longTermKey(username: username, realm: realm, password: password)
        var response: STUNMessage
        switch request.method {
        case .binding:
            response = STUNMessage(method: .binding, class: .success, transactionID: request.transactionID, attributes: [
                STUNMessage.address(.xorMappedAddress, ip: "203.0.113.7", port: 40000, transactionID: request.transactionID),
            ])
        case .allocate where request.attribute(.messageIntegrity) == nil:
            response = STUNMessage(method: .allocate, class: .error, transactionID: request.transactionID, attributes: [
                STUNMessage.errorCode(401, "Unauthorized"), STUNMessage.text(.realm, realm), STUNMessage.text(.nonce, "n0nce"),
            ])
        case .allocate where !STUNMessage.hasValidIntegrity(data, key: key):
            response = STUNMessage(method: .allocate, class: .error, transactionID: request.transactionID, attributes: [
                STUNMessage.errorCode(401, "Unauthorized"), STUNMessage.text(.realm, realm), STUNMessage.text(.nonce, "n0nce"),
            ])
        case .allocate:
            response = STUNMessage(method: .allocate, class: .success, transactionID: request.transactionID, attributes: [
                STUNMessage.address(.xorRelayedAddress, ip: "198.51.100.20", port: 49152, transactionID: request.transactionID),
                STUNMessage.address(.xorMappedAddress, ip: "203.0.113.7", port: 40000, transactionID: request.transactionID),
                STUNMessage.uint32(.lifetime, 600),
            ])
        case .refresh:
            lock.withLock { released = request.lifetime == 0 && STUNMessage.hasValidIntegrity(data, key: key) }
            response = STUNMessage(method: .refresh, class: .success, transactionID: request.transactionID)
        }
        let wire = response.encoded()
        lock.withLock {
            received.append(request)
            outbox.append(wire)
        }
    }

    func receive(timeout: TimeInterval) async throws -> Data? {
        lock.withLock { outbox.isEmpty ? nil : outbox.removeFirst() }
    }

    func close() async {}
}

struct ICERunnerTests {
    private func run(_ source: String, ice: FakeTURNServer) async -> RunResult? {
        let workspace = makeWorkspace(["webrtc.stamp": source])
        let runner = Runner(workspace: workspace, transport: StubTransport { _ in (500, [:], "") }, ice: ice)
        let name = Document.parse(source).requests.first?.name ?? ""
        return await runner.run(RequestReference(path: "webrtc.stamp", name: name)).last
    }

    @Test func checksAStunServer() async throws {
        let result = try #require(await run("""
        ### Public address
        stun:stun.example.com:19302

        > assert status == 200
        > assert body.mapped.address == "203.0.113.7"
        > assert body.behindNAT
        """, ice: FakeTURNServer()))
        #expect(result.error == nil)
        #expect(result.request?.method == "STUN")
        #expect(result.assertions.filter { !$0.passed }.isEmpty)
    }

    @Test func allocatesAndReleasesARelay() async throws {
        let server = FakeTURNServer()
        let result = try #require(await run("""
        ### Relay
        @auth basic alice wonderland
        TURN turn:turn.example.com:3478?transport=tcp

        > assert status == 200
        > assert body.relayed.port == 49152
        > assert body.authenticated
        > assert body.lifetime == 600
        """, ice: server))
        #expect(result.error == nil)
        #expect(result.assertions.filter { !$0.passed }.isEmpty)
        #expect(server.received.map(\.method) == [.allocate, .allocate, .refresh])
        #expect(server.released)
    }

    @Test func reportsRejectedCredentials() async throws {
        let result = try #require(await run("""
        ### Relay
        @auth basic alice nope
        TURN turn:turn.example.com

        > assert status == 401
        """, ice: FakeTURNServer()))
        #expect(result.response?.statusCode == 401)
        #expect(result.assertions.first?.passed == true)
    }
}
