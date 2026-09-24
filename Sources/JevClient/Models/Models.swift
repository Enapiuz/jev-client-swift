import Foundation

/// Metadata returned by the models endpoint. Release dates remain the service's string value.
public struct ModelCard: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var releaseDate: String

    public init(name: String, description: String, releaseDate: String) {
        self.name = name
        self.description = description
        self.releaseDate = releaseDate
    }

    private enum CodingKeys: String, CodingKey {
        case name, description
        case releaseDate = "release_date"
    }
}

/// The models endpoint envelope.
public struct ListModelsResponse: Codable, Sendable, Equatable {
    public var models: [ModelCard]

    public init(models: [ModelCard]) { self.models = models }
}
