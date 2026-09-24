# JevClient

JevClient is a Swift package for TypeSafe AI's [System One API](https://docs.typesafe.ai/api). It sends evidence as a `state` value and named questions, then returns constrained Choice, Score, or Noul answers. It also lists available models. The package has no third-party dependencies and imports no UI framework.

The package requires Swift 6.4 in Swift 6 language mode. Its declared minimums are macOS 12 and iOS 15. Linux uses `FoundationNetworking` where needed. CI is configured for macOS and Linux package tests and an iOS device build. JevClient does not implement streaming, chat, file uploads, or automatic credential storage.

## Add the local package

In Xcode, use **File → Add Package Dependencies → Add Local…**, select this repository, and add the `JevClient` library product to your target. For another Swift package, use a local path and product dependency:

```swift
dependencies: [
    .package(path: "../JevClient"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [.product(name: "JevClient", package: "JevClient")]
    ),
]
```

There is no published package URL or release tag to install yet.

## First request

This complete example reads an API key in the application and asks whether a message requests a refund. The client itself never reads environment variables. Set `TYPESAFE_API_KEY` before running this example; do not commit a key to source control.

```swift
import Foundation
import JevClient

private struct MissingAPIKey: Error {}

@main
struct Example {
    static func main() async throws {
        guard let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"],
              !key.isEmpty else { throw MissingAPIKey() }

        let client = try JevClient(apiKey: key)
        let result = try await client.noul(
            state: "Please refund the payment for last month.",
            instructions: "Does this message explicitly request the return of money already paid?"
        )
        print(result.value.noul)
        print(result.metadata.requestID ?? "No request ID returned")
    }
}
```

