import Foundation

/// A service model identifier. Aliases can move; use the response's resolved model for audit logs.
public struct JevModel: RawRepresentable, ExpressibleByStringLiteral, Codable, Sendable, Equatable, Hashable {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let jev1_13_0: JevModel = "jev-1.13.0"
    public static let jev1_14_0: JevModel = "jev-1.14.0"

    public static let latest: JevModel = "jev-latest"
    public static let preview: JevModel = "jev-preview"

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// An application-side validation error with a path to the invalid value.
public struct JevValidationError: Error, Sendable, Equatable, LocalizedError {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    public var errorDescription: String? { "\(path): \(message)" }
}

/// Optional descriptions of the true and false outcomes of a Noul question.
public struct NoulCriteria: Codable, Sendable, Equatable {
    public var trueDescription: JSONValue?
    public var falseDescription: JSONValue?

    public init(trueDescription: JSONValue? = nil, falseDescription: JSONValue? = nil) {
        self.trueDescription = trueDescription
        self.falseDescription = falseDescription
    }

    private enum CodingKeys: String, CodingKey {
        case trueDescription = "true"
        case falseDescription = "false"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.trueDescription) {
            trueDescription = try container.decode(JSONValue.self, forKey: .trueDescription)
        } else {
            trueDescription = .none
        }
        if container.contains(.falseDescription) {
            falseDescription = try container.decode(JSONValue.self, forKey: .falseDescription)
        } else {
            falseDescription = .none
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(trueDescription, forKey: .trueDescription)
        try container.encodeIfPresent(falseDescription, forKey: .falseDescription)
    }
}

/// A flat wire question; the associated values become `instructions` and `criteria` fields.
public enum Question: Codable, Sendable, Equatable {
    case choice(instructions: JSONValue? = nil, criteria: [String: JSONValue])
    case score(instructions: JSONValue? = nil, criteria: [JSONValue])
    case box(instructions: JSONValue)
    case noul(instructions: JSONValue? = nil, criteria: NoulCriteria? = nil)

    public var type: String {
        switch self {
        case .choice: "choice"
        case .score: "score"
        case .noul: "noul"
        case .box: "box"
        }
    }

    private enum CodingKeys: String, CodingKey { case type, instructions, criteria }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let instructions: JSONValue?
        if container.contains(.instructions) {
            instructions = try container.decode(JSONValue.self, forKey: .instructions)
        } else {
            instructions = .none
        }
        switch type {
        case "choice":
            self = .choice(
                instructions: instructions,
                criteria: try container.decode([String: JSONValue].self, forKey: .criteria)
            )
        case "score":
            self = .score(
                instructions: instructions,
                criteria: try container.decode([JSONValue].self, forKey: .criteria)
            )
        case "box":
            self = .box(instructions: try container.decode(JSONValue.self, forKey: .instructions))
        case "noul":
            self = .noul(
                instructions: instructions,
                criteria: try container.decodeIfPresent(NoulCriteria.self, forKey: .criteria)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown question type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .choice(let instructions, let criteria):
            try container.encodeIfPresent(instructions, forKey: .instructions)
            try container.encode(criteria, forKey: .criteria)
        case .score(let instructions, let criteria):
            try container.encodeIfPresent(instructions, forKey: .instructions)
            try container.encode(criteria, forKey: .criteria)
        case .box(let instructions):
            try container.encode(instructions, forKey: .instructions)
        case .noul(let instructions, let criteria):
            try container.encodeIfPresent(instructions, forKey: .instructions)
            try container.encodeIfPresent(criteria, forKey: .criteria)
        }
    }

