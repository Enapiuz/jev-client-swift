import Foundation

/// The image formats accepted by the service. Bytes are sent without decoding or conversion.
public enum ImageFormat: String, Codable, Sendable, Equatable {
    case png, jpg, jpeg

    var mimeType: String { self == .png ? "image/png" : "image/jpeg" }
}

/// An in-memory image. Codable uses the service's base64 JSON representation.
public struct ImageAsset: Codable, Sendable, Equatable {
    public var data: Data
    public var format: ImageFormat

    public init(data: Data, format: ImageFormat) {
        self.data = data
        self.format = format
    }

    private enum CodingKeys: String, CodingKey { case type, format, dataBase64 = "data_base64" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.type), try container.decode(String.self, forKey: .type) != "image" {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Expected an image asset")
        }
        format = try container.decode(ImageFormat.self, forKey: .format)
        let encoded = try container.decode(String.self, forKey: .dataBase64)
        guard let bytes = Data(base64Encoded: encoded) else {
            throw DecodingError.dataCorruptedError(forKey: .dataBase64, in: container, debugDescription: "Invalid base64 image data")
        }
        data = bytes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("image", forKey: .type)
        try container.encode(format, forKey: .format)
        try container.encode(data.base64EncodedString(), forKey: .dataBase64)
    }
}

/// Multipart avoids base64 expansion; base64 JSON is useful for JSON-only proxies.
public enum ImageUploadEncoding: Sendable, Equatable {
    case multipart
    case base64JSON
}

extension JSONValue {
    func containsAssetReference(_ reference: String) -> Bool {
        switch self {
        case .string(let value): value.contains(reference)
        case .array(let values): values.contains { $0.containsAssetReference(reference) }
        case .object(let values): values.values.contains { $0.containsAssetReference(reference) }
        default: false
        }
    }
}

extension Question {
    func containsAssetReference(_ reference: String) -> Bool {
        switch self {
        case .choice(let instructions, let criteria):
            (instructions?.containsAssetReference(reference) ?? false) || criteria.values.contains { $0.containsAssetReference(reference) }
        case .score(let instructions, let criteria):
            (instructions?.containsAssetReference(reference) ?? false) || criteria.contains { $0.containsAssetReference(reference) }
        case .noul(let instructions, let criteria):
            (instructions?.containsAssetReference(reference) ?? false) ||
            (criteria?.trueDescription?.containsAssetReference(reference) ?? false) ||
            (criteria?.falseDescription?.containsAssetReference(reference) ?? false)
        case .box(let instructions): instructions.containsAssetReference(reference)
        }
    }
}