`noul` is a probability in `0...1`, not a Boolean, and it has no confidence field. Choice selects one supplied label; Score returns an expected position on an ordered rubric. Choice and Score both include full probability distributions and a separate service-provided confidence value. Put the question in `instructions`: the question ID is for correlation, not semantic instructions. The SDK permits omitted instructions for API compatibility, but explicit instructions usually make the intended judgment clearer. See the [question primitives](https://docs.typesafe.ai/primitives).

## Batch questions over one state

The following statements run in an async context with a `client` from the first example:

```swift
let result = try await client.evaluate(
    state: [
        "message": "The export crashes every time. I cannot send the report.",
        "plan": "business"
    ],
    questions: [
        "team": .choice(
            instructions: "Which team should handle the primary issue?",
            criteria: [
                "technical": "A product malfunction or blocked workflow",
                "billing": "Payments, invoices, and refunds",
                "other": "Neither team fits"
            ]
        ),
        "impact": .score(
            instructions: "How blocked is the user's workflow?",
            criteria: [
                "The workflow works normally.",
                "The workflow is impaired but has a workaround.",
                "The workflow cannot be completed."
            ]
        ),
        "refund": .noul(
            instructions: "Does the message explicitly request a refund?"
        )
    ]
)

let team = try result.value.choice("team")
let impact = try result.value.score("impact")
let refund = try result.value.noul("refund")
print(team.choice, impact.score, refund.noul)
print(result.model as Any, result.usage?.inputTokens as Any)
```

`JevResponse.model` and `JevResponse.usage` are available for batched and single-question decisions. `usage` and each token count are optional: missing usage means unknown, not zero. The returned model identifies the resolved service model, which can differ from a moving alias such as `.latest`. The full batch envelope is also in `result.value`. Model discovery uses `try await client.models()` and returns `[ModelCard]`; a model ID can be valid even when absent from the alias list. See [models](https://docs.typesafe.ai/models).

## Typed Choice and structured state

All enum cases become Choice labels. Descriptions default to JSON null; meaningful descriptions make labels less ambiguous. The helper rejects duplicate raw labels, descriptions for cases outside `allCases`, and response labels or probability keys that cannot map back to the enum.

```swift
enum Team: String, CaseIterable, Hashable, Sendable {
    case technical, billing, other
}

let decision = try await client.choice(
    state: "The export button crashes the app.",
    instructions: "Which team should handle the primary issue?",
    choices: Team.self,
    descriptions: [
        .technical: "A product malfunction",
        .billing: "Payments or invoices",
        .other: "Neither team fits"
    ]
)
let selected: Team = decision.value.choice
let technicalProbability = decision.value.probabilities[.technical]
```

Use `JSONValue.encoding` for an existing `Encodable` state, and `JSONValue.decode` to convert a JSON value back to a model. The request's top-level state must be a string, object, or array; nested values can include numbers, booleans, and null. Input validation rejects non-finite numbers and malformed question criteria before sending a request.

```swift
struct Ticket: Codable, Sendable {
    let message: String
    let priority: Int
}

let ticket = Ticket(message: "Export fails", priority: 2)
let state = try JSONValue.encoding(ticket)
let answer = try await client.noul(
    state: state,
    instructions: "Does this ticket describe a product malfunction?"
)
```

## Configuration, retries, and cancellation

`JevConfiguration` accepts a fixed `.apiKey`, an async `.bearerToken` provider called for each attempt, or `.none` for a caller-managed proxy authorization header. A custom `baseURL` is the API root, not the `/v1` prefix. Use a secure token source in real applications; the environment lookup below only illustrates the provider shape.

```swift
let configuration = JevConfiguration(
    authentication: .bearerToken {
        guard let token = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"],
              !token.isEmpty else { throw MissingAPIKey() }
        return token
    },
    model: .latest,
    requestTimeout: 15,
    totalTimeout: 45,
    retryPolicy: RetryPolicy(maxRetries: 1),
    observer: { event in
        // Forward only the lifecycle fields your logging policy permits.
        _ = event
    }
)
let configuredClient = try JevClient(
    configuration: configuration,
    responseValidation: .strict(tolerance: 0.01)
)
let perCall = RequestOptions(
    requestTimeout: 10,
    totalTimeout: 20,
    retryPolicy: .disabled
)
let models = try await configuredClient.models(options: perCall)
```

Timeout values are seconds. `requestTimeout` is per HTTP attempt; `totalTimeout` covers token acquisition, attempts, and retry delays. Per-call options override the configured values when present. The default policy permits two retries after the first attempt for selected transient HTTP, connection, and timeout failures, with bounded backoff and applicable `Retry-After` headers. Retrying a System One evaluation may repeat billable work. Set `retryPolicy: .disabled` to disable retries unambiguously, including in per-call options. A total deadline and caller cancellation require a custom transport or token provider to cooperate with task cancellation; an uncooperative operation can delay completion.

```swift
let task = Task {
    try await client.noul(
        state: "Please cancel renewal.",
        instructions: "Does the message request cancellation of the next renewal?"
    )
}
// When this work is no longer needed:
task.cancel()
```

For a proxy with its own authorization scheme, configure `.none`, supply an API-root URL for the proxy, and set its `Authorization` header in `headers`. The proxy must expose the same `/v1/systemone` and `/v1/models` paths:

```swift
private struct MissingProxyConfiguration: Error {}

guard let proxyURLText = ProcessInfo.processInfo.environment["JEV_PROXY_URL"],
      let proxyURL = URL(string: proxyURLText),
      let proxyAuthorization = ProcessInfo.processInfo.environment["JEV_PROXY_AUTH"] else {
    throw MissingProxyConfiguration()
}
let proxyClient = try JevClient(configuration: JevConfiguration(
    authentication: .none,
    baseURL: proxyURL,
    headers: ["Authorization": proxyAuthorization]
))
```

For direct TypeSafe calls, use `.apiKey` or `.bearerToken`; these set the Bearer header for you. Do not embed a shared TypeSafe secret in a distributed app. Route requests through your backend or let the user supply a key that you handle securely. The SDK provides no keychain integration or automatic storage.

The transport is injectable. This wrapper illustrates instrumentation while preserving the normal URLSession behavior:

```swift
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct TimedTransport: HTTPTransport {
    let underlying: any HTTPTransport

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let start = ProcessInfo.processInfo.systemUptime
        let response = try await underlying.send(request)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("HTTP duration:", elapsed)
        return response
    }
}

let instrumentedClient = try JevClient(
    apiKey: key,
    transport: TimedTransport(underlying: URLSessionTransport())
)
```

The default `URLSessionTransport` owns an ephemeral session with cookies and caching disabled. It refuses redirects. `URLSessionTransport(configuration:)` copies a supplied `URLSessionConfiguration` into a new session owned by the transport and still refuses redirects:

```swift
let sessionConfiguration = URLSessionConfiguration.ephemeral
sessionConfiguration.timeoutIntervalForResource = 60
let configuredTransport = URLSessionTransport(configuration: sessionConfiguration)
let clientWithSessionConfiguration = try JevClient(
    apiKey: key,
    transport: configuredTransport
)
```

To reuse an existing session, provide your own `HTTPTransport` implementation. A custom transport should respect cancellation and return the complete body as `HTTPResponse`.

## Validation and errors

`.standard` response validation checks structure against the request: answer IDs and kinds, Choice labels, Score indices, finite in-range probabilities and scores, and optional usage counts. `.strict(tolerance:)` additionally checks probability mass, the Choice winner, the Score weighted mean, and the echoed Score legend. The tolerance must be finite and within `0...0.1`. Strict checking can reject rounded distributions or changed echo text that standard validation accepts. Request validation is always enabled.

Every `JevResponse` includes `metadata` (`statusCode`, headers, request ID, attempt count) and the raw response `body`. Decision results also expose the resolved `model` and optional `usage`, including single-question helpers. Single-question helpers return only the selected answer in `value`; use `evaluate` or `systemOne` to access all named answers in the full envelope. Non-2xx responses throw `JevError.http` with status, headers, request ID, attempts, and raw body. Decoding failures have a sanitized message and retain bytes for deliberate inspection. Avoid logging state, credentials, headers, or response bodies by default; even a request ID may be sensitive in some systems. The observer emits lifecycle events without request or response bodies.

```swift
do {
    let result = try await client.models()
    print(result.metadata.statusCode, result.value.count)
} catch JevError.http(let error) {
    print("HTTP", error.statusCode, error.requestID as Any)
    // Inspect error.body or error.bodyJSON only when your privacy policy allows it.
} catch JevError.decoding(_, let metadata, _) {
    print("Could not decode response", metadata.requestID as Any)
} catch is CancellationError {
    // The caller cancelled the task.
}
```

Local input failures throw `JevValidationError`; invalid configuration, transport failure, timeout, decoding, and response validation use `JevError`. A cancelled operation propagates `CancellationError`.

## Verification

Run the package tests and release build on macOS or Linux with Swift 6.4:

```sh
Scripts/test.sh
swift build -c release
```

For an iOS compile check on macOS with Xcode and an iOS SDK:

```sh
xcodebuild -scheme JevClient -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

The [testing guide](Documentation/Testing.md) explains the Swift Testing runner, its optional Tiden reporting, artifacts, and a direct `swift test` path when Python is unavailable. The [CI workflow](.github/workflows/ci.yml) is configured to run package tests and release builds on Apple and Linux, plus an iOS device build and DocC build on Apple. A configured workflow is separate from a hosted run. The iOS build checks compilation, and these tests use local HTTP fixtures; neither establishes live authenticated TypeSafe API behavior.

API behavior and model availability can change; consult the current [TypeSafe API reference](https://docs.typesafe.ai/api), [model reference](https://docs.typesafe.ai/models), and [System One concepts](https://docs.typesafe.ai/concepts/system-one).
