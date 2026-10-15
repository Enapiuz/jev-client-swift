import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import JevClient

private let imageRef = "9c5da231-2183-4c7a-a78c-39eef9246b55"
private let imageBytes = Data([0, 13, 10, 255, 34, 128, 0])
private let image = ImageAsset(data: imageBytes, format: .png)
private let noulJSON = #"{"model":"jev-1.14.0","answers":{"result":{"type":"noul","noul":0.8}},"usage":{"input_tokens":2}}"#
private let boxJSON = #"{"model":"jev-1.14.0","answers":{"result":{"type":"box","box":{"top":0.1,"bottom":0.8,"left":0.2,"right":0.9},"confidence":0.7}},"usage":{"input_tokens":2}}"#

private actor ImageTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var responses: [HTTPResponse]
    init(_ bodies: [String] = [noulJSON], statuses: [Int] = []) {
        responses = bodies.enumerated().map { index, body in
            HTTPResponse(statusCode: statuses.isEmpty ? 200 : statuses[index], headers: ["x-typesafe-request-id": "images-test"], body: Data(body.utf8))
        }
    }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
    func recorded() -> [URLRequest] { requests }
}

private func imageRequest(state: JSONValue? = nil, questions: [String: Question] = ["result": .noul()], model: JevModel = .latest, assets: [String: ImageAsset]? = nil) -> SystemOneRequest {
    SystemOneRequest(state: state ?? .string("Inspect \(imageRef) carefully"), model: model, questions: questions, assets: assets ?? [imageRef: image])
}

private func imageClient(_ transport: any HTTPTransport, headers: [String: String] = [:], features: JevExperimentalFeatures = .init(images: true), encoding: ImageUploadEncoding = .multipart) throws -> JevClient {
    try JevClient(configuration: JevConfiguration(authentication: .apiKey("test-key"), headers: headers, experimentalFeatures: features, imageUploadEncoding: encoding, retryPolicy: .disabled), transport: transport)
}

private struct ParsedPart {
    let headers: String
    let body: Data
}

private func multipart(_ request: URLRequest) throws -> [ParsedPart] {
    let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
    let boundary = try #require(contentType.components(separatedBy: "boundary=").last)
    let body = try #require(request.httpBody)
    let separator = Data("\r\n--\(boundary)".utf8)
    let headerEnd = Data("\r\n\r\n".utf8)
    #expect(body.starts(with: Data("--\(boundary)\r\n".utf8)))
    #expect(body.suffix(Data("--\(boundary)--\r\n".utf8).count) == Data("--\(boundary)--\r\n".utf8))
    var offset = Data("--\(boundary)\r\n".utf8).count
    var parts: [ParsedPart] = []
    while offset < body.count {
        let headers = try #require(body.range(of: headerEnd, in: offset..<body.count))
        let end = try #require(body.range(of: separator, in: headers.upperBound..<body.count))
        parts.append(ParsedPart(headers: String(decoding: body[offset..<headers.lowerBound], as: UTF8.self), body: body.subdata(in: headers.upperBound..<end.lowerBound)))
        offset = end.upperBound
        if body[offset..<min(offset + 2, body.count)] == Data("--".utf8) { break }
        offset += 2
    }
    return parts
}

