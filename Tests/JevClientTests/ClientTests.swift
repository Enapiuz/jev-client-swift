import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import JevClient

private struct CapturedRequest: Sendable {
    let method: String?
    let url: String?
    let headers: [String: String]
    let body: Data?
    let timeout: TimeInterval

    init(_ request: URLRequest) {
        method = request.httpMethod
        url = request.url?.absoluteString
        headers = request.allHTTPHeaderFields ?? [:]
        body = request.httpBody
        timeout = request.timeoutInterval
    }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

private actor RecordingTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private var requests: [CapturedRequest] = []

    init(_ responses: [HTTPResponse]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(CapturedRequest(request))
        guard !responses.isEmpty else { throw FixtureError.exhausted }
        return responses.removeFirst()
    }

    func recorded() -> [CapturedRequest] { requests }
}

private enum FixtureError: Error { case exhausted }

private struct CancelledTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse { throw CancellationError() }
}

private struct TimedTransport: HTTPTransport {
    let underlying: any HTTPTransport

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let start = ProcessInfo.processInfo.systemUptime
        let response = try await underlying.send(request)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        #expect(elapsed >= 0)
        return response
    }
}

private func fixture(
    _ body: String,
    status: Int = 200,
    requestID: String = "request-fixture"
) -> HTTPResponse {
    HTTPResponse(
        statusCode: status,
        headers: ["x-typesafe-request-id": requestID, "Content-Type": "application/json"],
        body: Data(body.utf8)
    )
}

private let choiceResult = """
{"model":"jev-resolved","answers":{"result":{"type":"choice","choice":"technical","probabilities":{"technical":0.8,"billing":0.2},"confidence":0.67}},"usage":{"input_tokens":12,"output_tokens":4}}
"""

private let scoreResult = """
{"model":"jev-resolved","answers":{"result":{"type":"score","score":1.6,"legend":{"0":"None","1":"Some","2":"Blocked"},"probabilities":{"0":0.1,"1":0.2,"2":0.7},"confidence":0.7}},"usage":{"input_tokens":12,"output_tokens":4}}
"""

private let noulResult = """
{"model":"jev-resolved","answers":{"result":{"type":"noul","noul":0.8}},"usage":{"input_tokens":12,"output_tokens":4}}
"""

private enum Team: String, CaseIterable, Hashable, Sendable {
    case technical, billing, other
}

private struct DuplicateCase: RawRepresentable, CaseIterable, Hashable, Sendable {
    let rawValue: String
    let identity: Int

    init(rawValue: String, identity: Int) {
        self.rawValue = rawValue
        self.identity = identity
    }

    init?(rawValue: String) { self.init(rawValue: rawValue, identity: 0) }

    static var allCases: [DuplicateCase] {
        [
            DuplicateCase(rawValue: "same", identity: 1),
            DuplicateCase(rawValue: "same", identity: 2)
        ]
    }
}

private enum SparseCase: String, CaseIterable, Hashable, Sendable {
    case visible, hidden
    static var allCases: [SparseCase] { [.visible] }
}

