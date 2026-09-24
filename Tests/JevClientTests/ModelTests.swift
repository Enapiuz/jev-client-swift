import Foundation
import Testing
@testable import JevClient

private struct DatedRecord: Codable, Equatable {
    let createdAt: Date
}

private enum Route: String {
    case accept
    case reject
}

private func canonicalJSON(_ data: Data) throws -> Data {
    let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
}

private func expectValidationError(
    at expectedPath: String,
    _ operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected validation error at \(expectedPath)")
    } catch let error as JevValidationError {
        #expect(error.path == expectedPath)
        #expect(!error.message.isEmpty)
    } catch {
        Issue.record("Expected JevValidationError at \(expectedPath), got \(error)")
    }
}

private func expectDecodingFailure<T: Decodable>(_ type: T.Type, json: String) {
    do {
        _ = try JSONDecoder().decode(type, from: Data(json.utf8))
        Issue.record("Expected decoding failure for \(json)")
    } catch is DecodingError {
        // A malformed decision must not acquire a synthetic default.
    } catch {
        Issue.record("Expected DecodingError, got \(error)")
    }
}

private func mixedRequest() -> SystemOneRequest {
    SystemOneRequest(state: "Evidence", questions: [
        "route": .choice(instructions: "Choose a route", criteria: ["accept": "Accept", "reject": "Reject"]),
        "grade": .score(instructions: "Grade severity", criteria: ["low", "medium", "high"]),
        "flag": .noul(instructions: "Is it flagged?")
    ])
}

private func mixedResponse() -> SystemOneResponse {
    SystemOneResponse(model: "jev-resolved", answers: [
        "route": .choice(.init(choice: "accept", probabilities: ["accept": 0.6, "reject": 0.4], confidence: 0.8)),
        "grade": .score(.init(
            score: 1.0,
            legend: ["0": "low", "1": "medium", "2": "high"],
            probabilities: ["0": 0.25, "1": 0.5, "2": 0.25], confidence: 0.7
        )),
        "flag": .noul(.init(noul: 0.2))
    ], usage: .init(inputTokens: 12, outputTokens: 4))
}

struct ModelTests {
    // The boundary must retain integers beyond binary64 precision and honor caller JSON strategies.
    @Test func jsonPreservesIntegers() throws {
        let fixture = #"{"min":-9223372036854775808,"beyondSafe":9007199254740993,"max":18446744073709551615,"nested":[true,null,{"n":18446744073709551615}]}"#
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(fixture.utf8))
        guard case .object(let fields) = decoded else {
            Issue.record("Expected a JSON object")
            return
        }
        #expect(fields["min"] == .integer(Int64.min))
        #expect(fields["beyondSafe"] == .integer(9_007_199_254_740_993))
        #expect(fields["max"] == .unsignedInteger(UInt64.max))
        #expect(fields["nested"] == .array([.bool(true), .null, .object(["n": .unsignedInteger(UInt64.max)])]))

