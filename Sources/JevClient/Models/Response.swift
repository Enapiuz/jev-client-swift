import Foundation

/// A categorical answer and its complete distribution over the requested labels.
public struct ChoiceAnswer: Codable, Sendable, Equatable {
    public var choice: String
    public var probabilities: [String: Double]
    public var confidence: Double

    public init(choice: String, probabilities: [String: Double], confidence: Double) {
        self.choice = choice
        self.probabilities = probabilities
        self.confidence = confidence
    }

    /// Converts the selected label to a string-backed enum, rejecting unknown labels.
    public func value<T: RawRepresentable>(as type: T.Type) throws -> T where T.RawValue == String {
        guard let value = T(rawValue: choice) else {
            throw JevValidationError(path: "answer.choice", message: "Unknown value: \(choice)")
        }
        return value
    }
}

/// An expected position on a zero-based, ordered rubric.
public struct ScoreAnswer: Codable, Sendable, Equatable {
    public var score: Double
    public var legend: [String: JSONValue]
    public var probabilities: [String: Double]
    public var confidence: Double

    public init(
        score: Double,
        legend: [String: JSONValue],
        probabilities: [String: Double],
        confidence: Double
    ) {
        self.score = score
        self.legend = legend
        self.probabilities = probabilities
        self.confidence = confidence
    }

    /// Score divided by the highest rubric index; nil when fewer than two legend entries exist.
    public var normalizedScore: Double? {
        guard legend.count > 1 else { return nil }
        return score / Double(legend.count - 1)
    }
}

/// Probability that the proposition in a Noul question is true.
public struct NoulAnswer: Codable, Sendable, Equatable {
    public var noul: Double

    public init(noul: Double) { self.noul = noul }
}

/// A flat wire answer with a required `type` discriminator.
public enum Answer: Codable, Sendable, Equatable {
    case choice(ChoiceAnswer)
    case score(ScoreAnswer)
    case noul(NoulAnswer)

    public var type: String {
        switch self {
        case .choice: "choice"
        case .score: "score"
        case .noul: "noul"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, choice, score, noul, legend, probabilities, confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "choice":
            self = .choice(ChoiceAnswer(
                choice: try container.decode(String.self, forKey: .choice),
                probabilities: try container.decode([String: Double].self, forKey: .probabilities),
                confidence: try container.decode(Double.self, forKey: .confidence)
            ))
        case "score":
            self = .score(ScoreAnswer(
                score: try container.decode(Double.self, forKey: .score),
                legend: try container.decode([String: JSONValue].self, forKey: .legend),
                probabilities: try container.decode([String: Double].self, forKey: .probabilities),
                confidence: try container.decode(Double.self, forKey: .confidence)
            ))
        case "noul":
            self = .noul(NoulAnswer(noul: try container.decode(Double.self, forKey: .noul)))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown answer type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .choice(let answer):
            try container.encode(answer.choice, forKey: .choice)
            try container.encode(answer.probabilities, forKey: .probabilities)
            try container.encode(answer.confidence, forKey: .confidence)
        case .score(let answer):
            try container.encode(answer.score, forKey: .score)
            try container.encode(answer.legend, forKey: .legend)
            try container.encode(answer.probabilities, forKey: .probabilities)
            try container.encode(answer.confidence, forKey: .confidence)
        case .noul(let answer):
            try container.encode(answer.noul, forKey: .noul)
        }
    }
}

/// Optional token counts. Absence means unknown, not zero.
public struct Usage: Codable, Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

/// Validation levels for answers that have already decoded structurally.
public enum ResponseValidation: Sendable, Equatable {
    /// Enforces present decisions, types, keys, ranges, and finite values while allowing rounded distributions and changed echoed legend text.
    case standard
    /// Also checks distribution mass, winner/weighted score consistency, and exact echoed rubrics.
    /// The tolerance must be finite and in `0...0.1`.
    case strict(tolerance: Double)
}

/// A resolved model and answers indexed by the request's question IDs.
public struct SystemOneResponse: Codable, Sendable, Equatable {
    public var model: String
    public var answers: [String: Answer]
    public var usage: Usage?

    public init(model: String, answers: [String: Answer], usage: Usage? = nil) {
        self.model = model
        self.answers = answers
        self.usage = usage
    }

    public func choice(_ id: String) throws -> ChoiceAnswer {
        guard let answer = answers[id] else {
            throw JevValidationError(path: "answers.\(id)", message: "Missing answer")
        }
        guard case .choice(let value) = answer else {
            throw JevValidationError(path: "answers.\(id)", message: "Expected a Choice answer")
        }
        return value
    }

    public func score(_ id: String) throws -> ScoreAnswer {
        guard let answer = answers[id] else {
            throw JevValidationError(path: "answers.\(id)", message: "Missing answer")
        }
        guard case .score(let value) = answer else {
            throw JevValidationError(path: "answers.\(id)", message: "Expected a Score answer")
        }
        return value
    }

    public func noul(_ id: String) throws -> NoulAnswer {
        guard let answer = answers[id] else {
            throw JevValidationError(path: "answers.\(id)", message: "Missing answer")
        }
        guard case .noul(let value) = answer else {
            throw JevValidationError(path: "answers.\(id)", message: "Expected a Noul answer")
        }
        return value
    }

