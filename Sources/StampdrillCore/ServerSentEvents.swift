import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ServerSentEvent: Hashable, Sendable {
    public var event: String
    public var data: String
    public var id: String?

    public init(event: String = "message", data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Reads a `text/event-stream` one line at a time (lines without their line break).
public struct ServerSentEventParser: Sendable {
    private var event = ""
    private var data: [String] = []
    private var id: String?

    public init() {}

    /// Returns an event when `line` completes one.
    public mutating func feed(_ line: String) -> ServerSentEvent? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": data.append(String(value))
        case "id": id = String(value)
        default: break
        }
        return nil
    }

    /// An event left unfinished when the stream ends.
    public mutating func finish() -> ServerSentEvent? {
        dispatch()
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            event = ""
            data = []
        }
        guard !data.isEmpty else { return nil }
        return ServerSentEvent(event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"), id: id)
    }
}

/// A response whose body is read line by line as it arrives.
public struct StreamingResponse: Sendable {
    public var statusCode: Int
    public var headers: [HTTPField]
    public var lines: AsyncThrowingStream<String, Error>

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol StreamingHTTPTransport: Sendable {
    func open(_ request: ResolvedRequest) async throws -> StreamingResponse
}

/// Splits bytes into lines, keeping empty ones, which end events in an event stream.
struct LineSplitter {
    private var buffer: [UInt8] = []

    mutating func append(_ bytes: some Sequence<UInt8>, emit: (String) -> Void) {
        for byte in bytes {
            if byte == 0x0A {
                if buffer.last == 0x0D { buffer.removeLast() }
                emit(String(decoding: buffer, as: UTF8.self))
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(byte)
            }
        }
    }

    mutating func finish(emit: (String) -> Void) {
        if !buffer.isEmpty { emit(String(decoding: buffer, as: UTF8.self)) }
        buffer.removeAll()
    }
}

#if !os(Linux)
public final class URLSessionStreamingTransport: StreamingHTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func open(_ request: ResolvedRequest) async throws -> StreamingResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for header in request.headers { urlRequest.addValue(header.value, forHTTPHeaderField: header.name) }

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch {
            throw TransportError(message: "could not connect to \(request.url.host ?? "the server"): \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { throw TransportError(message: "the server did not send an HTTP response") }
        let headers = http.allHeaderFields.compactMap { key, value in (key as? String).map { HTTPField($0, "\(value)") } }

        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                var splitter = LineSplitter()
                var chunk: [UInt8] = []
                do {
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == 0x0A {
                            splitter.append(chunk) { continuation.yield($0) }
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    splitter.append(chunk) { continuation.yield($0) }
                    splitter.finish { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return StreamingResponse(statusCode: http.statusCode, headers: headers, lines: lines)
    }
}

public typealias PlatformStreamingTransport = URLSessionStreamingTransport
#endif
