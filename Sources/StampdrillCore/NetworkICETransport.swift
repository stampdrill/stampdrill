import Foundation

#if canImport(Network)
import Network

/// Talks to STUN and TURN servers over UDP, TCP or TLS with Network.framework.
public struct NetworkICETransport: ICETransport {
    public init() {}

    public func open(_ server: ICEServer, timeout: TimeInterval, allowsInsecureConnections: Bool) async throws -> any ICEChannel {
        let parameters: NWParameters
        switch server.transport {
        case .udp:
            parameters = .udp
        case .tcp:
            parameters = .tcp
        case .tls:
            let tls = NWProtocolTLS.Options()
            if allowsInsecureConnections {
                sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
            }
            parameters = NWParameters(tls: tls)
        }
        guard let port = NWEndpoint.Port(rawValue: server.port) else { throw TransportError(message: "invalid port \(server.port)") }
        let connection = NWConnection(host: NWEndpoint.Host(server.host), port: port, using: parameters)
        let channel = NetworkICEChannel(connection: connection, isReliable: server.transport != .udp)
        try await channel.start(timeout: timeout, server: server)
        return channel
    }
}

final class NetworkICEChannel: ICEChannel, @unchecked Sendable {
    let connection: NWConnection
    let isReliable: Bool
    private let queue = DispatchQueue(label: "cc.siamand.stampdrill.ice")
    private let inbox = Inbox<Data>()
    /// Bytes read from a stream that don't make a whole message yet; only touched on `queue`.
    private var buffer = Data()

    init(connection: NWConnection, isReliable: Bool) {
        self.connection = connection
        self.isReliable = isReliable
    }

    var localAddress: String? {
        get async {
            guard case .hostPort(let host, let port)? = connection.currentPath?.localEndpoint else { return nil }
            var text = "\(host)"
            if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
            return text.contains(":") ? "[\(text)]:\(port)" : "\(text):\(port)"
        }
    }

    func start(timeout: TimeInterval, server: ICEServer) async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run {
                        self.readLoop()
                        continuation.resume()
                    }
                case .failed(let error), .waiting(let error):
                    once.run { continuation.resume(throwing: TransportError(message: "cannot reach \(server.address): \(error.localizedDescription)")) }
                case .cancelled:
                    once.run { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                once.run { continuation.resume(throwing: TransportError(message: "cannot reach \(server.address) within \(Int(timeout)) s")) }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func receive(timeout: TimeInterval) async throws -> Data? {
        await inbox.next(timeout: timeout)
    }

    /// Reads for as long as the connection lives, so an answer that arrives
    /// after a receive gave up is still there for the next one.
    private func readLoop() {
        let handler: @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                var messages: [Data] = []
                if isReliable {
                    buffer.append(data)
                    while let length = STUNMessage.length(ofMessageIn: buffer), buffer.count >= length {
                        messages.append(Data(buffer.prefix(length)))
                        buffer.removeFirst(length)
                    }
                } else {
                    messages = [data]
                }
                let inbox = inbox
                Task { for message in messages { await inbox.push(message) } }
            }
            if error != nil || (isComplete && isReliable) {
                Task { await inbox.finish() }
            } else {
                readLoop()
            }
        }
        if isReliable {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536, completion: handler)
        } else {
            connection.receiveMessage(completion: handler)
        }
    }

    func close() async {
        connection.cancel()
        await inbox.finish()
    }
}

/// Runs a closure the first time only; continuations must resume exactly once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        body()
    }
}

#else

/// STUN and TURN checks use Network.framework, which only Apple platforms have.
public struct NetworkICETransport: ICETransport {
    public init() {}

    public func open(_ server: ICEServer, timeout: TimeInterval, allowsInsecureConnections: Bool) async throws -> any ICEChannel {
        throw TransportError(message: "STUN and TURN checks are only available on macOS")
    }
}

#endif
