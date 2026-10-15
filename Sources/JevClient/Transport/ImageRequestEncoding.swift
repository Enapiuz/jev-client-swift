import Foundation

extension SystemOneRequest {
    func encodedBody(using encoding: ImageUploadEncoding) throws -> (body: Data, contentType: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if assets.isEmpty || encoding == .base64JSON {
            let body = try encoder.encode(self)
            try Self.validateBodySize(body.count)
            return (body, "application/json")
        }

        // This envelope encodes part references directly, never base64 copies of image bytes.
        struct PartReference: Encodable {
            let type = "image"
            let format: ImageFormat
            let part: String
        }
        struct Envelope: Encodable {
            let state: JSONValue
            let model: JevModel
            let questions: [String: Question]
            let assets: [String: PartReference]
        }
        let references = assets.mapValues { asset in
            PartReference(format: asset.format, part: "image_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        }
        let json = try encoder.encode(Envelope(state: state, model: model, questions: questions, assets: references))
        var boundary: String
        repeat {
            boundary = "JevClient_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        } while json.range(of: Data(boundary.utf8)) != nil || assets.values.contains(where: { $0.data.range(of: Data(boundary.utf8)) != nil })

        var body = Data()
        func append(_ text: String) { body.append(contentsOf: text.utf8) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"request\"\r\nContent-Type: application/json\r\n\r\n")
        body.append(json)
        append("\r\n")
        for reference in assets.keys.sorted() {
            let asset = assets[reference]!
            let name = references[reference]!.part
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(name).\(asset.format.rawValue)\"\r\nContent-Type: \(asset.format.mimeType)\r\n\r\n")
            body.append(asset.data)
            append("\r\n")
            try Self.validateBodySize(body.count)
        }
        append("--\(boundary)--\r\n")
        try Self.validateBodySize(body.count)
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    private static func validateBodySize(_ count: Int) throws {
        guard count <= 32 * 1_024 * 1_024 else {
            throw JevValidationError(path: "request", message: "Encoded request exceeds 33554432 bytes")
        }
    }
}
