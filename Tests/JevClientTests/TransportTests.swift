import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import JevClient

private let ok = HTTPResponse(statusCode: 200, headers: [:], body: Data("ok".utf8))

private actor RecordingTransport: HTTPTransport {
    private var requests: [URLRequest] = []
    private let handler: @Sendable (URLRequest, Int) async throws -> HTTPResponse

    init(handler: @escaping @Sendable (URLRequest, Int) async throws -> HTTPResponse = { _, _ in ok }) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try await handler(request, requests.count)
    }

    func recorded() -> [URLRequest] { requests }
}

private actor Counter {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

private actor EntrySignal {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?

    func markEntered() {
        entered = true
        waiter?.resume()
        waiter = nil
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

/// The observer and sleep seams are synchronous closures. Every mutable access is under this lock.
private final class LockedCapture<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []
    func append(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
    func snapshot() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private enum ProbeFailure: Error { case provider }

private func config(
    authentication: JevAuthentication = .apiKey("key"),
    baseURL: URL = URL(string: "https://example.test")!,
    retryPolicy: RetryPolicy = .disabled,
    totalTimeout: TimeInterval? = nil,
    observer: (@Sendable (JevEvent) -> Void)? = nil
) -> JevConfiguration {
    JevConfiguration(
        authentication: authentication,
        baseURL: baseURL,
        totalTimeout: totalTimeout,
        retryPolicy: retryPolicy,
        observer: observer
    )
}

private func execute(
    _ executor: HTTPExecutor,
    method: String = "POST",
    path: String = "/v1/systemone",
    body: Data? = Data("{}".utf8),
    options: RequestOptions = .init()
) async throws -> (HTTPResponse, ResponseMetadata) {
    try await executor.execute(method: method, path: path, body: body, options: options)
}

private func requireHTTPError(
    _ operation: () async throws -> Void
) async -> JevHTTPError? {
    do {
        try await operation()
        Issue.record("Expected an HTTP error")
    } catch JevError.http(let error) {
        return error
    } catch {
        Issue.record("Expected JevError.http, got \(type(of: error))")
    }
    return nil
}

struct TransportTests {
    // Concurrent calls must share a Sendable executor without mixing bodies, auth, or base paths.
    @Test func concurrentRequestsAndBasePaths() async throws {
        let transport = RecordingTransport()
        let executor = HTTPExecutor(
            configuration: config(baseURL: URL(string: "https://example.test/gateway/")!),
            transport: transport
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    let body = Data("payload-\(index)".utf8)
                    let (_, metadata) = try await execute(
                        executor,
                        body: body,
                        options: RequestOptions(headers: ["X-Request-Number": "\(index)"])
                    )
                    #expect(metadata.attempts == 1)
                }
            }
            try await group.waitForAll()
        }
        let requests = await transport.recorded()
        #expect(requests.count == 32)
        for request in requests {
            #expect(request.url?.absoluteString == "https://example.test/gateway/v1/systemone")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key")
            let index = try #require(Int(request.value(forHTTPHeaderField: "X-Request-Number") ?? ""))
            #expect(request.httpBody == Data("payload-\(index)".utf8))
        }
    }

    // Authentication must refresh on retry; ordinary headers merge while protocol headers remain owned.
    @Test func authenticationAndHeaders() async throws {
        let counter = Counter()
        let transport = RecordingTransport { _, attempt in
            attempt == 1 ? HTTPResponse(statusCode: 503, headers: [:], body: Data()) : ok
        }
        var configuration = config(
            authentication: .bearerToken { "token-\(await counter.next())" },
            retryPolicy: RetryPolicy(maxRetries: 1, jitter: 0)
        )
        configuration.headers = [
            "aCcEpT": "wrong", "cOnTeNt-TyPe": "wrong", "uSeR-aGeNt": "wrong",
            "aUtHoRiZaTiOn": "wrong", "X-Mode": "base"
        ]
        let executor = HTTPExecutor(configuration: configuration, transport: transport, sleep: { _ in })
        let (_, metadata) = try await execute(
            executor,
            options: RequestOptions(
                headers: [
                    "x-mode": "call", "ACCEPT": "also wrong",
                    "AUTHORIZATION": "also wrong"
                ], requestTimeout: 7
            )
        )
        #expect(metadata.attempts == 2)
        let requests = await transport.recorded()
        #expect(requests.count == 2)
        for (index, request) in requests.enumerated() {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-\(index + 1)")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "JevClient/0.1.0")
            #expect(request.value(forHTTPHeaderField: "X-Mode") == "call")
            #expect(request.timeoutInterval == 7)
        }
        let proxy = RecordingTransport()
        _ = try await execute(
            HTTPExecutor(configuration: config(authentication: .none), transport: proxy),
            method: "GET", path: "/v1/models", body: nil,
            options: RequestOptions(headers: ["aUtHoRiZaTiOn": "Proxy custom"])
        )
        let proxyRequest = try #require(await proxy.recorded().first)
        #expect(proxyRequest.value(forHTTPHeaderField: "Authorization") == "Proxy custom")
        #expect(proxyRequest.value(forHTTPHeaderField: "Content-Type") == nil)
        var tabHeader = config()
        tabHeader.headers = ["X-Note": "alpha\tbeta"]
        try tabHeader.validate()
        let staticKey = RecordingTransport()
        _ = try await execute(HTTPExecutor(configuration: config(), transport: staticKey))
        #expect(await staticKey.recorded().first?.value(forHTTPHeaderField: "Authorization") == "Bearer key")
    }

    // Unsafe URLs, timeouts, headers, policies, and tokens must fail before transport.send.
    @Test func rejectsInvalidConfiguration() async throws {
        let transport = RecordingTransport()
        var invalid: [JevConfiguration] = []
        for raw in [
            "ftp://example.test", "https://user:pass@example.test", "https://example.test?x=1",
            "https://example.test#fragment"
        ] {
            invalid.append(config(baseURL: URL(string: raw)!))
        }
        for timeout in [0, -1, .nan, .infinity] as [TimeInterval] {
            var value = config()
            value.requestTimeout = timeout
            invalid.append(value)
            value = config()
            value.totalTimeout = timeout
            invalid.append(value)
        }
        for headers in [
            ["Bad Name": "x"], ["X-Test": "one\rtwo"],
            ["X-Test": "one\ntwo"], ["X-Test": "one\r\ntwo"],
            ["X-Test": "one\0two"], ["X-Test": "one\u{7f}two"],
            ["Host": "other.test"], ["content-LENGTH": "3"],
            ["X-Duplicate": "a", "x-duplicate": "b"]
        ] {
            var value = config()
            value.headers = headers
            invalid.append(value)
        }
        for policy in [
            RetryPolicy(maxRetries: -1), RetryPolicy(maxRetries: .max),
            RetryPolicy(initialDelay: -.infinity), RetryPolicy(maxDelay: .nan),
            RetryPolicy(jitter: 1.1), RetryPolicy(maxRetryAfter: -1),
            RetryPolicy(statusCodes: [99])
        ] {
            invalid.append(config(retryPolicy: policy))
        }
        for value in invalid {
            do {
                _ = try await execute(HTTPExecutor(configuration: value, transport: transport))
                Issue.record("Expected configuration rejection")
            } catch JevError.configuration { }
        }
        for options in [
            RequestOptions(headers: ["X-Test": "bad\nvalue"]),
            RequestOptions(requestTimeout: 0),
            RequestOptions(totalTimeout: .nan),
            RequestOptions(retryPolicy: RetryPolicy(jitter: -0.1))
        ] {
            do {
                _ = try await execute(HTTPExecutor(configuration: config(), transport: transport), options: options)
                Issue.record("Expected options rejection")
            } catch JevError.configuration { }
        }
        for auth in [
            JevAuthentication.apiKey(""), .apiKey("bad\rkey"), .apiKey("bad\nkey"),
            .apiKey("bad\r\nkey"), .apiKey("bad\tkey")
        ] {
            do {
                _ = try await execute(HTTPExecutor(configuration: config(authentication: auth), transport: transport))
                Issue.record("Expected token rejection")
            } catch JevError.configuration { }
        }
        do {
            let provider = JevAuthentication.bearerToken { "bad\r\nkey" }
            _ = try await execute(HTTPExecutor(configuration: config(authentication: provider), transport: transport))
            Issue.record("Expected provider token rejection")
        } catch JevError.configuration { }
        do {
            let provider = JevAuthentication.bearerToken { throw ProbeFailure.provider }
            _ = try await execute(HTTPExecutor(configuration: config(authentication: provider), transport: transport))
            Issue.record("Expected provider failure")
        } catch ProbeFailure.provider { }
        #expect(await transport.recorded().isEmpty)
    }

    // Only transient configured responses and network errors retry; final errors retain original bytes.
    @Test func retriesTransientHTTPFailures() async throws {
        let transport = RecordingTransport { _, attempt in
            switch attempt {
            case 1: HTTPResponse(statusCode: 529, headers: [:], body: Data("first".utf8))
            case 2: HTTPResponse(statusCode: 429, headers: [:], body: Data("second".utf8))
            default: ok
            }
        }
        let executor = HTTPExecutor(
            configuration: config(retryPolicy: RetryPolicy(jitter: 0)),
            transport: transport, sleep: { _ in }
        )
        #expect(try await execute(executor).1.attempts == 3)
        #expect(await transport.recorded().count == 3)

        for status in [401, 403, 422] {
            let noRetry = RecordingTransport { _, _ in
                HTTPResponse(statusCode: status, headers: [:], body: Data("denied".utf8))
            }
            let error = await requireHTTPError {
                _ = try await execute(HTTPExecutor(
                    configuration: config(retryPolicy: RetryPolicy()), transport: noRetry,
                    sleep: { _ in }
                ))
            }
            #expect(error?.statusCode == status)
            #expect(await noRetry.recorded().count == 1)
        }
        let final = RecordingTransport { _, attempt in
            HTTPResponse(
                statusCode: 429, headers: ["X-TypeSafe-Request-Id": "req-\(attempt)"],
                body: Data("error-\(attempt)".utf8)
            )
        }
        let finalError = await requireHTTPError {
            _ = try await execute(HTTPExecutor(
                configuration: config(retryPolicy: RetryPolicy(maxRetries: 1, jitter: 0)),
                transport: final, sleep: { _ in }
            ))
        }
        #expect(finalError?.attempts == 2)
        #expect(finalError?.body == Data("error-2".utf8))
        #expect(finalError?.requestID == "req-2")
        #expect(finalError?.bodyText == "error-2")
        #expect(finalError?.errorDescription == "HTTP 429 (request req-2)")

        let disabled = RecordingTransport { _, _ in
            HTTPResponse(statusCode: 503, headers: [:], body: Data("disabled".utf8))
        }
        let disabledError = await requireHTTPError {
            _ = try await execute(HTTPExecutor(
                configuration: config(retryPolicy: RetryPolicy(maxRetries: 2)),
                transport: disabled, sleep: { _ in }
            ), options: RequestOptions(retryPolicy: .disabled))
        }
        #expect(disabledError?.bodyText == "disabled")
        #expect(await disabled.recorded().count == 1)

        for (code, retries) in [
            (URLError.notConnectedToInternet, true), (URLError.timedOut, true),
            (URLError.serverCertificateUntrusted, false)
        ] {
            let failing = RecordingTransport { _, _ in throw URLError(code) }
            do {
                _ = try await execute(HTTPExecutor(
                    configuration: config(retryPolicy: RetryPolicy(maxRetries: 1, jitter: 0)),
                    transport: failing, sleep: { _ in }
                ))
                Issue.record("Expected transport failure")
            } catch JevError.transport { }
            #expect(await failing.recorded().count == (retries ? 2 : 1))
        }
        let cancelled = RecordingTransport { _, _ in throw CancellationError() }
        do {
            _ = try await execute(HTTPExecutor(
                configuration: config(retryPolicy: RetryPolicy()), transport: cancelled,
                sleep: { _ in }
            ))
            Issue.record("Expected cancellation")
        } catch is CancellationError { }
        #expect(await cancelled.recorded().count == 1)

        for (code, policy) in [
            (URLError.notConnectedToInternet, RetryPolicy(maxRetries: 1, retryConnectionErrors: false)),
            (URLError.timedOut, RetryPolicy(maxRetries: 1, retryTimeouts: false))
        ] {
            let failing = RecordingTransport { _, _ in throw URLError(code) }
            do {
                _ = try await execute(HTTPExecutor(
                    configuration: config(retryPolicy: policy), transport: failing,
                    sleep: { _ in }
                ))
                Issue.record("Expected disabled transport retry failure")
            } catch JevError.transport { }
            #expect(await failing.recorded().count == 1)
        }
    }

    // Backoff is capped before downward jitter; valid server delays take precedence and a cap forbids early retries.
    @Test func retryAfterAndBackoff() async throws {
        let delays = LockedCapture<TimeInterval>()
        let backoff = RecordingTransport { _, attempt in
            attempt <= 3 ? HTTPResponse(statusCode: 503, headers: [:], body: Data()) : ok
        }
        _ = try await execute(HTTPExecutor(
            configuration: config(retryPolicy: RetryPolicy(
                maxRetries: 3, initialDelay: 0.5, maxDelay: 1, jitter: 0
            )),
            transport: backoff, sleep: { delays.append($0) }
        ))
        #expect(delays.snapshot() == [0.5, 1, 1])

        let serverDelays = LockedCapture<TimeInterval>()
        let fromHeaders = RecordingTransport { _, attempt in
            switch attempt {
            case 1:
                HTTPResponse(statusCode: 429, headers: [
                    "Retry-After-Ms": "1250", "Retry-After": "10"
                ], body: Data())
            case 2:
                HTTPResponse(statusCode: 429, headers: ["Retry-After-Ms": "bad"], body: Data())
            default: ok
            }
        }
        _ = try await execute(HTTPExecutor(
            configuration: config(retryPolicy: RetryPolicy(maxRetries: 2, jitter: 0)),
            transport: fromHeaders, sleep: { serverDelays.append($0) }
        ))
        #expect(serverDelays.snapshot() == [1.25, 1])

        let date = Date().addingTimeInterval(5)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let dateHeader = formatter.string(from: date)
        let dateDelays = LockedCapture<TimeInterval>()
        let dated = RecordingTransport { _, attempt in
            attempt == 1
                ? HTTPResponse(statusCode: 429, headers: ["Retry-After": dateHeader], body: Data())
                : ok
        }
        _ = try await execute(HTTPExecutor(
            configuration: config(retryPolicy: RetryPolicy(maxRetries: 1, jitter: 0)),
            transport: dated, sleep: { dateDelays.append($0) }
        ))
        let parsedDelay = try #require(dateDelays.snapshot().first)
        #expect(abs(parsedDelay - date.timeIntervalSinceNow) < 2)

        let capped = RecordingTransport { _, _ in
            HTTPResponse(statusCode: 429, headers: ["Retry-After": "61"], body: Data("wait".utf8))
        }
        let cappedError = await requireHTTPError {
            _ = try await execute(HTTPExecutor(
                configuration: config(retryPolicy: RetryPolicy(maxRetries: 2, jitter: 0)),
                transport: capped, sleep: { _ in Issue.record("Must not sleep before server delay") }
            ))
        }
        #expect(cappedError?.bodyText == "wait")
        #expect(await capped.recorded().count == 1)
    }

    // Cancellation while a retry delay is entered must stop the next send without a timing race.
    @Test func cancellationStopsRequests() async throws {
        let entered = EntrySignal()
        let transport = RecordingTransport { _, _ in
            HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
        let executor = HTTPExecutor(
            configuration: config(retryPolicy: RetryPolicy(maxRetries: 2)),
            transport: transport,
            sleep: { _ in
                await entered.markEntered()
                try await Task.sleep(nanoseconds: UInt64.max)
            }
        )
        let task = Task { try await execute(executor) }
        await entered.waitUntilEntered()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError { }
        #expect(await transport.recorded().count == 1)

        let transportEntered = EntrySignal()
        let waitingTransport = RecordingTransport { _, _ in
            await transportEntered.markEntered()
            try await Task.sleep(nanoseconds: UInt64.max)
            return ok
        }
        let waitingTask = Task {
            try await execute(HTTPExecutor(
                configuration: config(retryPolicy: RetryPolicy(maxRetries: 2)),
                transport: waitingTransport
            ))
        }
        await transportEntered.waitUntilEntered()
        waitingTask.cancel()
        do {
            _ = try await waitingTask.value
            Issue.record("Expected transport CancellationError")
        } catch is CancellationError { }
        #expect(await waitingTransport.recorded().count == 1)
    }

    // A full-operation deadline covers providers and custom transports; nil disables it.
    @Test func enforcesTimeouts() async throws {
        let blockedProvider = JevAuthentication.bearerToken {
            try await Task.sleep(nanoseconds: UInt64.max)
            return "late"
        }
        let neverSent = RecordingTransport()
        do {
            _ = try await execute(HTTPExecutor(
                configuration: config(authentication: blockedProvider, totalTimeout: 0.1),
                transport: neverSent
            ))
            Issue.record("Expected provider deadline")
        } catch JevError.timeout { }
        #expect(await neverSent.recorded().isEmpty)

        let blockedTransport = RecordingTransport { _, _ in
            try await Task.sleep(nanoseconds: UInt64.max)
            return ok
        }
        do {
            _ = try await execute(HTTPExecutor(
                configuration: config(totalTimeout: 0.1), transport: blockedTransport
            ))
            Issue.record("Expected transport deadline")
        } catch JevError.timeout { }
        #expect(await blockedTransport.recorded().count == 1)

        let noDeadline = RecordingTransport()
        var noDeadlineConfig = config(totalTimeout: nil)
        noDeadlineConfig.requestTimeout = 15
        _ = try await execute(HTTPExecutor(configuration: noDeadlineConfig, transport: noDeadline))
        #expect(await noDeadline.recorded().first?.timeoutInterval == 15)
    }

    // Observer events must expose only lifecycle fields, never auth, bodies, or secret headers.
    @Test func observerEventsAreRedacted() async throws {
        let events = LockedCapture<JevEvent>()
        let transport = RecordingTransport { _, attempt in
            attempt == 1
                ? HTTPResponse(statusCode: 503, headers: ["X-TypeSafe-Request-Id": "first"], body: Data("private-body".utf8))
                : HTTPResponse(statusCode: 200, headers: ["x-typesafe-request-id": "second"], body: Data("ok".utf8))
        }
        let configuration = config(
            authentication: .apiKey("private-key"),
            retryPolicy: RetryPolicy(maxRetries: 1, jitter: 0),
            observer: { events.append($0) }
        )
        _ = try await execute(HTTPExecutor(
            configuration: configuration, transport: transport, sleep: { _ in }
        ))
        let observed = events.snapshot()
        #expect(observed.count == 5)
        guard observed.count == 5 else { return }
        if case .requestStarted(let attempt, let method, let path) = observed[0] {
            #expect(attempt == 1 && method == "POST" && path == "/v1/systemone")
        } else { Issue.record("Expected requestStarted") }
        if case .responseReceived(let attempt, let status, let id) = observed[1] {
            #expect(attempt == 1 && status == 503 && id == "first")
        } else { Issue.record("Expected responseReceived") }
        if case .retryScheduled(let attempt, let delay) = observed[2] {
            #expect(attempt == 1 && delay == 0.5)
        } else { Issue.record("Expected retryScheduled") }
        if case .requestStarted(let attempt, _, _) = observed[3] {
            #expect(attempt == 2)
        } else { Issue.record("Expected second requestStarted") }
        if case .responseReceived(let attempt, let status, let id) = observed[4] {
            #expect(attempt == 2 && status == 200 && id == "second")
        } else { Issue.record("Expected second responseReceived") }
        let description = String(describing: observed)
        #expect(!description.contains("private-key"))
        #expect(!description.contains("private-body"))
        #expect(!description.contains("Authorization"))

        let failures = LockedCapture<JevEvent>()
        let rejected = RecordingTransport { _, _ in
            HTTPResponse(statusCode: 401, headers: [:], body: Data("secret-error".utf8))
        }
        _ = await requireHTTPError {
            _ = try await execute(HTTPExecutor(
                configuration: config(observer: { failures.append($0) }), transport: rejected
            ))
        }
        let failureEvents = failures.snapshot()
        #expect(failureEvents.count == 3)
        if failureEvents.count == 3,
           case .requestFailed(let attempt, let kind) = failureEvents[2] {
            #expect(attempt == 1 && kind == "http")
        } else { Issue.record("Expected terminal requestFailed") }
        #expect(!String(describing: failureEvents).contains("secret-error"))
    }

    #if os(macOS) || os(Linux)
    // A real loopback server verifies URLSession's bytes, headers, error body, and redirect refusal.
    @Test func urlSessionWireBehavior() async throws {
        let server = try LoopbackServer(minimumRequests: 6) { request in
            switch request.path {
            case "/base/v1/systemone":
                return .init(status: 200, body: Data("{}".utf8))
            case "/base/v1/models":
                return .init(status: 200, body: Data("{\"models\":[]}".utf8))
            case "/error":
                return .init(status: 422, headers: ["X-TypeSafe-Request-Id": "wire-id"], body: Data("wire-error".utf8))
            case "/redirect":
                return .init(status: 302, headers: ["Location": "/destination"], body: Data())
            case "/configured":
                return .init(status: 200, body: Data("configured".utf8))
            default:
                return .init(status: 500, body: Data("unexpected".utf8))
            }
        }
        let transport = URLSessionTransport()
        let base = HTTPExecutor(
            configuration: config(
                authentication: .apiKey("wire-secret"),
                baseURL: server.url.appendingPathComponent("base")
            ),
            transport: transport
        )
        #expect(try await execute(base, body: Data("wire-body".utf8)).1.statusCode == 200)
        #expect(try await execute(base, method: "GET", path: "/v1/models", body: nil).1.statusCode == 200)
        let root = HTTPExecutor(
            configuration: config(baseURL: server.url), transport: transport
        )
        let error = await requireHTTPError {
            _ = try await execute(root, method: "GET", path: "/error", body: nil)
        }
        #expect(error?.statusCode == 422)
        #expect(error?.body == Data("wire-error".utf8))
        #expect(error?.requestID == "wire-id")
        let redirect = await requireHTTPError {
            _ = try await execute(root, method: "GET", path: "/redirect", body: nil)
        }
        #expect(redirect?.statusCode == 302)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpAdditionalHeaders = ["X-Session-Config": "owned-config"]
        let configuredTransport = URLSessionTransport(configuration: sessionConfiguration)
        let configuredRoot = HTTPExecutor(
            configuration: config(authentication: .none, baseURL: server.url),
            transport: configuredTransport
        )
        #expect(try await execute(configuredRoot, method: "GET", path: "/configured", body: nil).1.statusCode == 200)
        let configuredRedirect = await requireHTTPError {
            _ = try await execute(configuredRoot, method: "GET", path: "/redirect", body: nil)
        }
        #expect(configuredRedirect?.statusCode == 302)
        let received = try await server.requests()
        #expect(received.count == 6)
        #expect(received.map(\.path) == [
            "/base/v1/systemone", "/base/v1/models", "/error", "/redirect",
            "/configured", "/redirect"
        ])
        #expect(received[0].method == "POST")
        #expect(received[0].body == Data("wire-body".utf8))
        #expect(received[0].header("authorization") == "Bearer wire-secret")
        #expect(received[0].header("content-type") == "application/json")
        #expect(received[0].header("accept") == "application/json")
        #expect(received[0].header("user-agent") == "JevClient/0.1.0")
        #expect(received[1].method == "GET")
        #expect(received[4].header("x-session-config") == "owned-config")
        #expect(received[5].header("x-session-config") == "owned-config")
        #expect(!received.contains(where: { $0.path == "/destination" }))
    }
    #endif
}