    /// Checks the SDK-compatible request profile, including nested finite JSON numbers.
    public func validate(path: String = "question") throws {
        let instructions: JSONValue?
        switch self {
        case .choice(let value, _), .score(let value, _), .noul(let value, _):
            instructions = value
        case .box(let value):
            instructions = value
        }
        try instructions?.validateContent(at: "\(path).instructions", allowsNull: true)

        switch self {
        case .choice(_, let criteria):
            guard (1...255).contains(criteria.count) else {
                throw JevValidationError(path: "\(path).criteria", message: "Choice requires 1...255 labels")
            }
            for label in criteria.keys.sorted() {
                guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw JevValidationError(path: "\(path).criteria", message: "Choice labels must not be blank")
                }
                try criteria[label]!.validateContent(at: "\(path).criteria.\(label)", allowsNull: true)
            }
        case .score(_, let criteria):
            guard (2...10).contains(criteria.count) else {
                throw JevValidationError(path: "\(path).criteria", message: "Score requires 2...10 rubric entries")
            }
            for (index, value) in criteria.enumerated() {
                try value.validateContent(at: "\(path).criteria[\(index)]", allowsNull: false)
            }
        case .box(let instructions):
            try instructions.validateContent(at: "\(path).instructions", allowsNull: false)
        case .noul(_, let criteria):
            try criteria?.trueDescription?.validateContent(at: "\(path).criteria.true", allowsNull: true)
            try criteria?.falseDescription?.validateContent(at: "\(path).criteria.false", allowsNull: true)
        }
    }
}

/// The complete System One request envelope.
public struct SystemOneRequest: Codable, Sendable, Equatable {
    public var state: JSONValue
    public var model: JevModel
    public var questions: [String: Question]
    public var assets: [String: ImageAsset]

    public init(state: JSONValue, model: JevModel = .latest, questions: [String: Question], assets: [String: ImageAsset] = [:]) {
        self.state = state
        self.model = model
        self.questions = questions
        self.assets = assets
    }

    private enum CodingKeys: String, CodingKey { case state, model, questions, assets }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(JSONValue.self, forKey: .state)
        model = try container.decode(JevModel.self, forKey: .model)
        questions = try container.decode([String: Question].self, forKey: .questions)
        assets = try container.decodeIfPresent([String: ImageAsset].self, forKey: .assets) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encode(model, forKey: .model)
        try container.encode(questions, forKey: .questions)
        if !assets.isEmpty { try container.encode(assets, forKey: .assets) }
    }

    /// Rejects invalid portable state, empty model/IDs, malformed criteria, and nonfinite numbers.
    public func validate() throws {
        try state.validateContent(at: "state", allowsNull: false)
        guard !model.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JevValidationError(path: "model", message: "Model identifier must not be blank")
        }
        guard !questions.isEmpty else {
            throw JevValidationError(path: "questions", message: "At least one question is required")
        }
        var referenceBytes = 0
        for (reference, asset) in assets {
            let count = reference.utf8.count
            guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  count <= 1_024 else {
                throw JevValidationError(path: "assets", message: "Image references must be nonblank and at most 1024 UTF-8 bytes")
            }
            referenceBytes += count
            guard referenceBytes <= 65_536 else {
                throw JevValidationError(path: "assets", message: "Image references exceed 65536 UTF-8 bytes in total")
            }
            guard !asset.data.isEmpty, asset.data.count <= 16 * 1_024 * 1_024 else {
                throw JevValidationError(path: "assets", message: "Each image must contain 1...16777216 bytes")
            }
            guard state.containsAssetReference(reference) || questions.values.contains(where: { $0.containsAssetReference(reference) }) else {
                throw JevValidationError(path: "assets", message: "An image asset is not referenced by a string value")
            }
        }
        if questions.values.contains(where: { if case .box = $0 { true } else { false } }) {
            guard !assets.isEmpty else {
                throw JevValidationError(path: "assets", message: "Box requires image assets")
            }
            guard model != .jev1_13_0 else {
                throw JevValidationError(path: "model", message: "Box is unavailable with jev-1.13.0")
            }
        }
        for id in questions.keys.sorted() {
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw JevValidationError(path: "questions", message: "Question IDs must not be blank")
            }
            try questions[id]!.validate(path: "questions.\(id)")
        }
    }
}
