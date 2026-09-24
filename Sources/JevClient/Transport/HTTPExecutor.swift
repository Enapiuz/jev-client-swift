import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Runs one logical request, including authentication, retries, and an overall deadline.
/// Custom transports and token providers must cooperate with cancellation: structured
/// timeout racing waits for a cancelled child before it can return to the caller.
internal struct HTTPExecutor: Sendable {
    private let configuration: JevConfiguration
    private let transport: any HTTPTransport
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    internal init(
        configuration: JevConfiguration,
        transport: any HTTPTransport,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = sleepSeconds
    ) {
        self.configuration = configuration
        self.transport = transport
        self.sleep = sleep
    }

    internal func execute(
        method: String,
        path: String,
        body: Data?,
        options: RequestOptions
    ) async throws -> (HTTPResponse, ResponseMetadata) {
        try configuration.validate()
        try options.validate()
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              !path.contains("?"), !path.contains("#"),
              !path.utf8.contains(13), !path.utf8.contains(10) else {
            throw JevError.configuration("Request path must be an absolute path without a query or fragment")
        }
        guard !method.isEmpty, method.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }) else {
            throw JevError.configuration("Request method is invalid")
        }
        let policy = options.retryPolicy ?? configuration.retryPolicy
        let timeout = options.totalTimeout ?? configuration.totalTimeout
        if let timeout {
            return try await withThrowingTaskGroup(
                of: (HTTPResponse, ResponseMetadata).self
            ) { group in
                group.addTask {
                    try await executeAttempts(
                        method: method,
                        path: path,
                        body: body,
                        options: options,
                        policy: policy
                    )
                }
                group.addTask {
                    try await sleepSeconds(timeout)
                    throw JevError.timeout
                }
                do {
                    guard let result = try await group.next() else {
                        throw JevError.timeout
                    }
                    group.cancelAll()
                    try Task.checkCancellation()
                    return result
                } catch {
                    group.cancelAll()
                    try Task.checkCancellation()
                    throw error
                }
            }
        }
        return try await executeAttempts(
            method: method,
            path: path,
            body: body,
            options: options,
            policy: policy
        )
    }

    private func executeAttempts(
        method: String,
        path: String,
        body: Data?,
        options: RequestOptions,
        policy: RetryPolicy
    ) async throws -> (HTTPResponse, ResponseMetadata) {
        let perAttemptTimeout = options.requestTimeout ?? configuration.requestTimeout
        for attempt in 1...(policy.maxRetries + 1) {
            try Task.checkCancellation()
            configuration.observer?(.requestStarted(attempt: attempt, method: method, path: path))

            let request: URLRequest
            do {
                request = try await makeRequest(
                    method: method,
                    path: path,
                    body: body,
                    options: options,
                    timeout: perAttemptTimeout
                )
            } catch {
                configuration.observer?(.requestFailed(attempt: attempt, kind: "authentication"))
                try Task.checkCancellation()
                throw error
            }

            let response: HTTPResponse
            do {
                try Task.checkCancellation()
                response = try await transport.send(request)
                try Task.checkCancellation()
            } catch {
                if Task.isCancelled || error is CancellationError ||
                    (error as? URLError)?.code == .cancelled {
                    configuration.observer?(.requestFailed(attempt: attempt, kind: "cancelled"))
                    throw CancellationError()
                }
                if attempt <= policy.maxRetries, shouldRetryTransport(error, policy: policy) {
                    let delay = backoffDelay(for: attempt, policy: policy)
                    configuration.observer?(.retryScheduled(attempt: attempt, delay: delay))
                    try await sleep(delay)
                    continue
                }
                configuration.observer?(.requestFailed(attempt: attempt, kind: "transport"))
                if let error = error as? JevError { throw error }
                throw JevError.transport(underlying: error)
            }

            let requestID = response.header("x-typesafe-request-id")
            configuration.observer?(.responseReceived(
                attempt: attempt,
                statusCode: response.statusCode,
                requestID: requestID
            ))
            let metadata = ResponseMetadata(
                statusCode: response.statusCode,
                headers: response.headers,
                requestID: requestID,
                attempts: attempt
            )
            if (200...299).contains(response.statusCode) {
                return (response, metadata)
            }
            if attempt <= policy.maxRetries, policy.statusCodes.contains(response.statusCode),
               let delay = retryDelay(for: response, attempt: attempt, policy: policy) {
                configuration.observer?(.retryScheduled(attempt: attempt, delay: delay))
                try await sleep(delay)
                continue
            }
            configuration.observer?(.requestFailed(attempt: attempt, kind: "http"))
            throw JevError.http(JevHTTPError(
                statusCode: response.statusCode,
                headers: response.headers,
                body: response.body,
                requestID: requestID,
                attempts: attempt
            ))
        }
        // The loop always returns or throws on its final allowed attempt.
        throw JevError.configuration("No HTTP attempts were configured")
    }

    private func makeRequest(
        method: String,
        path: String,
        body: Data?,
        options: RequestOptions,
        timeout: TimeInterval
    ) async throws -> URLRequest {
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw JevError.configuration("Invalid baseURL")
        }
        let basePath = components.percentEncodedPath
        var prefix = basePath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        components.percentEncodedPath = prefix + path
        guard let url = components.url else {
            throw JevError.configuration("Invalid request URL")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body

        var headers: [String: String] = [:]
        for (name, value) in configuration.headers {
            setHeader(name, value: value, in: &headers)
        }
        for (name, value) in options.headers {
            setHeader(name, value: value, in: &headers)
        }
        // Protocol-owned values win regardless of caller header casing.
        setHeader("Accept", value: "application/json", in: &headers)
        setHeader("User-Agent", value: "JevClient/0.1.0", in: &headers)
        removeHeader("Content-Type", from: &headers)
        if body != nil {
            setHeader("Content-Type", value: "application/json", in: &headers)
        }
        switch configuration.authentication {
        case .none:
            break
        case .apiKey(let key):
            setHeader("Authorization", value: "Bearer \(try validateToken(key))", in: &headers)
        case .bearerToken(let provider):
            let token = try await provider()
            setHeader("Authorization", value: "Bearer \(try validateToken(token))", in: &headers)
        }
        try Task.checkCancellation()
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

private func validateToken(_ token: String) throws -> String {
    guard !token.isEmpty,
          token.utf8.allSatisfy({ $0 > 32 && $0 != 127 }) else {
        throw JevError.configuration("Authentication token must be nonempty and contain no control or whitespace bytes")
    }
    return token
}

private func setHeader(_ name: String, value: String, in headers: inout [String: String]) {
    removeHeader(name, from: &headers)
    headers[name] = value
}

private func removeHeader(_ name: String, from headers: inout [String: String]) {
    for key in headers.keys.filter({ $0.caseInsensitiveCompare(name) == .orderedSame }) {
        headers.removeValue(forKey: key)
    }
}

private func shouldRetryTransport(_ error: any Error, policy: RetryPolicy) -> Bool {
    guard let urlError = error as? URLError else { return false }
    switch urlError.code {
    case .timedOut:
        return policy.retryTimeouts
    case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
         .networkConnectionLost, .notConnectedToInternet:
        return policy.retryConnectionErrors
    default:
        return false
    }
}

private func retryDelay(
    for response: HTTPResponse,
    attempt: Int,
    policy: RetryPolicy
) -> TimeInterval? {
    if policy.respectRetryAfter, let serverDelay = serverRetryDelay(response) {
        // Never retry earlier than a valid server instruction, even when it is too long.
        return serverDelay <= policy.maxRetryAfter ? serverDelay : nil
    }
    return backoffDelay(for: attempt, policy: policy)
}

private func serverRetryDelay(_ response: HTTPResponse) -> TimeInterval? {
    if let milliseconds = response.header("retry-after-ms"),
       let value = nonnegativeDecimal(milliseconds.trimmingCharacters(in: .whitespaces)) {
        return value / 1_000
    }
    guard let header = response.header("retry-after")?.trimmingCharacters(in: .whitespaces) else {
        return nil
    }
    if !header.isEmpty, header.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
       let seconds = Double(header) {
        return seconds
    }
    if !header.isEmpty, header.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) {
        return .infinity
    }
    for format in [
        "EEE, dd MMM yyyy HH:mm:ss 'GMT'",
        "EEEE, dd-MMM-yy HH:mm:ss 'GMT'",
        "EEE MMM d HH:mm:ss yyyy",
    ] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = format
        if let date = formatter.date(from: header) {
            return max(0, date.timeIntervalSinceNow)
        }
    }
    return nil
}

private func nonnegativeDecimal(_ value: String) -> Double? {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count <= 2,
          parts.contains(where: { !$0.isEmpty }),
          parts.allSatisfy({ $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }) else {
        return nil
    }
    return Double(value) ?? .infinity
}

private func backoffDelay(for attempt: Int, policy: RetryPolicy) -> TimeInterval {
    let multiplier = pow(2, Double(attempt - 1))
    let capped = min(policy.maxDelay, policy.initialDelay * multiplier)
    return capped * (1 - Double.random(in: 0...policy.jitter))
}

private func sleepSeconds(_ seconds: TimeInterval) async throws {
    var remaining = seconds
    while remaining > 0 {
        try Task.checkCancellation()
        let chunk = min(remaining, 3_600)
        let nanoseconds = max(UInt64(1), UInt64((chunk * 1_000_000_000).rounded(.up)))
        try await Task.sleep(nanoseconds: nanoseconds)
        remaining -= chunk
    }
}
