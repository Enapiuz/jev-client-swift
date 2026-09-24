/// A categorical answer mapped to an application's string-backed enum.
public struct TypedChoiceAnswer<Choice: Hashable & Sendable>: Sendable {
    /// The selected enum case.
    public let choice: Choice
    /// The complete distribution keyed by enum case.
    public let probabilities: [Choice: Double]
    /// The service's separate confidence value, which is not the maximum probability.
    public let confidence: Double

    public init(choice: Choice, probabilities: [Choice: Double], confidence: Double) {
        self.choice = choice
        self.probabilities = probabilities
        self.confidence = confidence
    }
}
