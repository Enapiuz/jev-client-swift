# ``JevClient``

A Swift client for TypeSafe AI's System One decision API and model discovery endpoint.

## Overview

JevClient sends a string or structured JSON state together with named ``Question`` values. Each question requests a constrained ``Answer``: Choice selects one supplied label, Score estimates a position on an ordered rubric, and Noul estimates the probability that a proposition is true. The service is not a chat or text-generation interface.

Create a client with a key, then make one or several evaluations:

```swift
let client = try JevClient(apiKey: key)
let result = try await client.noul(
    state: "Please refund last month's charge.",
    instructions: "Does this message explicitly request money already paid to be returned?"
)
let probability = result.value.noul
```

The SDK accepts optional question instructions for wire compatibility. Supply a clear instruction in ordinary use. The question ID is only a correlation key. Criteria descriptions and instructions can be ``JSONValue`` strings or structured JSON. `state` must be a top-level string, object, or array. ``SystemOneRequest/validate()`` checks local inputs before the network call.

For several judgments over the same evidence, use ``JevClient/evaluate(state:questions:model:options:validation:)``. The answer IDs match the question IDs. Decision results expose the resolved `model` and optional token `usage` directly on ``JevResponse``, as well as in the batch ``SystemOneResponse``. Optional usage means unknown when absent; it is not a zero count. Moving model aliases can resolve to different versions over time. ``JevClient/models(options:)`` returns available model metadata.

Single-question methods use the ID `result` and return a ``JevResponse`` holding only that typed answer in `value`. The resolved model, optional usage, and complete response bytes remain available on the wrapper. Use `evaluate` or ``JevClient/systemOne(_:options:validation:)`` when all named answers matter. ``JevClient/choice(state:instructions:choices:descriptions:model:options:)`` converts all cases of a string-backed enum into Choice labels and converts the entire returned distribution to enum keys.

## HTTP behavior

``JevConfiguration`` sets an API-root URL, model, authentication, headers, timeouts, retries, and an optional observer. The official root is `https://api.typesafe.ai`; paths `/v1/systemone` and `/v1/models` are added by the client. Authentication is explicit: fixed API key, an async Bearer token provider invoked per attempt, or caller-managed proxy authorization. The client does not read environment variables or store credentials. A shared service key in a distributed app belongs on a backend or must be replaced by a user-supplied key handled securely.

``RequestOptions`` overrides headers, timeout values, and retry policy for one operation. Timeout values are seconds. The request timeout is per attempt; the optional total timeout covers retries, delays, and token acquisition. A total deadline can wait for a custom transport or token provider that ignores cancellation. The default policy permits two retries for configured transient failures. Retrying an evaluation may repeat billable work; set `retryPolicy: .disabled` to disable retries unambiguously, including in per-call options. Caller task cancellation propagates as `CancellationError`.

``URLSessionTransport`` owns an ephemeral session by default, disables cookies and caching, and refuses redirects. `URLSessionTransport(configuration:)` copies the supplied `URLSessionConfiguration` into a session owned by the transport and still refuses redirects. To reuse an existing session, implement ``HTTPTransport`` around it. Custom transports should cooperate with task cancellation. Linux uses `FoundationNetworking` for URLSession and URLRequest compatibility.

The optional ``JevConfiguration/observer`` receives lifecycle events without bodies or credentials. It can include paths, statuses, timing, and request IDs; apply your application's privacy policy before forwarding events. Avoid logging states, headers, raw bodies, and secrets by default.

## Validation and errors

``ResponseValidation/standard`` validates decoded answers against the request: IDs and types, labels and rubric indices, finite probabilities, score ranges, and usage counts. ``ResponseValidation/strict(tolerance:)`` also checks distribution mass, Choice winner consistency, Score weighted mean, and the echoed Score rubric. Tolerance must be finite in `0...0.1`. Strict mode can reject ordinary rounding or changed echo text.

Malformed local input throws ``JevValidationError``. Non-2xx HTTP responses throw ``JevError/http(_:)`` carrying status, headers, request ID, attempts, and raw body. Decoding failures carry a generic sanitized message plus metadata and raw bytes for deliberate inspection; invalid decoded answers throw ``JevError/invalidResponse(reason:metadata:)``. ``JevResponse`` retains status, headers, request ID, attempt count, and raw bytes for successful calls.

The package declares Swift 6.4, Swift 6 language mode, macOS 12, and iOS 15 minimums. CI is configured for Apple and Linux tests and release builds, with an iOS device compile check and a DocC build on Apple. A configured workflow is separate from a hosted run; an iOS build does not establish runtime behavior. The test suite uses local HTTP fixtures and does not make an authenticated TypeSafe API call. See the repository README for installation and examples and the [testing guide](../../../Documentation/Testing.md) for repeatable checks. Consult the current [TypeSafe API reference](https://docs.typesafe.ai/api), [System One concepts](https://docs.typesafe.ai/concepts/system-one), and [model reference](https://docs.typesafe.ai/models) for service behavior.

## Topics

### Client and configuration

- ``JevClient``
- ``JevConfiguration``
- ``JevAuthentication``
- ``RequestOptions``
- ``RetryPolicy``
- ``HTTPTransport``
- ``URLSessionTransport``
- ``JevEvent``

### Requests and answers

- ``JSONValue``
- ``JevModel``
- ``SystemOneRequest``
- ``Question``
- ``NoulCriteria``
- ``SystemOneResponse``
- ``Answer``
- ``ChoiceAnswer``
- ``ScoreAnswer``
- ``NoulAnswer``
- ``TypedChoiceAnswer``
- ``Usage``
- ``ModelCard``

### Results and failures

- ``JevResponse``
- ``ResponseMetadata``
- ``ResponseValidation``
- ``JevValidationError``
- ``JevError``
- ``JevHTTPError``
