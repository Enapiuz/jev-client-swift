import Foundation

/// An asynchronous client for TypeSafe AI's System One and model discovery endpoints.
/// The client neither reads environment variables nor stores credentials.
public struct JevClient: Sendable {
    private let configuration: JevConfiguration
    private let executor: HTTPExecutor
    private let responseValidation: ResponseValidation

    /// Creates a client with a fixed API key. `baseURL` is the API root, without `/v1`.
    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.typesafe.ai")!,
        model: JevModel = .latest,
        transport: any HTTPTransport = URLSessionTransport(),
        responseValidation: ResponseValidation = .standard
    ) throws {
        try self.init(
            configuration: JevConfiguration(
                authentication: .apiKey(apiKey), baseURL: baseURL, model: model
            ),
            transport: transport,
            responseValidation: responseValidation
        )
    }

    /// Creates a client with explicit authentication, timeout, retry, and HTTP settings.
    public init(
        configuration: JevConfiguration,
        transport: any HTTPTransport = URLSessionTransport(),
        responseValidation: ResponseValidation = .standard
    ) throws {
        try configuration.validate()
        try Self.validate(responseValidation)
        self.configuration = configuration
        self.executor = HTTPExecutor(configuration: configuration, transport: transport)
        self.responseValidation = responseValidation
    }

    /// Sends a complete named-question request to `POST /v1/systemone`.
    /// Invalid requests fail before an HTTP attempt. The result retains the resolved model,
    /// optional usage counts, response metadata, and raw response body.
    @concurrent public func systemOne(
        _ request: SystemOneRequest,
        options: RequestOptions = .init(),
        validation: ResponseValidation? = nil
    ) async throws -> JevResponse<SystemOneResponse> {
        try request.validate()
        let policy = validation ?? responseValidation
        try Self.validate(policy)
        try Task.checkCancellation()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(request)
        let (response, metadata) = try await executor.execute(
            method: "POST", path: "/v1/systemone", body: body, options: options
        )
        let decoded: SystemOneResponse
        do {
            decoded = try JSONDecoder().decode(SystemOneResponse.self, from: response.body)
        } catch {
            throw JevError.decoding(
                message: "Could not decode the System One response.",
                metadata: metadata, body: response.body
            )
        }
        do {
            try decoded.validate(for: request, policy: policy)
        } catch let error as JevValidationError {
            throw JevError.invalidResponse(
                reason: "\(error.path): \(error.message)", metadata: metadata
            )
        }
        try Task.checkCancellation()
        return JevResponse(
            value: decoded, metadata: metadata, body: response.body,
            model: decoded.model, usage: decoded.usage
        )
    }

    /// Evaluates named questions using the configured model unless one is supplied.
    @concurrent public func evaluate(
        state: JSONValue,
        questions: [String: Question],
        model: JevModel? = nil,
        options: RequestOptions = .init(),
        validation: ResponseValidation? = nil
    ) async throws -> JevResponse<SystemOneResponse> {
        try await systemOne(
            SystemOneRequest(
                state: state, model: model ?? configuration.model, questions: questions
            ),
            options: options, validation: validation
        )
    }

    /// Lists model aliases and metadata from `GET /v1/models`.
    @concurrent public func models(
        options: RequestOptions = .init()
    ) async throws -> JevResponse<[ModelCard]> {
        try Task.checkCancellation()
        let (response, metadata) = try await executor.execute(
            method: "GET", path: "/v1/models", body: nil, options: options
        )
        let decoded: ListModelsResponse
        do {
            decoded = try JSONDecoder().decode(ListModelsResponse.self, from: response.body)
        } catch {
            throw JevError.decoding(
                message: "Could not decode the models response.",
                metadata: metadata, body: response.body
            )
        }
        for (index, model) in decoded.models.enumerated() {
            guard !model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw JevError.invalidResponse(
                    reason: "models[\(index)].name: Model name must not be blank",
                    metadata: metadata
                )
            }
        }
        try Task.checkCancellation()
        return JevResponse(value: decoded.models, metadata: metadata, body: response.body)
    }

    /// Evaluates one categorical question named `result`.
    @concurrent public func choice(
        state: JSONValue,
        instructions: JSONValue? = nil,
        criteria: [String: JSONValue],
        model: JevModel? = nil,
        options: RequestOptions = .init()
    ) async throws -> JevResponse<ChoiceAnswer> {
        let response = try await evaluate(
            state: state,
            questions: ["result": .choice(instructions: instructions, criteria: criteria)],
            model: model, options: options
        )
        guard case .choice(let answer)? = response.value.answers["result"] else {
            throw JevError.invalidResponse(
                reason: "answers.result: Expected a Choice answer", metadata: response.metadata
            )
        }
        return response.map { _ in answer }
    }

    /// Evaluates one ordered-rubric question named `result`.
    @concurrent public func score(
        state: JSONValue,
        instructions: JSONValue? = nil,
        criteria: [JSONValue],
        model: JevModel? = nil,
        options: RequestOptions = .init()
    ) async throws -> JevResponse<ScoreAnswer> {
        let response = try await evaluate(
            state: state,
            questions: ["result": .score(instructions: instructions, criteria: criteria)],
            model: model, options: options
        )
        guard case .score(let answer)? = response.value.answers["result"] else {
            throw JevError.invalidResponse(
                reason: "answers.result: Expected a Score answer", metadata: response.metadata
            )
        }
        return response.map { _ in answer }
    }

    /// Evaluates one proposition named `result`. The result is a probability, not a Boolean.
    @concurrent public func noul(
        state: JSONValue,
        instructions: JSONValue? = nil,
        criteria: NoulCriteria? = nil,
        model: JevModel? = nil,
        options: RequestOptions = .init()
    ) async throws -> JevResponse<NoulAnswer> {
        let response = try await evaluate(
            state: state,
            questions: ["result": .noul(instructions: instructions, criteria: criteria)],
            model: model, options: options
        )
        guard case .noul(let answer)? = response.value.answers["result"] else {
            throw JevError.invalidResponse(
                reason: "answers.result: Expected a Noul answer", metadata: response.metadata
            )
        }
        return response.map { _ in answer }
    }

    /// Evaluates one Choice using every case of a string-backed enum as a label.
    /// Missing descriptions become JSON null; explicit descriptions improve decisions.
    @concurrent public func choice<C: RawRepresentable & CaseIterable & Hashable & Sendable>(
        state: JSONValue,
        instructions: JSONValue? = nil,
        choices: C.Type,
        descriptions: [C: JSONValue] = [:],
        model: JevModel? = nil,
        options: RequestOptions = .init()
    ) async throws -> JevResponse<TypedChoiceAnswer<C>> where C.RawValue == String {
        let cases = Array(C.allCases)
        let caseSet = Set(cases)
        guard descriptions.keys.allSatisfy(caseSet.contains) else {
            throw JevValidationError(
                path: "descriptions", message: "Description key is absent from allCases"
            )
        }
        var labelToChoice: [String: C] = [:]
        var criteria: [String: JSONValue] = [:]
        for candidate in cases {
            let label = candidate.rawValue
            guard labelToChoice.updateValue(candidate, forKey: label) == nil else {
                throw JevValidationError(path: "choices", message: "Duplicate raw label in allCases")
            }
            criteria[label] = descriptions[candidate] ?? .null
        }
        let response = try await choice(
            state: state, instructions: instructions, criteria: criteria,
            model: model, options: options
        )
        guard let winner = labelToChoice[response.value.choice] else {
            throw JevError.invalidResponse(
                reason: "answers.result.choice: Unknown enum label", metadata: response.metadata
            )
        }
        var probabilities: [C: Double] = [:]
        for (label, probability) in response.value.probabilities {
            guard let candidate = labelToChoice[label] else {
                throw JevError.invalidResponse(
                    reason: "answers.result.probabilities: Unknown enum label",
                    metadata: response.metadata
                )
            }
            probabilities[candidate] = probability
        }
        guard probabilities.count == caseSet.count else {
            throw JevError.invalidResponse(
                reason: "answers.result.probabilities: Missing enum label",
                metadata: response.metadata
            )
        }
        let answer = TypedChoiceAnswer(
            choice: winner, probabilities: probabilities, confidence: response.value.confidence
        )
        return response.map { _ in answer }
    }

    private static func validate(_ policy: ResponseValidation) throws {
        if case .strict(let tolerance) = policy {
            guard tolerance.isFinite, (0...0.1).contains(tolerance) else {
                throw JevValidationError(
                    path: "policy.tolerance", message: "Tolerance must be finite and in 0...0.1"
                )
            }
        }
    }
}
