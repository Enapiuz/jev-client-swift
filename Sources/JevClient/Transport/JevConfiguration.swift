import Foundation

/// Authentication is resolved for every attempt so an asynchronous provider can rotate tokens.
public enum JevAuthentication: Sendable {
    case apiKey(String)
    case bearerToken(@Sendable () async throws -> String)
    /// Lets a caller-controlled proxy supply its own Authorization header.
    case none
}

public struct RetryPolicy: Sendable, Equatable {
    public var maxRetries: Int
    public var initialDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var jitter: Double
    public var statusCodes: Set<Int>
    public var respectRetryAfter: Bool
    public var maxRetryAfter: TimeInterval
    public var retryConnectionErrors: Bool
    public var retryTimeouts: Bool

    public init(
        maxRetries: Int = 2,
        initialDelay: TimeInterval = 0.5,
        maxDelay: TimeInterval = 5,
        jitter: Double = 0.25,
        statusCodes: Set<Int> = Set([408, 429] + Array(500...599)),
        respectRetryAfter: Bool = true,
        maxRetryAfter: TimeInterval = 60,
        retryConnectionErrors: Bool = true,
        retryTimeouts: Bool = true
    ) {
        self.maxRetries = maxRetries
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
        self.statusCodes = statusCodes
        self.respectRetryAfter = respectRetryAfter
        self.maxRetryAfter = maxRetryAfter
        self.retryConnectionErrors = retryConnectionErrors
        self.retryTimeouts = retryTimeouts
    }

    public static let `default` = RetryPolicy()
    public static let disabled = RetryPolicy(maxRetries: 0)

    func validate() throws {
        guard (0...1_000).contains(maxRetries) else {
            throw JevError.configuration("maxRetries must be between 0 and 1000")
        }
        guard initialDelay.isFinite, initialDelay >= 0,
              maxDelay.isFinite, maxDelay >= 0,
              jitter.isFinite, (0...1).contains(jitter),
              maxRetryAfter.isFinite, maxRetryAfter >= 0 else {
            throw JevError.configuration("Retry delays and jitter are invalid")
        }
        guard statusCodes.allSatisfy({ (100...599).contains($0) }) else {
            throw JevError.configuration("Retry status codes must be valid HTTP statuses")
        }
    }
}

public struct JevConfiguration: Sendable {
    public var authentication: JevAuthentication
    public var baseURL: URL
    public var model: JevModel
    public var headers: [String: String]
    /// Per-attempt URLRequest timeout, in seconds.
    public var requestTimeout: TimeInterval
    /// Full operation timeout, including token providers and retry delays. Set nil to disable.
    public var totalTimeout: TimeInterval?
    public var retryPolicy: RetryPolicy
    /// Synchronous, Sendable, redacted lifecycle observations.
    public var observer: (@Sendable (JevEvent) -> Void)?

    public init(
        authentication: JevAuthentication,
        baseURL: URL = URL(string: "https://api.typesafe.ai")!,
        model: JevModel = .latest,
        headers: [String: String] = [:],
        requestTimeout: TimeInterval = 30,
        totalTimeout: TimeInterval? = 90,
        retryPolicy: RetryPolicy = .default,
        observer: (@Sendable (JevEvent) -> Void)? = nil
    ) {
        self.authentication = authentication
        self.baseURL = baseURL
        self.model = model
        self.headers = headers
        self.requestTimeout = requestTimeout
        self.totalTimeout = totalTimeout
        self.retryPolicy = retryPolicy
        self.observer = observer
    }

    public func validate() throws {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw JevError.configuration("baseURL must be an HTTP URL without credentials, query, or fragment")
        }
        try validateTimeout(requestTimeout, name: "requestTimeout")
        if let totalTimeout {
            try validateTimeout(totalTimeout, name: "totalTimeout")
        }
        try retryPolicy.validate()
        try validateHeaders(headers)
    }
}

public struct RequestOptions: Sendable {
    public var headers: [String: String]
    public var requestTimeout: TimeInterval?
    public var totalTimeout: TimeInterval?
    public var retryPolicy: RetryPolicy?

    /// Nil values inherit configuration; disable the overall deadline on the configuration.
    public init(
        headers: [String: String] = [:],
        requestTimeout: TimeInterval? = nil,
        totalTimeout: TimeInterval? = nil,
        retryPolicy: RetryPolicy? = nil
    ) {
        self.headers = headers
        self.requestTimeout = requestTimeout
        self.totalTimeout = totalTimeout
        self.retryPolicy = retryPolicy
    }

    func validate() throws {
        try validateHeaders(headers)
        if let requestTimeout {
            try validateTimeout(requestTimeout, name: "requestTimeout")
        }
        if let totalTimeout {
            try validateTimeout(totalTimeout, name: "totalTimeout")
        }
        try retryPolicy?.validate()
    }
}

private func validateTimeout(_ interval: TimeInterval, name: String) throws {
    guard interval.isFinite, interval > 0 else {
        throw JevError.configuration("\(name) must be finite and positive")
    }
}

private let validHeaderTokenBytes = Set("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)

private func validateHeaders(_ headers: [String: String]) throws {
    var seenNames = Set<String>()
    for (name, value) in headers {
        guard !name.isEmpty, name.utf8.allSatisfy(validHeaderTokenBytes.contains) else {
            throw JevError.configuration("Invalid HTTP header name")
        }
        let normalizedName = name.lowercased()
        guard seenNames.insert(normalizedName).inserted else {
            throw JevError.configuration("Duplicate HTTP header name")
        }
        guard normalizedName != "host", normalizedName != "content-length" else {
            throw JevError.configuration("Host and Content-Length headers are managed by the transport")
        }
        guard value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) else {
            throw JevError.configuration("HTTP header values cannot contain control characters")
        }
    }
}