@Suite struct ImageExperimentalTests {
    @Test func modelConstantsAndAssetRoundtrip() throws {
        #expect(JevModel.jev1_13_0.rawValue == "jev-1.13.0")
        #expect(JevModel.jev1_14_0.rawValue == "jev-1.14.0")
        #expect(JevModel.latest.rawValue == "jev-latest")
        #expect(JevModel.preview.rawValue == "jev-preview")
        let request = imageRequest()
        let encoded = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(SystemOneRequest.self, from: encoded) == request)
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(image)) as? [String: String]
        #expect(wire == ["type": "image", "format": "png", "data_base64": imageBytes.base64EncodedString()])
        for format in ImageFormat.allTestFormats {
            let asset = ImageAsset(data: imageBytes, format: format)
            #expect(try JSONDecoder().decode(ImageAsset.self, from: JSONEncoder().encode(asset)) == asset)
        }
        #expect(try JSONDecoder().decode(ImageAsset.self, from: Data(#"{"format":"jpg","data_base64":"AQI="}"#.utf8)) == ImageAsset(data: Data([1, 2]), format: .jpg))
        for invalid in [
            #"{"type":"audio","format":"png","data_base64":"AQI="}"#,
            #"{"type":null,"format":"png","data_base64":"AQI="}"#,
            #"{"format":"png","data_base64":"a!@#"}"#,
            #"{"format":"gif","data_base64":"AQI="}"#,
            #"{"format":"png"}"#
        ] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(ImageAsset.self, from: Data(invalid.utf8)) }
        }
        let legacy = SystemOneRequest(state: "text", questions: ["result": .noul()])
        let legacyData = try JSONEncoder().encode(legacy)
        #expect(!(String(decoding: legacyData, as: UTF8.self).contains("assets")))
        #expect(try JSONDecoder().decode(SystemOneRequest.self, from: legacyData).assets.isEmpty)
    }

    @Test func referencesUseOnlyStringValues() throws {
        let states: [JSONValue] = [
            .string("Compare \(imageRef) with another image"),
            ["outer": ["nested": [.string("Inside \(imageRef)")]]]
        ]
        for state in states { try imageRequest(state: state).validate() }
        let questions: [Question] = [
            .choice(instructions: .string("Inspect \(imageRef)"), criteria: ["a": .null]),
            .choice(criteria: ["a": ["nested": [.string("Inspect \(imageRef)")]]]),
            .score(criteria: [.string(imageRef), "other"]),
            .noul(criteria: NoulCriteria(falseDescription: .string("Check \(imageRef)"))),
            .box(instructions: ["image": .string(imageRef)])
        ]
        for question in questions { try imageRequest(state: "text", questions: ["result": question]).validate() }
        let invalid: [SystemOneRequest] = [
            imageRequest(state: .object([imageRef: "value"])),
            imageRequest(state: "text", questions: [imageRef: .noul()]),
            imageRequest(state: "text", questions: ["result": .choice(criteria: [imageRef: "value"])])
        ]
        for request in invalid { #expect(throws: JevValidationError.self) { try request.validate() } }
        try SystemOneRequest(state: "Unknown references are server validated", questions: ["result": .noul()]).validate()
    }

    @Test func referenceAndFileLimits() throws {
        for reference in ["", " \n", String(repeating: "é", count: 513)] {
            #expect(throws: JevValidationError.self) {
                try imageRequest(state: .string(reference), assets: [reference: image]).validate()
            }
        }
        let reference = String(repeating: "é", count: 512)
        try imageRequest(state: .string(reference), assets: [reference: image]).validate()
        var assets: [String: ImageAsset] = [:]
        for index in 0..<64 {
            let key = String(format: "%04d", index) + String(repeating: "x", count: 1020)
            assets[key] = image
        }
        let state = JSONValue.array(assets.keys.map(JSONValue.string))
        try imageRequest(state: state, assets: assets).validate()
        assets["extra"] = image
        #expect(throws: JevValidationError.self) { try imageRequest(state: .array([state, "extra"]), assets: assets).validate() }
        for size in [0, 16 * 1024 * 1024 + 1] {
            #expect(throws: JevValidationError.self) { try imageRequest(assets: [imageRef: ImageAsset(data: Data(repeating: 1, count: size), format: .png)]).validate() }
        }
        try imageRequest(assets: [imageRef: ImageAsset(data: Data(repeating: 1, count: 16 * 1024 * 1024), format: .jpeg)]).validate()
    }

    @Test func multipartAndRetryReplay() async throws {
        let transport = ImageTransport(["busy", noulJSON], statuses: [503, 200])
        let client = try JevClient(configuration: JevConfiguration(authentication: .apiKey("test-key"), headers: ["Content-Type": "wrong"], experimentalFeatures: .init(images: true), retryPolicy: RetryPolicy(maxRetries: 1, initialDelay: 0, maxDelay: 0)), transport: transport)
        let unsafeRef = "path/\"\r\nInjected: value"
        let assets = [imageRef: image, unsafeRef: ImageAsset(data: Data([255, 0, 12]), format: .jpg)]
        let result = try await client.noul(state: .array([.string(imageRef), .string(unsafeRef)]), assets: assets, options: .init(headers: ["content-type": "also-wrong"]))
        #expect(result.metadata.attempts == 2)
        let requests = await transport.recorded()
        #expect(requests.count == 2)
        #expect(requests[0].httpBody == requests[1].httpBody)
        #expect(requests[0].value(forHTTPHeaderField: "Content-Type") == requests[1].value(forHTTPHeaderField: "Content-Type"))
        let parts = try multipart(requests[0])
        #expect(parts.count == 3)
        #expect(parts[0].headers == "Content-Disposition: form-data; name=\"request\"\r\nContent-Type: application/json")
        let root = try #require(JSONSerialization.jsonObject(with: parts[0].body) as? [String: Any])
        let encodedAssets = try #require(root["assets"] as? [String: [String: String]])
        #expect(!String(decoding: parts[0].body, as: UTF8.self).contains("data_base64"))
        for (reference, asset) in assets {
            let entry = try #require(encodedAssets[reference])
            let name = try #require(entry["part"])
            #expect(name.hasPrefix("image_"))
            #expect(name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 })
            #expect(entry["type"] == "image" && entry["format"] == asset.format.rawValue)
            let part = try #require(parts.dropFirst().first { $0.headers.contains("name=\"\(name)\"") })
            #expect(part.body == asset.data)
            #expect(part.headers.contains("Content-Type: \(asset.format == .png ? "image/png" : "image/jpeg")"))
            #expect(!part.headers.contains(unsafeRef) && !part.headers.contains(imageRef))
        }
    }

    @Test func base64AndLegacyEncoding() async throws {
        let transport = ImageTransport([noulJSON, noulJSON, noulJSON])
        let client = try imageClient(transport, encoding: .base64JSON)
        _ = try await client.noul(state: .string(imageRef), assets: [imageRef: image])
        _ = try await client.noul(state: "legacy")
        _ = try await client.noul(state: .string(imageRef), assets: [imageRef: image], options: .init(imageUploadEncoding: .multipart))
        let requests = await transport.recorded()
        #expect(requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try JSONDecoder().decode(SystemOneRequest.self, from: #require(requests[0].httpBody)).assets == [imageRef: image])
        #expect(requests[1].value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(!String(decoding: try #require(requests[1].httpBody), as: UTF8.self).contains("assets"))
        #expect(try multipart(requests[2]).count == 2)
    }

    @Test func encodedBodySizeBoundaries() throws {
        let limit = 32 * 1024 * 1024
        for encoding in [ImageUploadEncoding.multipart, .base64JSON] {
            let original = imageRequest(state: .string(imageRef))
            let overhead = try original.encodedBody(using: encoding).body.count
            var atLimit = original
            atLimit.state = .string(imageRef + String(repeating: "x", count: limit - overhead))
            #expect(try atLimit.encodedBody(using: encoding).body.count == limit)
            atLimit.state = .string(imageRef + String(repeating: "x", count: limit - overhead + 1))
            #expect(throws: JevValidationError.self) { try atLimit.encodedBody(using: encoding) }
        }
    }

    @Test func oversizedBodyFailsBeforeTransport() async throws {
        let transport = ImageTransport()
        let client = try imageClient(transport)
        let large = ImageAsset(data: Data(repeating: 1, count: 16 * 1024 * 1024), format: .jpeg)
        let request = imageRequest(state: "first second", assets: ["first": large, "second": large])
        for encoding in [ImageUploadEncoding.multipart, .base64JSON] {
            do {
                _ = try await client.systemOne(request, options: .init(imageUploadEncoding: encoding))
                Issue.record("Expected oversized request rejection")
            } catch let error as JevValidationError { #expect(error.path == "request") }
        }
        #expect((await transport.recorded()).isEmpty)
    }

    @Test func multipartPreservesExactIntegersAndPerCallJSONOverride() async throws {
        let transport = ImageTransport([noulJSON, noulJSON])
        let client = try imageClient(transport)
        let state: JSONValue = ["image": .string(imageRef), "signed": .integer(.max), "unsigned": .unsignedInteger(.max)]
        _ = try await client.noul(state: state, assets: [imageRef: image])
        _ = try await client.noul(state: state, assets: [imageRef: image], options: .init(imageUploadEncoding: .base64JSON))
        let requests = await transport.recorded()
        let multipartJSON = try multipart(requests[0])[0].body
        let base64JSON = try #require(requests[1].httpBody)
        for body in [multipartJSON, base64JSON] {
            let wire = try JSONDecoder().decode(JSONValue.self, from: body)
            guard case .object(let envelope) = wire else { Issue.record("Expected request envelope"); return }
            #expect(envelope["state"] == state)
        }
        #expect(requests[1].value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func rawConfigurationFlagsRemainUsable() async throws {
        let transport = ImageTransport()
        let client = try imageClient(transport, headers: ["TYPESAFE-DANGER-ZONE-IMAGES": "true", "TypeSafe-Danger-Zone-Long-Context": "true"], features: .init())
        _ = try await client.systemOne(imageRequest())
        let request = try #require(await transport.recorded().first)
        #expect(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") == "true")
        #expect(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Long-Context") == "true")
    }

    @Test func optInDefaultsAndPrecedence() async throws {
        let transport = ImageTransport(Array(repeating: noulJSON, count: 8))
        let defaults = try imageClient(transport, features: .init())
        _ = try await defaults.noul(state: "legacy")
        do {
            _ = try await defaults.systemOne(imageRequest())
            Issue.record("Expected explicit opt-in")
        } catch let error as JevValidationError { #expect(error.path == "experimentalFeatures.images") }
        #expect((await transport.recorded()).count == 1)
        let configured = try imageClient(transport, headers: ["TYPESAFE-DANGER-ZONE-IMAGES": "false", "typesafe-danger-zone-long-context": "false"], features: .init(images: true, longContext: true))
        _ = try await configured.systemOne(imageRequest())
        do {
            _ = try await configured.systemOne(imageRequest(), options: .init(headers: ["typesafe-danger-zone-images": "false"]))
            Issue.record("Expected per-call raw false")
        } catch is JevValidationError {}
        _ = try await configured.systemOne(imageRequest(), options: .init(headers: ["TypeSafe-Danger-Zone-Images": "false"], experimentalFeatures: .init(images: true, longContext: false)))
        do {
            _ = try await configured.systemOne(imageRequest(), options: .init(headers: ["TypeSafe-Danger-Zone-Images": "true"], experimentalFeatures: .init(images: false)))
            Issue.record("Expected typed false override")
        } catch is JevValidationError {}
        _ = try await defaults.systemOne(imageRequest(), options: .init(headers: ["tYpEsAfE-dAnGeR-zOnE-iMaGeS": "TRUE"]))
        _ = try await configured.noul(state: "legacy", options: .init(experimentalFeatures: .init(images: false)))
        let requests = await transport.recorded()
        #expect(requests.count == 5)
        #expect(requests[0].value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") == nil)
        #expect(requests[0].value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Long-Context") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") == "true")
        #expect(requests[1].value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Long-Context") == "true")
        #expect(requests[2].value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Long-Context") == "false")
        #expect(requests[4].value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") == "false")
    }

    @Test func modelDiscoveryDoesNotApplyTypedFlags() async throws {
        let transport = ImageTransport([#"{"models":[]}"#])
        _ = try await imageClient(transport, features: .init(images: true, longContext: true)).models(options: .init(experimentalFeatures: .init(images: true, longContext: true)))
        let request = try #require(await transport.recorded().first)
        #expect(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") == nil)
        #expect(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Long-Context") == nil)
    }

    @Test func localFailuresNeverReachTransport() async throws {
        let transport = ImageTransport()
        let client = try imageClient(transport)
        for request in [
            imageRequest(assets: [imageRef: ImageAsset(data: Data(), format: .png)]),
            imageRequest(state: "unused"),
            imageRequest(questions: ["result": .box(instructions: "locate")], assets: [:]),
            imageRequest(questions: ["result": .box(instructions: "locate")], model: .jev1_13_0)
        ] {
            do { _ = try await client.systemOne(request); Issue.record("Expected local failure") }
            catch let error as JevValidationError {
                #expect(!error.message.contains(imageRef))
                #expect(!error.message.contains(imageBytes.base64EncodedString()))
            }
        }
        #expect((await transport.recorded()).isEmpty)
    }

    #if os(macOS) || os(Linux)
    @Test func multipartThroughURLSession() async throws {
        let server = try LoopbackServer(minimumRequests: 1) { _ in WireResponse(status: 200, body: Data(noulJSON.utf8)) }
        let client = try JevClient(configuration: JevConfiguration(authentication: .apiKey("test-key"), baseURL: server.url, experimentalFeatures: .init(images: true), retryPolicy: .disabled))
        _ = try await client.noul(state: .string(imageRef), assets: [imageRef: image])
        let wire = try #require(try await server.requests().first)
        #expect(wire.path == "/v1/systemone" && wire.method == "POST")
        #expect(wire.header("typesafe-danger-zone-images") == "true")
        var request = URLRequest(url: server.url)
        request.httpBody = wire.body
        request.setValue(wire.header("content-type"), forHTTPHeaderField: "Content-Type")
        let parts = try multipart(request)
        #expect(parts.count == 2 && parts[1].body == imageBytes)
    }
    #endif
}

private extension ImageFormat {
    static var allTestFormats: [ImageFormat] { [.png, .jpg, .jpeg] }
}

private enum ImageLabel: String, CaseIterable, Hashable, Sendable { case yes, no }

@Suite struct BoxTests {
    @Test func codableHelperAndMixedBatch() async throws {
        let question = Question.box(instructions: ["task": "Locate target"])
        let wire = try JSONEncoder().encode(question)
        #expect(try JSONDecoder().decode(Question.self, from: wire) == question)
        #expect(!String(decoding: wire, as: UTF8.self).contains("criteria"))
        let batch = #"{"model":"jev-1.14.0","answers":{"box":{"type":"box","box":{"top":0.1,"bottom":0.8,"left":0.2,"right":0.9},"confidence":0.7},"choice":{"type":"choice","choice":"yes","probabilities":{"yes":1},"confidence":1},"score":{"type":"score","score":1,"legend":{"0":"low","1":"high"},"probabilities":{"0":0,"1":1},"confidence":1},"noul":{"type":"noul","noul":0.2}},"usage":{"input_tokens":2}}"#
        let transport = ImageTransport([boxJSON, batch, batch])
        let client = try imageClient(transport)
        let result = try await client.box(state: .string(imageRef), instructions: "Locate target", model: .jev1_14_0, assets: [imageRef: image])
        #expect(result.value == BoxAnswer(box: BoxCoordinates(top: 0.1, bottom: 0.8, left: 0.2, right: 0.9), confidence: 0.7))
        #expect(result.model == "jev-1.14.0" && result.usage?.inputTokens == 2)
        #expect(result.body == Data(boxJSON.utf8) && result.metadata.requestID == "images-test")
        let questions: [String: Question] = [
            "box": question, "choice": .choice(criteria: ["yes": .null]),
            "score": .score(criteria: ["low", "high"]), "noul": .noul()
        ]
        for policy in [ResponseValidation.standard, .strict(tolerance: 0.01)] {
            let response = try await client.evaluate(state: .string(imageRef), questions: questions, assets: [imageRef: image], validation: policy)
            #expect(try response.value.box("box") == result.value)
            #expect(try response.value.choice("choice").choice == "yes")
            #expect(try response.value.score("score").score == 1)
            #expect(try response.value.noul("noul").noul == 0.2)
            #expect(try JSONDecoder().decode(SystemOneResponse.self, from: JSONEncoder().encode(response.value)) == response.value)
            #expect(throws: JevValidationError.self) { try response.value.box("missing") }
            #expect(throws: JevValidationError.self) { try response.value.box("choice") }
        }
        let sent = try multipart(try #require(await transport.recorded().first))
        let encodedRequest = try #require(JSONSerialization.jsonObject(with: sent[0].body) as? [String: Any])
        #expect(encodedRequest["model"] as? String == "jev-1.14.0")
    }

    @Test func coordinatesAndConfidenceAlwaysValidated() throws {
        let request = imageRequest(questions: ["result": .box(instructions: "locate")])
        let valid = BoxAnswer(box: BoxCoordinates(top: 0, bottom: 1, left: 0, right: 1), confidence: 0)
        let response = SystemOneResponse(model: "resolved", answers: ["result": .box(valid)])
        try response.validate(for: request)
        let invalidValues: [Double] = [-0.01, 1.01, .nan, .infinity, -.infinity]
        var invalidAnswers: [BoxAnswer] = []
        for value in invalidValues {
            var bad = valid; bad.confidence = value; invalidAnswers.append(bad)
            bad = valid; bad.box.top = value; invalidAnswers.append(bad)
            bad = valid; bad.box.bottom = value; invalidAnswers.append(bad)
            bad = valid; bad.box.left = value; invalidAnswers.append(bad)
            bad = valid; bad.box.right = value; invalidAnswers.append(bad)
        }
        for coordinates in [
            BoxCoordinates(top: 0.5, bottom: 0.5, left: 0, right: 1),
            BoxCoordinates(top: 0.8, bottom: 0.2, left: 0, right: 1),
            BoxCoordinates(top: 0, bottom: 1, left: 0.5, right: 0.5),
            BoxCoordinates(top: 0, bottom: 1, left: 0.8, right: 0.2)
        ] { invalidAnswers.append(BoxAnswer(box: coordinates, confidence: 0.5)) }
        for policy in [ResponseValidation.standard, .strict(tolerance: 0.01)] {
            for answer in invalidAnswers {
                #expect(throws: JevValidationError.self) {
                    try SystemOneResponse(model: "resolved", answers: ["result": .box(answer)]).validate(for: request, policy: policy)
                }
            }
            #expect(throws: JevValidationError.self) {
                try SystemOneResponse(model: "resolved", answers: ["result": .noul(NoulAnswer(noul: 0.5))]).validate(for: request, policy: policy)
            }
        }
    }

    @Test func structuralErrorsAndClientMismatch() async throws {
        for raw in [
            #"{"box":{"top":0,"bottom":1,"left":0,"right":1},"confidence":1}"#,
            #"{"type":"box","box":{"top":0,"bottom":1,"left":0},"confidence":1}"#,
            #"{"type":"box","box":{"top":0,"bottom":1,"left":0,"right":1}}"#
        ] { #expect(throws: (any Error).self) { try JSONDecoder().decode(Answer.self, from: Data(raw.utf8)) } }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Question.self, from: Data(#"{"type":"box"}"#.utf8)) }
        #expect(throws: JevValidationError.self) { try Question.box(instructions: .null).validate() }
        let transport = ImageTransport([noulJSON, boxJSON.replacingOccurrences(of: "0.9", with: "0.1")])
        let client = try imageClient(transport)
        for expectedPath in ["answers.result.type", "answers.result.box"] {
            do {
                _ = try await client.box(state: .string(imageRef), instructions: "Locate target", assets: [imageRef: image])
                Issue.record("Expected invalid Box response")
            } catch JevError.invalidResponse(let reason, let metadata) {
                #expect(reason.contains(expectedPath) && metadata.requestID == "images-test")
            }
        }
    }

    @Test func prerequisitesAndForwardCompatibleModels() throws {
        for model in [JevModel.latest, .preview, .jev1_14_0, JevModel(rawValue: "future-custom")] {
            try imageRequest(questions: ["result": .box(instructions: "locate")], model: model).validate()
        }
        #expect(throws: JevValidationError.self) { try imageRequest(questions: ["result": .box(instructions: "locate")], model: .jev1_13_0).validate() }
        #expect(throws: JevValidationError.self) { try imageRequest(questions: ["result": .box(instructions: "locate")], assets: [:]).validate() }
    }

    @Test func allPrimitiveHelpersForwardAssets() async throws {
        let choice = #"{"model":"resolved","answers":{"result":{"type":"choice","choice":"yes","probabilities":{"yes":0.8,"no":0.2},"confidence":0.7}}}"#
        let score = #"{"model":"resolved","answers":{"result":{"type":"score","score":1,"legend":{"0":"low","1":"high"},"probabilities":{"0":0,"1":1},"confidence":1}}}"#
        let transport = ImageTransport([choice, score, noulJSON, choice])
        let client = try imageClient(transport)
        let assets = [imageRef: image]
        _ = try await client.choice(state: "state", instructions: .string("Inspect \(imageRef)"), criteria: ["yes": .null, "no": .null], assets: assets)
        _ = try await client.score(state: "state", criteria: [.string(imageRef), "high"], assets: assets)
        _ = try await client.noul(state: "state", criteria: .init(trueDescription: .string(imageRef)), assets: assets)
        let typed = try await client.choice(state: "state", choices: ImageLabel.self, descriptions: [.yes: .string(imageRef)], assets: assets)
        #expect(typed.value.choice == .yes && typed.value.probabilities[.yes] == 0.8)
        let requests = await transport.recorded()
        #expect(requests.count == 4)
        for request in requests {
            let parts = try multipart(request)
            #expect(parts.count == 2 && parts[1].body == imageBytes)
        }
    }
}
