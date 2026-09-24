import Foundation

/// A JSON value that preserves signed and unsigned 64-bit integers separately from floating-point numbers.
public indirect enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int64.self) { self = .integer(value); return }
        if let value = try? container.decode(UInt64.self) { self = .unsignedInteger(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .unsignedInteger(let value): try container.encode(value)
        case .number(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    .init(codingPath: encoder.codingPath, debugDescription: "JSON numbers must be finite")
                )
            }
            try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Converts an Encodable value through its actual JSON representation and encoder configuration.
    public static func encoding<T: Encodable>(
        _ value: T,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> JSONValue {
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes this value as a concrete type using the supplied decoder configuration.
    public func decode<T: Decodable>(
        _ type: T.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try decoder.decode(type, from: data)
    }

    // Shared request/response content validation. Nested JSON may contain every JSON kind.
    func validateContent(at path: String, allowsNull: Bool) throws {
        switch self {
        case .null:
            guard allowsNull else {
                throw JevValidationError(path: path, message: "Expected a string, object, or array")
            }
        case .string, .object, .array:
            try validateFinite(at: path)
        default:
            throw JevValidationError(path: path, message: "Expected a string, object, or array\(allowsNull ? ", or null" : "")")
        }
    }

    func validateFinite(at path: String) throws {
        switch self {
        case .number(let value) where !value.isFinite:
            throw JevValidationError(path: path, message: "JSON number must be finite")
        case .array(let values):
            for (index, value) in values.enumerated() {
                try value.validateFinite(at: "\(path)[\(index)]")
            }
        case .object(let values):
            for key in values.keys.sorted() {
                try values[key]!.validateFinite(at: "\(path).\(key)")
            }
        default:
            break
        }
    }

    // The service may echo an integral JSON number with a different storage case.
    // Keep this separate from public Equatable and require exact numeric conversion.
    func isJSONEquivalent(to other: JSONValue) -> Bool {
        switch (self, other) {
        case (.array(let left), .array(let right)):
            guard left.count == right.count else { return false }
            for (leftValue, rightValue) in zip(left, right) {
                guard leftValue.isJSONEquivalent(to: rightValue) else { return false }
            }
            return true
        case (.object(let left), .object(let right)):
            guard left.count == right.count else { return false }
            for (key, leftValue) in left {
                guard let rightValue = right[key], leftValue.isJSONEquivalent(to: rightValue) else {
                    return false
                }
            }
            return true
        case (.integer(let signed), .unsignedInteger(let unsigned)):
            return signed >= 0 && UInt64(signed) == unsigned
        case (.unsignedInteger(let unsigned), .integer(let signed)):
            return signed >= 0 && unsigned == UInt64(signed)
        case (.number(let number), .integer(let integer)):
            return Int64(exactly: number) == integer
        case (.integer(let integer), .number(let number)):
            return Int64(exactly: number) == integer
        case (.number(let number), .unsignedInteger(let integer)):
            return UInt64(exactly: number) == integer
        case (.unsignedInteger(let integer), .number(let number)):
            return UInt64(exactly: number) == integer
        default:
            return self == other
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .integer(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    /// Repeated keys use the last value, matching ordinary dictionary assignment.
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var values: [String: JSONValue] = [:]
        for (key, value) in elements { values[key] = value }
        self = .object(values)
    }
}
