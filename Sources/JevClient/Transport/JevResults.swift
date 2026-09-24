import Foundation

public struct ResponseMetadata: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let requestID: String?
    /// Number of HTTP attempts made, starting at one.
    public let attempts: Int

    public init(statusCode: Int, headers: [String: String], requestID: String?, attempts: Int) {
        self.statusCode = statusCode
        self.headers = headers
        self.requestID = requestID
        self.attempts = attempts
    }
}

public struct JevResponse<Value: Sendable>: Sendable {
    public let value: Value
    public let metadata: ResponseMetadata
    public let body: Data
    public let model: String?
    public let usage: Usage?

    public init(
        value: Value,
        metadata: ResponseMetadata,
        body: Data,
        model: String? = nil,
        usage: Usage? = nil
    ) {
        self.value = value
        self.metadata = metadata
        self.body = body
        self.model = model
        self.usage = usage
    }

    public func map<T: Sendable>(_ transform: (Value) throws -> T) rethrows -> JevResponse<T> {
        JevResponse<T>(
            value: try transform(value),
            metadata: metadata,
            body: body,
            model: model,
            usage: usage
        )
    }
}

public struct JevHTTPError: Error, Sendable, LocalizedError {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
    public let requestID: String?
    public let attempts: Int

    public init(
        statusCode: Int,
        headers: [String: String],
        body: Data,
        requestID: String?,
        attempts: Int
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.requestID = requestID
        self.attempts = attempts
    }

    public var bodyText: String? { String(data: body, encoding: .utf8) }
    public var bodyJSON: JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: body) }

    public var errorDescription: String? {
        if let requestID {
            return "HTTP \(statusCode) (request \(requestID))"
        }
        return "HTTP \(statusCode)"
    }
}

public enum JevError: Error, Sendable, LocalizedError {
    case configuration(String)
    case http(JevHTTPError)
    case transport(underlying: any Error)
    case timeout
    /// The message is for programmatic diagnostics and should be sanitized by its caller.
    case decoding(message: String, metadata: ResponseMetadata, body: Data)
    case invalidResponse(reason: String, metadata: ResponseMetadata)

    public var errorDescription: String? {
        switch self {
        case .configuration(let message):
            return "Invalid client configuration: \(message)"
        case .http(let error):
            return error.errorDescription
        case .transport:
            return "Transport request failed"
        case .timeout:
            return "Request deadline exceeded"
        case .decoding:
            return "Response decoding failed"
        case .invalidResponse:
            return "Invalid response"
        }
    }
}

/// Lifecycle information safe to forward to tracing or logging.
public enum JevEvent: Sendable {
    case requestStarted(attempt: Int, method: String, path: String)
    case responseReceived(attempt: Int, statusCode: Int, requestID: String?)
    case retryScheduled(attempt: Int, delay: TimeInterval)
    case requestFailed(attempt: Int, kind: String)
}
