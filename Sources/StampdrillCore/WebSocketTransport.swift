import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SocketMessage: Hashable, Sendable, Identifiable {
    public enum Direction: String, Sendable {
        case sent
        case received
        case event
    }

    public let id = UUID()
    public var direction: Direction
    public var text: String
    /// Seconds since the connection opened.
    public var offset: TimeInterval
}

extension SocketMessage {
    /// A message or log line of an MCP session.
    public init(_ record: MCPClient.Record) {
        let direction: Direction = switch record.direction {
        case .sent: .sent
        case .received: .received
        case .log: .event
        }
        self.init(direction: direction, text: record.text, offset: record.offset)
    }
}

public protocol WebSocketConnection: Sendable {
    func send(_ text: String) async throws
    /// The next message, or nil when none arrives in time or the socket closed.
    func receive(timeout: TimeInterval) async throws -> String?
    func close() async
}

public protocol WebSocketTransport: Sendable {
    func connect(_ request: ResolvedRequest) async throws -> any WebSocketConnection
}

#if canImport(FoundationNetworking)
/// URLSession's WebSockets need a libcurl built with them, which Linux distributions rarely ship.
public typealias PlatformWebSocketTransport = NIOWebSocketTransport
#else
public typealias PlatformWebSocketTransport = URLSessionWebSocketTransport
#endif

public final class URLSessionWebSocketTransport: WebSocketTransport {
    private let session: URLSession

    public init() {
        session = URLSession(configuration: .ephemeral)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func connect(_ request: ResolvedRequest) async throws -> any WebSocketConnection {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        for header in request.headers {
            urlRequest.addValue(header.value, forHTTPHeaderField: header.name)
        }
        let task = session.webSocketTask(with: urlRequest)
        let connection = Connection(task: task)
        task.resume()
        connection.startReceiving()
        return connection
    }

    final class Connection: WebSocketConnection, @unchecked Sendable {
        let task: URLSessionWebSocketTask
        let inbox = Inbox<String>()

        init(task: URLSessionWebSocketTask) {
            self.task = task
        }

        func startReceiving() {
            Task { [task, inbox] in
                while true {
                    do {
                        switch try await task.receive() {
                        case .string(let text): await inbox.push(text)
                        case .data(let data): await inbox.push(String(decoding: data, as: UTF8.self))
                        @unknown default: break
                        }
                    } catch {
                        await inbox.finish()
                        return
                    }
                }
            }
        }

        func send(_ text: String) async throws {
            do {
                try await task.send(.string(text))
            } catch {
                throw TransportError(message: "could not send: \(error.localizedDescription)")
            }
        }

        func receive(timeout: TimeInterval) async throws -> String? {
            await inbox.next(timeout: timeout)
        }

        func close() async {
            task.cancel(with: .normalClosure, reason: nil)
            await inbox.finish()
        }
    }
}