        let literal: JSONValue = ["enabled": true, "absent": nil, "items": [1, "two", false]]
        #expect(literal == .object([
            "enabled": .bool(true), "absent": .null,
            "items": .array([.integer(1), .string("two"), .bool(false)])
        ]))
        let repeatedKey: JSONValue = ["key": 1, "key": 2]
        #expect(repeatedKey == .object(["key": .integer(2)]))
        #expect(String(decoding: try JSONEncoder().encode(JSONValue.integer(Int64.min)), as: UTF8.self) == "-9223372036854775808")
        #expect(String(decoding: try JSONEncoder().encode(JSONValue.unsignedInteger(UInt64.max)), as: UTF8.self) == "18446744073709551615")
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(decoded)) == decoded)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let record = DatedRecord(createdAt: Date(timeIntervalSince1970: 0))
        let value = try JSONValue.encoding(record, encoder: encoder)
        #expect(value == .object(["created_at": .string("1970-01-01T00:00:00Z")]))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        #expect(try value.decode(DatedRecord.self, decoder: decoder) == record)

        do {
            _ = try JSONEncoder().encode(JSONValue.number(.infinity))
            Issue.record("Nonfinite JSON must not encode")
        } catch is EncodingError {
            // Expected: no JSON numeric representation exists for infinity.
        }
    }

    // A hand-written wire fixture catches envelope and discriminator drift that round trips could hide.
    @Test func encodesRequestEnvelope() throws {
        let request = SystemOneRequest(state: ["message": "Hello", "count": 2], model: .preview, questions: [
            "route": .choice(
                instructions: ["goal": "route", "examples": ["refund", "question"]],
                criteria: ["billing": .null, "support": ["meaning": "A product problem"]]
            ),
            "grade": .score(criteria: ["low", ["meaning": "high"]]),
            "flag": .noul(
                instructions: .null,
                criteria: NoulCriteria(trueDescription: "Explicit", falseDescription: .null)
            ),
            "bare": .noul()
        ])
        let expected = #"""
        {
          "state":{"message":"Hello","count":2},
          "model":"jev-preview",
          "questions":{
            "route":{"type":"choice","instructions":{"goal":"route","examples":["refund","question"]},"criteria":{"billing":null,"support":{"meaning":"A product problem"}}},
            "grade":{"type":"score","criteria":["low",{"meaning":"high"}]},
            "flag":{"type":"noul","instructions":null,"criteria":{"true":"Explicit","false":null}},
            "bare":{"type":"noul"}
          }
        }
        """#
        #expect(try canonicalJSON(JSONEncoder().encode(request)) == canonicalJSON(Data(expected.utf8)))
        let decoded = try JSONDecoder().decode(SystemOneRequest.self, from: Data(expected.utf8))
        #expect(decoded == request)
        guard let bare = decoded.questions["bare"],
              case .noul(let missingInstructions, let missingCriteria) = bare,
              let flag = decoded.questions["flag"],
              case .noul(let nullInstructions, let flagCriteria) = flag,
              let grade = decoded.questions["grade"],
              case .score(let missingScoreInstructions, _) = grade else {
            Issue.record("Expected the authored question kinds")
            return
        }
        #expect(missingInstructions == Optional<JSONValue>.none)
        #expect(missingCriteria == nil)
        #expect(missingScoreInstructions == Optional<JSONValue>.none)
        #expect(nullInstructions == Optional<JSONValue>.some(.null))
        #expect(flagCriteria?.falseDescription == Optional<JSONValue>.some(.null))
        try request.validate()
    }

    // Request validation must accept documented boundaries and identify bad input without mutating it.
    @Test func rejectsInvalidRequests() throws {
        let original = SystemOneRequest(state: "Evidence", questions: ["q": .noul(instructions: "Is this true?")])
        try original.validate()
        try SystemOneRequest(state: "Evidence", questions: ["q": .choice(criteria: ["only": "description"])]).validate()
        let maxLabels = Dictionary(uniqueKeysWithValues: (0..<255).map { ("label\($0)", JSONValue.string("description")) })
        try SystemOneRequest(state: "Evidence", questions: ["q": .choice(criteria: maxLabels)]).validate()
        try SystemOneRequest(state: "Evidence", questions: ["q": .score(criteria: ["low", "high"])]).validate()
        try SystemOneRequest(state: "Evidence", questions: ["q": .score(criteria: Array(repeating: "level" as JSONValue, count: 10))]).validate()

        for state in [JSONValue.null, .integer(1), .bool(false)] {
            var invalid = original
            invalid.state = state
            expectValidationError(at: "state") { try invalid.validate() }
        }
        var invalid = original
        invalid.state = ["nested": [.number(.infinity)]]
        expectValidationError(at: "state.nested[0]") { try invalid.validate() }
        invalid = original
        invalid.model = "  "
        expectValidationError(at: "model") { try invalid.validate() }
        invalid = original
        invalid.questions = [:]
        expectValidationError(at: "questions") { try invalid.validate() }
        invalid.questions = ["  ": .noul()]
        expectValidationError(at: "questions") { try invalid.validate() }
        invalid.questions = ["q": .choice(criteria: [:])]
        expectValidationError(at: "questions.q.criteria") { try invalid.validate() }
        invalid.questions = ["q": .choice(criteria: Dictionary(uniqueKeysWithValues: (0..<256).map { ("label\($0)", JSONValue.string("description")) }))]
        expectValidationError(at: "questions.q.criteria") { try invalid.validate() }
        invalid.questions = ["q": .choice(criteria: ["  ": "description"])]
        expectValidationError(at: "questions.q.criteria") { try invalid.validate() }
        invalid.questions = ["q": .choice(criteria: ["only": .integer(1)])]
        expectValidationError(at: "questions.q.criteria.only") { try invalid.validate() }
        invalid.questions = ["q": .score(criteria: ["only"])]
        expectValidationError(at: "questions.q.criteria") { try invalid.validate() }
        invalid.questions = ["q": .score(criteria: Array(repeating: "level" as JSONValue, count: 11))]
        expectValidationError(at: "questions.q.criteria") { try invalid.validate() }
        invalid.questions = ["q": .score(criteria: ["low", .null])]
        expectValidationError(at: "questions.q.criteria[1]") { try invalid.validate() }
        invalid.questions = ["q": .noul(instructions: .integer(1))]
        expectValidationError(at: "questions.q.instructions") { try invalid.validate() }
        invalid.questions = ["q": .noul(criteria: .init(falseDescription: .bool(false)))]
        expectValidationError(at: "questions.q.criteria.false") { try invalid.validate() }
        invalid.questions = ["q": .choice(criteria: ["only": ["nested": .number(.nan)]])]
        expectValidationError(at: "questions.q.criteria.only.nested") { try invalid.validate() }
        #expect(original == SystemOneRequest(state: "Evidence", questions: ["q": .noul(instructions: "Is this true?")]))
    }

    // Independently authored responses establish the required decision fields and tolerate additive fields.
    @Test func decodesAllAnswerTypes() throws {
        let fixture = #"""
        {
          "model":"jev-1.13.0",
          "answers":{
            "route":{"type":"choice","choice":"accept","probabilities":{"accept":0.7,"reject":0.3},"confidence":0.8,"future":"ignored"},
            "grade":{"type":"score","score":1.25,"legend":{"0":"low","1":"medium","2":"high"},"probabilities":{"0":0.125,"1":0.5,"2":0.375},"confidence":0.6},
            "flag":{"type":"noul","noul":0.9,"future":{"version":2}}
          },
          "usage":{"input_tokens":12,"output_tokens":4,"future":7},
          "future":{"trace":"ignored"}
        }
        """#
        let response = try JSONDecoder().decode(SystemOneResponse.self, from: Data(fixture.utf8))
        #expect(response.model == "jev-1.13.0")
        #expect(response.answers.count == 3)
        #expect(response.answers["route"]?.type == "choice")
        #expect(response.answers["grade"]?.type == "score")
        #expect(response.answers["flag"]?.type == "noul")
        let choice = try response.choice("route")
        let score = try response.score("grade")
        let noul = try response.noul("flag")
        #expect(choice == ChoiceAnswer(choice: "accept", probabilities: ["accept": 0.7, "reject": 0.3], confidence: 0.8))
        #expect(score == ScoreAnswer(score: 1.25, legend: ["0": "low", "1": "medium", "2": "high"], probabilities: ["0": 0.125, "1": 0.5, "2": 0.375], confidence: 0.6))
        #expect(noul == NoulAnswer(noul: 0.9))
        #expect(response.usage == Usage(inputTokens: 12, outputTokens: 4))

        for invalid in [
            #"{"choice":"accept","probabilities":{"accept":1},"confidence":1}"#,
            #"{"type":"future","future":1}"#,
            #"{"type":"choice","probabilities":{"accept":1},"confidence":1}"#,
            #"{"type":"choice","choice":"accept","confidence":1}"#,
            #"{"type":"choice","choice":"accept","probabilities":{"accept":1}}"#,
            #"{"type":"score","legend":{"0":"low"},"probabilities":{"0":1},"confidence":1}"#,
            #"{"type":"score","score":0,"probabilities":{"0":1},"confidence":1}"#,
            #"{"type":"noul"}"#
        ] {
            expectDecodingFailure(Answer.self, json: invalid)
        }
    }

    // The models endpoint has its own envelope and snake-case release date field.
    @Test func decodesModelList() throws {
        let wire = #"{"models":[{"name":"jev-latest","description":"Current alias","release_date":"2026-09-01"}]}"#
        let list = try JSONDecoder().decode(ListModelsResponse.self, from: Data(wire.utf8))
        #expect(list.models == [ModelCard(name: "jev-latest", description: "Current alias", releaseDate: "2026-09-01")])
        #expect(try canonicalJSON(JSONEncoder().encode(list)) == canonicalJSON(Data(wire.utf8)))
    }

    // Every decision and ID must agree with its request before an application can act on it.
    @Test func rejectsInvalidResponses() throws {
        let request = mixedRequest()
        let valid = mixedResponse()
        try valid.validate(for: request)

        func check(_ path: String, _ change: (inout SystemOneResponse) -> Void) {
            var response = valid
            change(&response)
            expectValidationError(at: path) { try response.validate(for: request) }
        }

        check("answers.flag") { _ = $0.answers.removeValue(forKey: "flag") }
        check("answers.unasked") { $0.answers["unasked"] = .noul(.init(noul: 0.5)) }
        check("answers.flag.type") { $0.answers["flag"] = .choice(.init(choice: "accept", probabilities: ["accept": 1], confidence: 1)) }
        check("answers.route.choice") { $0.answers["route"] = .choice(.init(choice: "unknown", probabilities: ["accept": 0.6, "reject": 0.4], confidence: 0.8)) }
        check("answers.route.probabilities") { $0.answers["route"] = .choice(.init(choice: "accept", probabilities: ["accept": 1], confidence: 0.8)) }
        check("answers.route.probabilities.accept") { $0.answers["route"] = .choice(.init(choice: "accept", probabilities: ["accept": -0.1, "reject": 0.4], confidence: 0.8)) }
        check("answers.route.probabilities.accept") { $0.answers["route"] = .choice(.init(choice: "accept", probabilities: ["accept": 1.1, "reject": 0.4], confidence: 0.8)) }
        check("answers.route.probabilities.accept") { $0.answers["route"] = .choice(.init(choice: "accept", probabilities: ["accept": .infinity, "reject": 0.4], confidence: 0.8)) }
        check("answers.route.confidence") { $0.answers["route"] = .choice(.init(choice: "accept", probabilities: ["accept": 0.6, "reject": 0.4], confidence: .nan)) }
        check("answers.route.confidence") { $0.answers["route"] = .choice(.init(choice: "accept", probabilities: ["accept": 0.6, "reject": 0.4], confidence: 1.1)) }
        check("answers.flag.noul") { $0.answers["flag"] = .noul(.init(noul: -0.1)) }
        check("answers.flag.noul") { $0.answers["flag"] = .noul(.init(noul: 1.1)) }
        check("answers.flag.noul") { $0.answers["flag"] = .noul(.init(noul: .nan)) }
        check("model") { $0.model = " \n " }
        check("answers.grade.score") { $0.answers["grade"] = .score(.init(score: 2.1, legend: ["0": "low", "1": "medium", "2": "high"], probabilities: ["0": 0.25, "1": 0.5, "2": 0.25], confidence: 0.7)) }
        check("answers.grade.score") { $0.answers["grade"] = .score(.init(score: .infinity, legend: ["0": "low", "1": "medium", "2": "high"], probabilities: ["0": 0.25, "1": 0.5, "2": 0.25], confidence: 0.7)) }
        check("answers.grade.legend") { $0.answers["grade"] = .score(.init(score: 1, legend: ["0": "low", "2": "high"], probabilities: ["0": 0.25, "1": 0.5, "2": 0.25], confidence: 0.7)) }
        check("answers.grade.legend.1") { $0.answers["grade"] = .score(.init(score: 1, legend: ["0": "low", "1": .bool(true), "2": "high"], probabilities: ["0": 0.25, "1": 0.5, "2": 0.25], confidence: 0.7)) }
        check("answers.grade.probabilities") { $0.answers["grade"] = .score(.init(score: 1, legend: ["0": "low", "1": "medium", "2": "high"], probabilities: ["0": 0.5, "2": 0.5], confidence: 0.7)) }
    }

    // Strict mode guards numerical relationships while standard mode accepts rounded or altered echoes.
    @Test func strictValidationChecksRelations() throws {
        let request = mixedRequest()
        let tied = SystemOneResponse(model: "jev-resolved", answers: [
            "route": .choice(.init(choice: "accept", probabilities: ["accept": 0.5, "reject": 0.5], confidence: 0.8)),
            "grade": .score(.init(score: 1, legend: ["0": "low", "1": "medium", "2": "high"], probabilities: ["0": 0.25, "1": 0.5, "2": 0.25], confidence: 0.7)),
            "flag": .noul(.init(noul: 0.2))
        ])
        try tied.validate(for: request, policy: .strict(tolerance: 0.01))

        var rounded = tied
        rounded.answers["route"] = .choice(.init(choice: "reject", probabilities: ["accept": 0.5004, "reject": 0.4996], confidence: 0.8))
        rounded.answers["grade"] = .score(.init(score: 1.005, legend: ["0": "changed", "1": "medium", "2": "high"], probabilities: ["0": 0.25, "1": 0.5, "2": 0.25], confidence: 0.7))
        try rounded.validate(for: request)
        rounded.answers["grade"] = .score(.init(score: 1.005, legend: ["0": "low", "1": "medium", "2": "high"], probabilities: ["0": 0.25, "1": 0.5, "2": 0.25], confidence: 0.7))
        try rounded.validate(for: request, policy: .strict(tolerance: 0.01))

        func check(_ path: String, _ change: (inout SystemOneResponse) -> Void) {
            var response = tied
            change(&response)
            expectValidationError(at: path) { try response.validate(for: request, policy: .strict(tolerance: 0.01)) }
        }
        check("answers.route.probabilities") { $0.answers["route"] = .choice(.init(choice: "accept", probabilities: ["accept": 0.7, "reject": 0.4], confidence: 0.8)) }
        check("answers.route.choice") { $0.answers["route"] = .choice(.init(choice: "accept", probabilities: ["accept": 0.1, "reject": 0.9], confidence: 0.8)) }
        check("answers.grade.score") { $0.answers["grade"] = .score(.init(score: 1.2, legend: ["0": "low", "1": "medium", "2": "high"], probabilities: ["0": 0.25, "1": 0.5, "2": 0.25], confidence: 0.7)) }
        check("answers.grade.legend.0") { $0.answers["grade"] = .score(.init(score: 1, legend: ["0": "changed", "1": "medium", "2": "high"], probabilities: ["0": 0.25, "1": 0.5, "2": 0.25], confidence: 0.7)) }
        for tolerance in [Double.nan, -0.01, 0.11, .infinity] {
            expectValidationError(at: "policy.tolerance") { try tied.validate(for: request, policy: .strict(tolerance: tolerance)) }
        }

        let structuredRubric: [JSONValue] = [
            .object(["numbers": .array([.number(1.0), .unsignedInteger(1), .integer(Int64.max)])]),
            .object([
                "large": .integer(9_007_199_254_740_993),
                "ordered": .array([.string("first"), .string("second")])
            ])
        ]
        let structuredRequest = SystemOneRequest(state: "Evidence", questions: [
            "grade": .score(criteria: structuredRubric)
        ])
        let structuredWire = #"""
        {"model":"jev-resolved","answers":{"grade":{"type":"score","score":0.75,"legend":{"0":{"numbers":[1,1,9223372036854775807]},"1":{"large":9007199254740993,"ordered":["first","second"]}},"probabilities":{"0":0.25,"1":0.75},"confidence":0.8}}}
        """#
        let structuredResponse = try JSONDecoder().decode(SystemOneResponse.self, from: Data(structuredWire.utf8))
        try structuredResponse.validate(for: structuredRequest, policy: .strict(tolerance: 0.01))
        let structuredScore = try structuredResponse.score("grade")

        // The raw echo's integer also matches an exactly representable unsigned or Double value.
        var alternate = structuredResponse
        var alternateLegend = structuredScore.legend
        alternateLegend["0"] = .object(["numbers": .array([.integer(1), .number(1.0), .integer(Int64.max)])])
        alternate.answers["grade"] = .score(.init(
            score: structuredScore.score, legend: alternateLegend,
            probabilities: structuredScore.probabilities, confidence: structuredScore.confidence
        ))
        try alternate.validate(for: structuredRequest, policy: .strict(tolerance: 0.01))

        func checkStructuredLegend(_ index: String, value: JSONValue) {
            var response = structuredResponse
            var legend = structuredScore.legend
            legend[index] = value
            response.answers["grade"] = .score(.init(
                score: structuredScore.score, legend: legend,
                probabilities: structuredScore.probabilities, confidence: structuredScore.confidence
            ))
            expectValidationError(at: "answers.grade.legend.\(index)") {
                try response.validate(for: structuredRequest, policy: .strict(tolerance: 0.01))
            }
        }
        checkStructuredLegend("1", value: .object([
            "large": .number(9_007_199_254_740_992.0),
            "ordered": .array([.string("first"), .string("second")])
        ]))
        checkStructuredLegend("0", value: .object([
            "numbers": .array([.bool(true), .integer(1), .integer(Int64.max)])
        ]))
        checkStructuredLegend("1", value: .object([
            "large": .integer(9_007_199_254_740_993),
            "ordered": .array([.string("second"), .string("first")])
        ]))

        let withFutureField = #"""
        {"model":"jev-resolved","answers":{"route":{"type":"choice","choice":"accept","probabilities":{"accept":0.5,"reject":0.5},"confidence":0.8},"grade":{"type":"score","score":1,"legend":{"0":"low","1":"medium","2":"high"},"probabilities":{"0":0.25,"1":0.5,"2":0.25},"confidence":0.7},"flag":{"type":"noul","noul":0.2}},"usage":{"input_tokens":null,"future_count":9},"future_metadata":{"trace":"x"}}
        """#
        let decoded = try JSONDecoder().decode(SystemOneResponse.self, from: Data(withFutureField.utf8))
        #expect(decoded.usage?.inputTokens == nil)
        #expect(decoded.usage?.outputTokens == nil)
        try decoded.validate(for: request, policy: .strict(tolerance: 0.01))
    }

    // Missing metadata stays distinct from zero, and typed access must fail rather than invent answers.
    @Test func preservesUnknownUsageAndTypedAccess() throws {
        let request = mixedRequest()
        let noUsageWire = #"{"model":"jev-resolved","answers":{"route":{"type":"choice","choice":"accept","probabilities":{"accept":0.6,"reject":0.4},"confidence":0.8},"grade":{"type":"score","score":1,"legend":{"0":"low","1":"medium","2":"high"},"probabilities":{"0":0.25,"1":0.5,"2":0.25},"confidence":0.7},"flag":{"type":"noul","noul":0.2}}}"#
        let noUsage = try JSONDecoder().decode(SystemOneResponse.self, from: Data(noUsageWire.utf8))
        #expect(noUsage.usage == nil)
        try noUsage.validate(for: request)
        let partialUsageWire = String(noUsageWire.dropLast()) + #", "usage":{"input_tokens":0}}"#
        let partialUsage = try JSONDecoder().decode(SystemOneResponse.self, from: Data(partialUsageWire.utf8))
        #expect(partialUsage.usage?.inputTokens == 0)
        #expect(partialUsage.usage?.outputTokens == nil)
        try partialUsage.validate(for: request)
        let zeroUsageWire = String(noUsageWire.dropLast()) + #", "usage":{"input_tokens":0,"output_tokens":0}}"#
        let zeroUsage = try JSONDecoder().decode(SystemOneResponse.self, from: Data(zeroUsageWire.utf8))
        #expect(zeroUsage.usage == Usage(inputTokens: 0, outputTokens: 0))
        try zeroUsage.validate(for: request)

        var invalid = mixedResponse()
        invalid.usage = .init(inputTokens: -1, outputTokens: 0)
        expectValidationError(at: "usage.input_tokens") { try invalid.validate(for: request) }
        invalid.usage = .init(inputTokens: 0, outputTokens: -1)
        expectValidationError(at: "usage.output_tokens") { try invalid.validate(for: request) }

        let response = mixedResponse()
        #expect(try response.choice("route").choice == "accept")
        #expect(try response.score("grade").score == 1)
        #expect(try response.noul("flag").noul == 0.2)
        expectValidationError(at: "answers.missing") { _ = try response.choice("missing") }
        expectValidationError(at: "answers.route") { _ = try response.score("route") }
        expectValidationError(at: "answers.grade") { _ = try response.noul("grade") }
        let selected = try response.choice("route").value(as: Route.self)
        #expect(selected == .accept)
        expectValidationError(at: "answer.choice") {
            _ = try ChoiceAnswer(choice: "unknown", probabilities: [:], confidence: 0).value(as: Route.self)
        }
        #expect(try response.score("grade").normalizedScore == 0.5)
        #expect(ScoreAnswer(score: 0, legend: [:], probabilities: [:], confidence: 0).normalizedScore == nil)
    }
}