    /// Validates the response against its original request. Unknown additive JSON fields are ignored during decoding.
    public func validate(
        for request: SystemOneRequest,
        policy: ResponseValidation = .standard
    ) throws {
        try request.validate()
        if case .strict(let tolerance) = policy {
            guard tolerance.isFinite, (0...0.1).contains(tolerance) else {
                throw JevValidationError(path: "policy.tolerance", message: "Tolerance must be finite and in 0...0.1")
            }
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JevValidationError(path: "model", message: "Resolved model must not be blank")
        }
        if let value = usage?.inputTokens, value < 0 {
            throw JevValidationError(path: "usage.input_tokens", message: "Token count must not be negative")
        }
        if let value = usage?.outputTokens, value < 0 {
            throw JevValidationError(path: "usage.output_tokens", message: "Token count must not be negative")
        }

        let requestedIDs = Set(request.questions.keys)
        let answerIDs = Set(answers.keys)
        if let missing = requestedIDs.subtracting(answerIDs).sorted().first {
            throw JevValidationError(path: "answers.\(missing)", message: "Missing requested answer")
        }
        if let extra = answerIDs.subtracting(requestedIDs).sorted().first {
            throw JevValidationError(path: "answers.\(extra)", message: "Unexpected answer ID")
        }

        for id in request.questions.keys.sorted() {
            let path = "answers.\(id)"
            switch (request.questions[id]!, answers[id]!) {
            case (.choice(_, let criteria), .choice(let answer)):
                try Self.validateChoice(answer, labels: Set(criteria.keys), path: path, policy: policy)
            case (.score(_, let criteria), .score(let answer)):
                try Self.validateScore(answer, rubric: criteria, path: path, policy: policy)
            case (.noul, .noul(let answer)):
                try Self.validateProbability(answer.noul, path: "\(path).noul")
            default:
                throw JevValidationError(path: "\(path).type", message: "Answer type does not match question")
            }
        }
    }

    private static func validateProbability(_ value: Double, path: String) throws {
        guard value.isFinite, (0...1).contains(value) else {
            throw JevValidationError(path: path, message: "Expected a finite probability in 0...1")
        }
    }

    private static func validateDistribution(
        _ probabilities: [String: Double],
        expectedKeys: Set<String>,
        path: String,
        policy: ResponseValidation
    ) throws {
        guard Set(probabilities.keys) == expectedKeys else {
            throw JevValidationError(path: path, message: "Probability keys do not match the requested criteria")
        }
        for key in probabilities.keys.sorted() {
            try validateProbability(probabilities[key]!, path: "\(path).\(key)")
        }
        if case .strict(let tolerance) = policy {
            let mass = probabilities.values.reduce(0, +)
            guard abs(mass - 1) <= tolerance else {
                throw JevValidationError(path: path, message: "Probability mass differs from one beyond tolerance")
            }
        }
    }

    private static func validateChoice(
        _ answer: ChoiceAnswer,
        labels: Set<String>,
        path: String,
        policy: ResponseValidation
    ) throws {
        guard labels.contains(answer.choice) else {
            throw JevValidationError(path: "\(path).choice", message: "Winner is not a requested label")
        }
        try validateProbability(answer.confidence, path: "\(path).confidence")
        try validateDistribution(
            answer.probabilities, expectedKeys: labels,
            path: "\(path).probabilities", policy: policy
        )
        if case .strict(let tolerance) = policy {
            let winner = answer.probabilities[answer.choice]!
            let maximum = answer.probabilities.values.max()!
            guard maximum - winner <= tolerance else {
                throw JevValidationError(path: "\(path).choice", message: "Winner is below the maximum probability")
            }
        }
    }

    private static func validateScore(
        _ answer: ScoreAnswer,
        rubric: [JSONValue],
        path: String,
        policy: ResponseValidation
    ) throws {
        let indices = Set(rubric.indices.map { String($0) })
        guard Set(answer.legend.keys) == indices else {
            throw JevValidationError(path: "\(path).legend", message: "Legend indices do not match the requested rubric")
        }
        for key in answer.legend.keys.sorted() {
            try answer.legend[key]!.validateContent(at: "\(path).legend.\(key)", allowsNull: false)
        }
        try validateDistribution(
            answer.probabilities, expectedKeys: indices,
            path: "\(path).probabilities", policy: policy
        )
        try validateProbability(answer.confidence, path: "\(path).confidence")
        guard answer.score.isFinite, (0...Double(rubric.count - 1)).contains(answer.score) else {
            throw JevValidationError(path: "\(path).score", message: "Score is outside the requested rubric range")
        }
        if case .strict(let tolerance) = policy {
            let expectedScore = rubric.indices.reduce(0.0) {
                $0 + Double($1) * answer.probabilities[String($1)]!
            }
            guard abs(answer.score - expectedScore) <= tolerance else {
                throw JevValidationError(path: "\(path).score", message: "Score differs from the weighted mean")
            }
            for index in rubric.indices {
                guard let echoed = answer.legend[String(index)],
                      echoed.isJSONEquivalent(to: rubric[index]) else {
                    throw JevValidationError(path: "\(path).legend.\(index)", message: "Legend differs from the requested rubric")
                }
            }
        }
    }
}
