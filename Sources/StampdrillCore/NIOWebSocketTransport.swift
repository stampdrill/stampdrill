#if canImport(FoundationNetworking)
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import WebSocketKit

/// WebSockets through SwiftNIO, for platforms where URLSession has none.
public final class NIOWebSocketTransport: WebSocketTransport {
    public init() {}

    public func connect(_ request: ResolvedRequest) async throws -> any WebSocketConnection {
        var headers = HTTPHeaders()
        for header in request.headers { headers.add(name: header.name, value: header.value) }
        var tls = TLSConfiguration.makeClientConfiguration()
        if request.allowsInsecureConnections { tls.certificateVerification = .none }

        let connection = Connection()
        do {
            try await WebSocket.connect(
                to: request.url.absoluteString, headers: headers,
                configuration: WebSocketClient.Configuration(tlsConfiguration: tls, maxFrameSize: 1 << 24),
                on: MultiThreadedEventLoopGroup.singleton
            ) { socket in
                connection.attach(socket)
            }.get()
        } catch {
            throw TransportError(message: "could not connect to \(request.url.host ?? "the server"): \(error)")
        }
        return connection
    }

    final class Connection: WebSocketConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var socket: WebSocket?
        private let inbox = Inbox<String>()

        /// Called on the event loop as soon as the upgrade completes, before any frame arrives.
        func attach(_ socket: WebSocket) {
            lock.withLock { self.socket = socket }
            let inbox = inbox
            socket.onText { _, text in
                Task { await inbox.push(text) }
            }
            socket.onBinary { _, buffer in
                let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
                Task { await inbox.push(text) }
            }
            socket.onClose.whenComplete { _ in
                Task { await inbox.finish() }
            }
        }

        func send(_ text: String) async throws {
            guard let socket = lock.withLock({ self.socket }) else { throw TransportError(message: "the socket isn't open") }
            do {
                try await socket.send(text)
            } catch {
                throw TransportError(message: "could not send: \(error)")
            }
        }

        func receive(timeout: TimeInterval) async throws -> String? {
            await inbox.next(timeout: timeout)
        }

        func close() async {
            if let socket = lock.withLock({ self.socket }) {
                try? await socket.close()
            }
            await inbox.finish()
        }
    }
}
#endif
