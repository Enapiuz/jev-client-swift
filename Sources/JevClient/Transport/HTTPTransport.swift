import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A raw HTTP response. Header lookup is case insensitive as required by HTTP.
public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// An injectable, cancellation-aware HTTP boundary.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// URLSession transport that refuses redirects through session and task delegates.
///
/// The default initializer owns an ephemeral session with cookies and caching disabled.
/// A supplied configuration is copied by URLSession at creation; configure it before
/// passing it here, and do not mutate it concurrently. This transport always owns and
/// invalidates its session when released. A caller-supplied transport should cooperate
/// with task cancellation for overall request deadlines to finish.
public final class URLSessionTransport: HTTPTransport, Sendable {
    private let session: URLSession
    private let redirectDelegate: RedirectRejectingDelegate

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = RedirectRejectingDelegate()
        self.redirectDelegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public init(configuration: URLSessionConfiguration) {
        let delegate = RedirectRejectingDelegate()
        self.redirectDelegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (body, response) = try await session.data(
            for: request,
            delegate: redirectDelegate
        )
        guard let response = response as? HTTPURLResponse else {
            throw JevError.transport(underlying: NonHTTPResponseError())
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String {
                headers[key] = String(describing: value)
            }
        }
        return HTTPResponse(statusCode: response.statusCode, headers: headers, body: body)
    }
}

private struct NonHTTPResponseError: Error {}

private final class RedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
