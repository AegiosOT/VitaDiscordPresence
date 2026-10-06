import Foundation

/// A minimal HTTP request. Artwork lookups only need GET (catalogs, store search) and HEAD (probing that an
/// image URL answers with an image before handing it to Discord).
public struct HTTPRequest: Sendable, Hashable {
    public enum Method: String, Sendable, Hashable {
        case get = "GET"
        case head = "HEAD"
    }

    public var method: Method
    public var url: URL
    public var timeout: Duration

    public init(_ method: Method, _ url: URL, timeout: Duration = .seconds(10)) {
        self.method = method
        self.url = url
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// The media type without parameters, lowercased: `image/jpeg` for `image/jpeg;charset=UTF-8`.
    public var mediaType: String? {
        headers["content-type"]?.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
    }

    /// `true` when asking again later would most likely get the same answer: any status below 500 except
    /// 408 (request timeout) and 429 (too many requests).
    var isDefinitive: Bool {
        status < 500 && status != 408 && status != 429
    }
}

/// Sends HTTP requests. `URLSessionHTTPClient` is the real implementation; tests substitute fakes.
public protocol HTTPClient: Sendable {
    /// Sends `request` and returns the response, whatever its status. Throws only for transport failures
    /// (offline, timeout, TLS) and cancellation.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// `HTTPClient` on an ephemeral `URLSession`: no cookies, no cache, no credentials, and a user agent that
/// names the app.
///
/// GET follows redirects. HEAD returns a redirect as it is, so a probe sees what an image proxy fetching the
/// URL gets first. A request fails with `URLError(.timedOut)` once `HTTPRequest.timeout` passes without
/// data (and after two minutes in any case), and with `CancellationError` when the calling task is cancelled.
public struct URLSessionHTTPClient: HTTPClient {
    /// Sent with every request.
    static let userAgent = "VitaPresence/2.0 (+https://github.com/AegiosOT/VitaDiscordPresence)"

    /// One session for every client. It has no delegate, so it never needs invalidating.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    public init() {}

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let scheme = request.url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw URLError(.unsupportedURL)
        }
        try Task.checkCancellation()
        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: max(request.timeout.timeInterval, 0.001)
        )
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let delegate = request.method == .head ? RefuseRedirects() : nil
        let body: Data
        let response: URLResponse
        do {
            (body, response) = try await Self.session.data(for: urlRequest, delegate: delegate)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for case let (name as String, value as String) in response.allHeaderFields {
            headers[name.lowercased()] = value
        }
        return HTTPResponse(status: response.statusCode, headers: headers, body: body)
    }
}

/// Declines every redirect, so the task completes with the 3xx response itself.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
