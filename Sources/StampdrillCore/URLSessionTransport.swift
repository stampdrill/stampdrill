import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPTransport: Sendable {
    func send(_ request: ResolvedRequest) async throws -> HTTPResponse
}

public struct TransportError: Error, LocalizedError, Sendable {
    public var message: String

    public var errorDescription: String? { message }
}

#if os(Linux)
public typealias PlatformHTTPTransport = AsyncHTTPClientTransport
#else
public typealias PlatformHTTPTransport = URLSessionTransport
#endif

/// Sends requests with `URLSession`, one isolated session per transport so
/// cookies and connections don't leak between workspaces.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    #if canImport(FoundationNetworking)
    /// Linux's URLSession ignores per-request delegates, so requests that must not
    /// follow redirects go through a session whose own delegate refuses them.
    private let sessionWithoutRedirects: URLSession
    #endif
    public let userAgent: String

    public init(userAgent: String = "Stampdrill") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        session = URLSession(configuration: configuration)
        #if canImport(FoundationNetworking)
        sessionWithoutRedirects = URLSession(configuration: configuration, delegate: RedirectRefuser(), delegateQueue: nil)
        #endif
        self.userAgent = userAgent
    }

    deinit {
        session.invalidateAndCancel()
        #if canImport(FoundationNetworking)
        sessionWithoutRedirects.invalidateAndCancel()
        #endif
    }

    /// Cookies the servers set during this transport's life.
    public var cookies: [HTTPCookie] {
        session.configuration.httpCookieStorage?.cookies?.sorted { ($0.domain, $0.name) < ($1.domain, $1.name) } ?? []
    }

    public func deleteCookie(_ cookie: HTTPCookie) {
        session.configuration.httpCookieStorage?.deleteCookie(cookie)
    }

    public func deleteAllCookies() {
        for cookie in cookies { deleteCookie(cookie) }
    }

    public func send(_ request: ResolvedRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for header in request.headers {
            urlRequest.addValue(header.value, forHTTPHeaderField: header.name)
        }
        if request.header("User-Agent") == nil {
            urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        let delegate = TaskDelegate(
            followsRedirects: request.followsRedirects,
            allowsInsecureConnections: request.allowsInsecureConnections
        )
        let clock = ContinuousClock()
        let start = clock.now

        let (data, response): (Data, URLResponse)
        do {
            #if canImport(FoundationNetworking)
            _ = delegate
            (data, response) = try await (request.followsRedirects ? session : sessionWithoutRedirects).data(for: urlRequest)
            #else
            (data, response) = try await session.data(for: urlRequest, delegate: delegate)
            #endif
        } catch let error as URLError {
            throw TransportError(message: Self.describe(error, for: request))
        }

        let elapsed = clock.now - start
        guard let http = response as? HTTPURLResponse else {
            throw TransportError(message: "the server did not send an HTTP response")
        }

        let headers = http.allHeaderFields
            .compactMap { key, value in (key as? String).map { HTTPField($0, "\(value)") } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return HTTPResponse(
            url: http.url ?? request.url,
            statusCode: http.statusCode,
            headers: headers,
            body: data,
            duration: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        )
    }

    private static func describe(_ error: URLError, for request: ResolvedRequest) -> String {
        switch error.code {
        case .timedOut: "timed out after \(Int(request.timeout))s"
        case .cannotConnectToHost: "could not connect to \(request.url.host ?? "the server")"
        case .cannotFindHost, .dnsLookupFailed: "could not find host \(request.url.host ?? "")"
        case .notConnectedToInternet: "not connected to the internet"
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot:
            "the server certificate is not trusted; add '@insecure' to the request to skip verification"
        case .cancelled: "cancelled"
        default: error.localizedDescription
        }
    }
}

private final class TaskDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let followsRedirects: Bool
    let allowsInsecureConnections: Bool

    init(followsRedirects: Bool, allowsInsecureConnections: Bool) {
        self.followsRedirects = followsRedirects
        self.allowsInsecureConnections = allowsInsecureConnections
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        followsRedirects ? request : nil
    }

    #if canImport(Security)
    // Linux's Foundation can't override certificate checks, so @insecure only works on Apple platforms.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard allowsInsecureConnections,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
    #endif
}

#if canImport(FoundationNetworking)
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
#endif
