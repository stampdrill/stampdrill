#if os(Linux)
import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import NIOSSL

/// Sends requests with AsyncHTTPClient, which verifies certificates with the
/// operating system's trust store even in fully static builds.
public final class AsyncHTTPClientTransport: HTTPTransport, @unchecked Sendable {
    public let userAgent: String
    private let cookies = CookieJar()
    private let lock = NSLock()
    private var clients: [String: HTTPClient] = [:]

    public init(userAgent: String = "Stampdrill") {
        self.userAgent = userAgent
    }

    deinit {
        for client in clients.values { try? client.syncShutdown() }
    }

    /// Redirect and certificate settings belong to a client, so there is one per combination.
    private func client(followsRedirects: Bool, insecure: Bool) -> HTTPClient {
        let key = "\(followsRedirects)-\(insecure)"
        return lock.withLock {
            if let client = clients[key] { return client }
            var configuration = HTTPClient.Configuration()
            configuration.redirectConfiguration = followsRedirects ? .follow(max: 20, allowCycles: false) : .disallow
            configuration.decompression = .enabled(limit: .none)
            if insecure {
                var tls = TLSConfiguration.makeClientConfiguration()
                tls.certificateVerification = .none
                configuration.tlsConfiguration = tls
            }
            let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
            clients[key] = client
            return client
        }
    }

    public func send(_ request: ResolvedRequest) async throws -> HTTPResponse {
        var outgoing = HTTPClientRequest(url: request.url.absoluteString)
        outgoing.method = HTTPMethod(rawValue: request.method)
        for header in request.headers { outgoing.headers.add(name: header.name, value: header.value) }
        if request.header("User-Agent") == nil { outgoing.headers.replaceOrAdd(name: "User-Agent", value: userAgent) }
        if request.header("Cookie") == nil, let cookie = cookies.header(for: request.url) {
            outgoing.headers.add(name: "Cookie", value: cookie)
        }
        if let body = request.body { outgoing.body = .bytes(ByteBuffer(bytes: body)) }

        let clock = ContinuousClock()
        let start = clock.now
        let response: HTTPClientResponse
        let body: ByteBuffer
        do {
            response = try await client(followsRedirects: request.followsRedirects, insecure: request.allowsInsecureConnections)
                .execute(outgoing, timeout: .milliseconds(Int64(request.timeout * 1000)))
            body = try await response.body.collect(upTo: 512 * 1024 * 1024)
        } catch {
            throw TransportError(message: Self.describe(error, for: request))
        }
        let elapsed = clock.now - start

        cookies.store(response.headers["Set-Cookie"], from: request.url)
        let headers = response.headers
            .map { HTTPField($0.name, $0.value) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        return HTTPResponse(
            url: request.url,
            statusCode: Int(response.status.code),
            headers: headers,
            body: Data(body.readableBytesView),
            duration: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        )
    }

    private static func describe(_ error: Error, for request: ResolvedRequest) -> String {
        let host = request.url.host ?? "the server"
        if let error = error as? HTTPClientError {
            switch error {
            case .deadlineExceeded, .readTimeout, .connectTimeout: return "timed out after \(Int(request.timeout))s"
            case .cancelled: return "cancelled"
            default: return "\(error)"
            }
        }
        if error is NIOSSLError || "\(error)".contains("CERTIFICATE_VERIFY_FAILED") {
            return "the server certificate is not trusted; add '@insecure' to the request to skip verification"
        }
        if "\(error)".contains("connectionRefused") || "\(error)".contains("Connection refused") {
            return "could not connect to \(host)"
        }
        return "\(error)"
    }
}

/// Cookies set by servers during one run, sent back to matching hosts and paths.
final class CookieJar: @unchecked Sendable {
    private struct Cookie {
        var name: String
        var value: String
        var domain: String
        var hostOnly: Bool
        var path: String
        var expires: Date?
        var secure: Bool
    }

    private let lock = NSLock()
    private var cookies: [Cookie] = []

    func store(_ headers: [String], from url: URL) {
        guard let host = url.host?.lowercased() else { return }
        lock.withLock {
            for header in headers {
                let parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let pair = parts.first, let equals = pair.firstIndex(of: "=") else { continue }
                var cookie = Cookie(
                    name: String(pair[..<equals]), value: String(pair[pair.index(after: equals)...]),
                    domain: host, hostOnly: true, path: "/", expires: nil, secure: false
                )
                for attribute in parts.dropFirst() {
                    let name = attribute.prefix { $0 != "=" }.lowercased()
                    let value = attribute.contains("=") ? String(attribute[attribute.index(after: attribute.firstIndex(of: "=")!)...]) : ""
                    switch name {
                    case "domain" where !value.isEmpty:
                        cookie.domain = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        cookie.hostOnly = false
                    case "path" where value.hasPrefix("/"): cookie.path = value
                    case "max-age": cookie.expires = Double(value).map { Date().addingTimeInterval($0) }
                    case "secure": cookie.secure = true
                    default: break
                    }
                }
                cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
                if cookie.expires.map({ $0 > Date() }) ?? true { cookies.append(cookie) }
            }
        }
    }

    func header(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        let now = Date()
        let matching = lock.withLock {
            cookies.filter { cookie in
                (cookie.hostOnly ? host == cookie.domain : host == cookie.domain || host.hasSuffix("." + cookie.domain))
                    && path.hasPrefix(cookie.path)
                    && (!cookie.secure || url.scheme == "https")
                    && (cookie.expires.map { $0 > now } ?? true)
            }
        }
        return matching.isEmpty ? nil : matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}
#endif

#if os(Linux)
/// Event streams and other long responses, read as they arrive.
public final class AsyncHTTPClientStreamingTransport: StreamingHTTPTransport, @unchecked Sendable {
    private let client = HTTPClient(eventLoopGroupProvider: .singleton)

    public init() {}

    deinit {
        try? client.syncShutdown()
    }

    public func open(_ request: ResolvedRequest) async throws -> StreamingResponse {
        var outgoing = HTTPClientRequest(url: request.url.absoluteString)
        outgoing.method = HTTPMethod(rawValue: request.method)
        for header in request.headers { outgoing.headers.add(name: header.name, value: header.value) }
        if let body = request.body { outgoing.body = .bytes(ByteBuffer(bytes: body)) }

        let response: HTTPClientResponse
        do {
            response = try await client.execute(outgoing, timeout: .milliseconds(Int64(request.timeout * 1000)))
        } catch {
            throw TransportError(message: "could not connect to \(request.url.host ?? "the server"): \(error)")
        }
        let body = response.body
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                var splitter = LineSplitter()
                do {
                    for try await buffer in body {
                        splitter.append(buffer.readableBytesView) { continuation.yield($0) }
                    }
                    splitter.finish { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return StreamingResponse(
            statusCode: Int(response.status.code),
            headers: response.headers.map { HTTPField($0.name, $0.value) },
            lines: lines
        )
    }
}

public typealias PlatformStreamingTransport = AsyncHTTPClientStreamingTransport
#endif