@Suite struct ClientTests {
    // A mixed decision call must send the documented wire envelope and preserve the full response.
    @Test func evaluatesAllPrimitives() async throws {
        let responseBody = """
        {"model":"jev-resolved","answers":{"team":{"type":"choice","choice":"technical","probabilities":{"technical":0.93,"billing":0.02,"other":0.05},"confidence":0.8},"impact":{"type":"score","score":1.6,"legend":{"0":"None","1":"Some","2":"Blocked"},"probabilities":{"0":0.1,"1":0.2,"2":0.7},"confidence":0.7},"refund":{"type":"noul","noul":0.03}},"usage":{"input_tokens":70,"output_tokens":9}}
        """
        let transport = RecordingTransport(Array(repeating: fixture(responseBody), count: 3))
        let configuration = JevConfiguration(
            authentication: .apiKey("test-key"),
            model: "jev-configured",
            headers: ["X-Scope": "configured"],
            retryPolicy: .disabled
        )
        let client = try JevClient(configuration: configuration, transport: transport)
        let state: JSONValue = ["message": "Export crashes", "plan": "business"]
        let questions: [String: Question] = [
            "team": .choice(
                instructions: "Which team?",
                criteria: ["technical": "Product fault", "billing": "Payment", "other": "Neither"]
            ),
            "impact": .score(
                instructions: "How blocked?", criteria: ["None", "Some", "Blocked"]
            ),
            "refund": .noul(instructions: "Does the message ask for a refund?")
        ]

        let result = try await client.evaluate(
            state: state,
            questions: questions,
            options: RequestOptions(headers: ["X-Scope": "per-call"]),
            validation: .strict(tolerance: 0.01)
        )
        #expect(try result.value.choice("team").choice == "technical")
        #expect(try result.value.score("impact").score == 1.6)
        #expect(try result.value.noul("refund").noul == 0.03)
        #expect(result.model == "jev-resolved")
        #expect(result.usage?.inputTokens == 70)
        #expect(result.usage?.outputTokens == 9)
        #expect(result.value.model == "jev-resolved")
        #expect(result.metadata.statusCode == 200)
        #expect(result.metadata.requestID == "request-fixture")
        #expect(result.metadata.attempts == 1)
        #expect(result.body == Data(responseBody.utf8))

        _ = try await client.evaluate(state: state, questions: questions, model: "jev-override")
        _ = try await client.systemOne(
            SystemOneRequest(state: state, model: "jev-explicit", questions: questions)
        )

        let sent = await transport.recorded()
        #expect(sent.count == 3)
        #expect(sent[0].method == "POST")
        #expect(sent[0].url == "https://api.typesafe.ai/v1/systemone")
        #expect(sent[0].header("Authorization") == "Bearer test-key")
        #expect(sent[0].header("Content-Type") == "application/json")
        #expect(sent[0].header("X-Scope") == "per-call")
        #expect(sent[0].timeout == 30)
        let wire = try JSONDecoder().decode(JSONValue.self, from: try #require(sent[0].body))
        #expect(wire == [
            "state": ["message": "Export crashes", "plan": "business"],
            "model": "jev-configured",
            "questions": [
                "team": [
                    "type": "choice", "instructions": "Which team?",
                    "criteria": [
                        "technical": "Product fault", "billing": "Payment", "other": "Neither"
                    ]
                ],
                "impact": [
                    "type": "score", "instructions": "How blocked?",
                    "criteria": ["None", "Some", "Blocked"]
                ],
                "refund": ["type": "noul", "instructions": "Does the message ask for a refund?"]
            ]
        ])
        let overrideWire = try JSONDecoder().decode(JSONValue.self, from: try #require(sent[1].body))
        let explicitWire = try JSONDecoder().decode(JSONValue.self, from: try #require(sent[2].body))
        guard case .object(let overrideObject) = overrideWire,
              case .object(let explicitObject) = explicitWire else {
            Issue.record("Expected object requests")
            return
        }
        #expect(overrideObject["model"] == "jev-override")
        #expect(explicitObject["model"] == "jev-explicit")
    }

    // Single-question and enum helpers must retain response context and reject unmappable labels.
    @Test func singleAndEnumConveniences() async throws {
        let typedResult = """
        {"model":"jev-resolved","answers":{"result":{"type":"choice","choice":"technical","probabilities":{"technical":0.8,"billing":0.1,"other":0.1},"confidence":0.7}},"usage":{"input_tokens":12,"output_tokens":4}}
        """
        let malformedChoice = """
        {"model":"jev-resolved","answers":{"result":{"type":"choice","choice":"unknown","probabilities":{"technical":0.8,"billing":0.1,"other":0.1},"confidence":0.7}}}
        """
        let transport = RecordingTransport([
            fixture(choiceResult), fixture(scoreResult), fixture(noulResult),
            fixture(typedResult), fixture(malformedChoice)
        ])
        let client = try JevClient(apiKey: "test-key", transport: transport)
        let choice = try await client.choice(
            state: "Export crashes", instructions: "Which team?",
            criteria: ["technical": "Product fault", "billing": "Payment"]
        )
        let score = try await client.score(
            state: "Export crashes", instructions: "How blocked?",
            criteria: ["None", "Some", "Blocked"]
        )
        let noul = try await client.noul(
            state: "Export crashes", instructions: "Is this a product fault?"
        )
        #expect(choice.value.choice == "technical")
        #expect(score.value.score == 1.6)
        #expect(noul.value.noul == 0.8)
        for metadata in [choice.metadata, score.metadata, noul.metadata] {
            #expect(metadata.requestID == "request-fixture")
            #expect(metadata.attempts == 1)
        }
        #expect(choice.model == "jev-resolved" && score.model == "jev-resolved")
        #expect(noul.model == "jev-resolved")
        #expect(choice.usage?.inputTokens == 12 && score.usage?.outputTokens == 4)
        #expect(noul.usage?.inputTokens == 12)
        #expect(choice.body == Data(choiceResult.utf8))
        #expect(score.body == Data(scoreResult.utf8))
        #expect(noul.body == Data(noulResult.utf8))

        let typed = try await client.choice(
            state: "Export crashes", instructions: "Which team?", choices: Team.self,
            descriptions: [
                .technical: "Product fault", .billing: "Payment", .other: "Neither"
            ]
        )
        #expect(typed.value.choice == .technical)
        #expect(typed.value.probabilities == [
            .technical: 0.8, .billing: 0.1, .other: 0.1
        ])
        #expect(typed.model == "jev-resolved")
        #expect(typed.usage?.outputTokens == 4)
        #expect(typed.body == Data(typedResult.utf8))
        let sent = await transport.recorded()
        #expect(sent.count == 4)
        let typedWire = try JSONDecoder().decode(JSONValue.self, from: try #require(sent[3].body))
        guard case .object(let root) = typedWire,
              case .object(let questions)? = root["questions"],
              case .object(let result)? = questions["result"],
              case .object(let criteria)? = result["criteria"] else {
            Issue.record("Typed Choice did not send criterion descriptions")
            return
        }
        #expect(criteria == [
            "technical": "Product fault", "billing": "Payment", "other": "Neither"
        ])

        do {
            _ = try await client.choice(state: "x", choices: DuplicateCase.self)
            Issue.record("Expected duplicate raw labels to fail locally")
        } catch let error as JevValidationError {
            #expect(error.path == "choices")
        }
        do {
            _ = try await client.choice(
                state: "x", choices: SparseCase.self, descriptions: [.hidden: "Hidden"]
            )
            Issue.record("Expected unknown description case to fail locally")
        } catch let error as JevValidationError {
            #expect(error.path == "descriptions")
        }
        #expect(await transport.recorded().count == 4)

        do {
            _ = try await client.choice(
                state: "x", choices: Team.self,
                descriptions: [.technical: "Technical", .billing: "Billing", .other: "Other"]
            )
            Issue.record("Expected unknown service label to fail")
        } catch JevError.invalidResponse(let reason, let metadata) {
            #expect(reason.contains("answers.result.choice"))
            #expect(metadata.requestID == "request-fixture")
        }
    }

    // Bad local inputs, malformed service data, HTTP failures, and cancellation need distinct errors.
    @Test func rejectsInvalidInputAndResponses() async throws {
        let malformedJSON = "{"
        let missingDecision = """
        {"model":"jev-resolved","answers":{"result":{"type":"noul"}}}
        """
        let wrongType = """
        {"model":"jev-resolved","answers":{"result":{"type":"choice","choice":"yes","probabilities":{"yes":1},"confidence":1}}}
        """
        let outOfRange = """
        {"model":"jev-resolved","answers":{"result":{"type":"noul","noul":1.2}}}
        """
        let wrongID = """
        {"model":"jev-resolved","answers":{"other":{"type":"noul","noul":0.5}}}
        """
        let httpJSON = "{\"error\":\"bad key\"}"
        let httpText = "Permission denied"
        let responses = [
            fixture(malformedJSON), fixture(missingDecision),
            fixture(wrongType), fixture(outOfRange), fixture(wrongID),
            fixture(httpJSON, status: 401),
            fixture(httpText, status: 403),
            fixture("", status: 422)
        ]
        let transport = RecordingTransport(responses)
        let client = try JevClient(configuration: JevConfiguration(
            authentication: .apiKey("test-key"), retryPolicy: .disabled
        ), transport: transport)

        do {
            _ = try await client.noul(state: .number(4), instructions: "Is this true?")
            Issue.record("Expected invalid top-level state to fail locally")
        } catch let error as JevValidationError {
            #expect(error.path == "state")
        }
        do {
            _ = try await client.evaluate(state: "message", questions: [:])
            Issue.record("Expected an empty question map to fail locally")
        } catch let error as JevValidationError {
            #expect(error.path == "questions")
        }
        do {
            _ = try await client.evaluate(
                state: "message",
                questions: ["result": .noul(instructions: "Is this true?")],
                validation: .strict(tolerance: .nan)
            )
            Issue.record("Expected invalid strict policy to fail locally")
        } catch let error as JevValidationError {
            #expect(error.path == "policy.tolerance")
        }
        #expect((await transport.recorded()).isEmpty)

        for raw in [malformedJSON, missingDecision] {
            do {
                _ = try await client.noul(state: "message", instructions: "Is this true?")
                Issue.record("Expected a decoding failure")
            } catch JevError.decoding(let message, let metadata, let body) {
                #expect(message == "Could not decode the System One response.")
                #expect(metadata.requestID == "request-fixture")
                #expect(body == Data(raw.utf8))
            }
        }
        for expectedPath in [
            "answers.result.type", "answers.result.noul", "answers.result"
        ] {
            do {
                _ = try await client.noul(state: "message", instructions: "Is this true?")
                Issue.record("Expected response validation failure")
            } catch JevError.invalidResponse(let reason, let metadata) {
                #expect(reason.contains(expectedPath))
                #expect(metadata.requestID == "request-fixture")
            }
        }
        for (status, raw) in [(401, httpJSON), (403, httpText), (422, "")] {
            do {
                _ = try await client.noul(state: "message", instructions: "Is this true?")
                Issue.record("Expected HTTP error \(status)")
            } catch JevError.http(let error) {
                #expect(error.statusCode == status)
                #expect(error.body == Data(raw.utf8))
                #expect(error.requestID == "request-fixture")
                #expect(error.attempts == 1)
            }
        }
        #expect((await transport.recorded()).count == 8)

        let cancelled = try JevClient(apiKey: "test-key", transport: CancelledTransport())
        do {
            _ = try await cancelled.noul(state: "message", instructions: "Is this true?")
            Issue.record("Expected native CancellationError")
        } catch is CancellationError {
            // Cancellation must not be wrapped as a transport error.
        }
    }

    // Model discovery has a separate GET wire shape and preserves release-date strings.
    @Test func listsModels() async throws {
        let raw = """
        {"models":[{"name":"jev-latest","description":"Latest stable","release_date":"2026-09-01","future_field":true}],"extra":42}
        """
        let transport = RecordingTransport([fixture(raw, requestID: "models-request")])
        let client = try JevClient(configuration: JevConfiguration(
            authentication: .apiKey("test-key"),
            headers: ["X-Trace": "configured"], retryPolicy: .disabled
        ), transport: transport)
        let result = try await client.models(options: RequestOptions(headers: ["X-Trace": "per-call"]))
        #expect(result.value == [ModelCard(
            name: "jev-latest", description: "Latest stable", releaseDate: "2026-09-01"
        )])
        #expect(result.metadata.requestID == "models-request")
        #expect(result.metadata.statusCode == 200)
        #expect(result.body == Data(raw.utf8))
        #expect(result.model == nil && result.usage == nil)
        let sent = await transport.recorded()
        #expect(sent.count == 1)
        #expect(sent[0].method == "GET")
        #expect(sent[0].url == "https://api.typesafe.ai/v1/models")
        #expect(sent[0].body == nil)
        #expect(sent[0].header("Authorization") == "Bearer test-key")
        #expect(sent[0].header("X-Trace") == "per-call")
    }

    // An empty model catalog is valid; malformed catalogs must not become silent empty results.
    @Test func rejectsMalformedModels() async throws {
        let empty = #"{"models":[]}"#
        let wrongEnvelope = "[]"
        let missingField = #"{"models":[{"name":"jev","description":"Stable"}]}"#
        let wrongType = #"{"models":[{"name":12,"description":"Stable","release_date":"2026-09-01"}]}"#
        let blankName = #"{"models":[{"name":"  ","description":"Stable","release_date":"2026-09-01"}]}"#
        let transport = RecordingTransport([
            fixture(empty), fixture(wrongEnvelope), fixture(missingField),
            fixture(wrongType), fixture(blankName)
        ])
        let client = try JevClient(apiKey: "test-key", transport: transport)
        let validEmpty = try await client.models()
        #expect(validEmpty.value.isEmpty)

        for raw in [wrongEnvelope, missingField, wrongType] {
            do {
                _ = try await client.models()
                Issue.record("Expected malformed model catalog to fail decoding")
            } catch JevError.decoding(let message, let metadata, let body) {
                #expect(message == "Could not decode the models response.")
                #expect(metadata.requestID == "request-fixture")
                #expect(body == Data(raw.utf8))
            }
        }
        do {
            _ = try await client.models()
            Issue.record("Expected blank model name to fail validation")
        } catch JevError.invalidResponse(let reason, let metadata) {
            #expect(reason.contains("models[0].name"))
            #expect(metadata.requestID == "request-fixture")
        }
        #expect((await transport.recorded()).count == 5)
    }

    // README examples must work through the public module, including Codable state and concurrent use.
    @Test func documentationExamples() async throws {
        let batch = """
        {"model":"jev-resolved","answers":{"team":{"type":"choice","choice":"technical","probabilities":{"technical":0.8,"billing":0.1,"other":0.1},"confidence":0.7},"impact":{"type":"score","score":1.6,"legend":{"0":"The workflow works normally.","1":"The workflow is impaired but has a workaround.","2":"The workflow cannot be completed."},"probabilities":{"0":0.1,"1":0.2,"2":0.7},"confidence":0.7},"refund":{"type":"noul","noul":0.02}},"usage":{"input_tokens":30}}
        """
        let typed = """
        {"model":"jev-resolved","answers":{"result":{"type":"choice","choice":"technical","probabilities":{"technical":0.8,"billing":0.1,"other":0.1},"confidence":0.7}}}
        """
        let recording = RecordingTransport([
            fixture(noulResult), fixture(batch), fixture(typed),
            fixture(noulResult), fixture(noulResult), fixture(noulResult)
        ])
        let client = try JevClient(
            apiKey: "test-key", transport: TimedTransport(underlying: recording)
        )
        let simple = try await client.noul(
            state: "Please refund the payment for last month.",
            instructions: "Does this message explicitly request the return of money already paid?"
        )
        #expect(simple.value.noul == 0.8)
        #expect(simple.metadata.requestID == "request-fixture")

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
        #expect(try result.value.choice("team").choice == "technical")
        #expect(try result.value.score("impact").score == 1.6)
        #expect(try result.value.noul("refund").noul == 0.02)
        #expect(result.model == "jev-resolved" && result.usage?.inputTokens == 30)

        let decision = try await client.choice(
            state: "The export button crashes the app.",
            instructions: "Which team should handle the primary issue?",
            choices: Team.self,
            descriptions: [
                .technical: "A product malfunction", .billing: "Payments or invoices",
                .other: "Neither team fits"
            ]
        )
        #expect(decision.value.choice == .technical)
        #expect(decision.value.probabilities[.technical] == 0.8)

        struct Ticket: Codable, Sendable {
            let message: String
            let priority: Int
        }
        let ticket = Ticket(message: "Export fails", priority: 2)
        let state = try JSONValue.encoding(ticket)
        let structured = try await client.noul(
            state: state,
            instructions: "Does this ticket describe a product malfunction?"
        )
        #expect(structured.value.noul == 0.8)

        async let first = client.noul(
            state: "Please cancel renewal.", instructions: "Cancel next renewal?"
        )
        async let second = client.noul(
            state: "Please return my payment.", instructions: "Request refund?"
        )
        let (firstResult, secondResult) = try await (first, second)
        #expect(firstResult.value.noul == 0.8)
        #expect(secondResult.value.noul == 0.8)
        let sent = await recording.recorded()
        #expect(sent.count == 6)
        let structuredWire = try JSONDecoder().decode(JSONValue.self, from: try #require(sent[3].body))
        guard case .object(let root) = structuredWire else {
            Issue.record("Expected structured request")
            return
        }
        #expect(root["state"] == ["message": "Export fails", "priority": 2])
        let concurrentStates = try sent[4...5].map { captured -> JSONValue? in
            let wire = try JSONDecoder().decode(JSONValue.self, from: try #require(captured.body))
            guard case .object(let root) = wire else { return nil }
            return root["state"]
        }
        let states = concurrentStates.compactMap { $0 }
        #expect(states.count == 2)
        #expect(states.contains("Please cancel renewal."))
        #expect(states.contains("Please return my payment."))
    }
}
