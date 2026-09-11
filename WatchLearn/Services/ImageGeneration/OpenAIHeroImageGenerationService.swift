import Foundation
import ImageIO

struct GeneratedHeroImage: Equatable, Sendable {
    let imageData: Data
    let prompt: String
}

protocol HeroImageGenerating: Sendable {
    func generate(
        design: HeroDesign,
        description: String,
        apiKey: String
    ) async throws -> GeneratedHeroImage
}

enum HeroOpenAIServiceError: LocalizedError, Equatable, Sendable {
    case missingCredential
    case invalidHTTPResponse
    case httpStatus(Int, requestID: String?)
    case malformedResponse
    case contentRejected
    case invalidImage
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            "Add an OpenAI API key in Settings first."
        case .invalidHTTPResponse:
            "The online hero service returned an invalid response."
        case let .httpStatus(status, requestID):
            if let requestID {
                "The online hero service returned HTTP \(status) (request \(requestID))."
            } else {
                "The online hero service returned HTTP \(status)."
            }
        case .malformedResponse:
            "The online hero service returned an unreadable response."
        case .contentRejected:
            "That idea or picture was stopped by the child-safety filter. Try a friendlier idea."
        case .invalidImage:
            "The online hero service did not return a usable picture."
        case .responseTooLarge:
            "The online hero service returned more data than the app can safely process."
        }
    }
}

/// Performs the complete guarded image flow: local policy, remote text
/// moderation, image generation, and remote moderation of the generated image.
/// The reusable credential is accepted per call and is never persisted or logged.
struct OpenAIHeroImageGenerationService: HeroImageGenerating, Sendable {
    static let maximumModerationResponseBytes = 512 * 1_024
    static let maximumImageResponseBytes = 12 * 1_024 * 1_024

    private let session: URLSession
    private let moderationEndpoint: URL
    private let imageEndpoint: URL

    init(
        session: URLSession = .shared,
        moderationEndpoint: URL = URL(string: "https://api.openai.com/v1/moderations")!,
        imageEndpoint: URL = URL(string: "https://api.openai.com/v1/images/generations")!
    ) {
        self.session = session
        self.moderationEndpoint = moderationEndpoint
        self.imageEndpoint = imageEndpoint
    }

    func generate(
        design: HeroDesign,
        description: String,
        apiKey: String
    ) async throws -> GeneratedHeroImage {
        let credential = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else { throw HeroOpenAIServiceError.missingCredential }

        let approvedDescription = try HeroPromptPolicy.sanitize(description)
        let prompt = HeroGenerationPromptBuilder.prompt(
            design: design,
            approvedDescription: approvedDescription
        )

        try await moderateText(
            approvedDescription.isEmpty ? design.childSummary(in: .english) : approvedDescription,
            apiKey: credential
        )
        let imageData = try await requestImage(prompt: prompt, apiKey: credential)
        guard GeneratedHeroImageValidator.isValid(imageData) else {
            throw HeroOpenAIServiceError.invalidImage
        }
        try await moderateImage(imageData, apiKey: credential)
        return GeneratedHeroImage(imageData: imageData, prompt: prompt)
    }

    private func moderateText(_ text: String, apiKey: String) async throws {
        let body: [String: Any] = [
            "model": "omni-moderation-latest",
            "input": text
        ]
        let data = try await performJSONRequest(
            endpoint: moderationEndpoint,
            body: body,
            apiKey: apiKey,
            timeout: 30,
            maximumResponseBytes: Self.maximumModerationResponseBytes
        )
        try Self.requireUnflaggedModeration(data)
    }

    private func moderateImage(_ imageData: Data, apiKey: String) async throws {
        let dataURL = "data:image/png;base64,\(imageData.base64EncodedString())"
        let body: [String: Any] = [
            "model": "omni-moderation-latest",
            "input": [[
                "type": "image_url",
                "image_url": ["url": dataURL]
            ]]
        ]
        let data = try await performJSONRequest(
            endpoint: moderationEndpoint,
            body: body,
            apiKey: apiKey,
            timeout: 45,
            maximumResponseBytes: Self.maximumModerationResponseBytes
        )
        try Self.requireUnflaggedModeration(data)
    }

    private func requestImage(prompt: String, apiKey: String) async throws -> Data {
        let body: [String: Any] = [
            "model": "gpt-image-2",
            "prompt": prompt,
            "n": 1,
            "size": "1024x1024",
            "quality": "low",
            "output_format": "png",
            "background": "opaque",
            "moderation": "auto"
        ]
        let data = try await performJSONRequest(
            endpoint: imageEndpoint,
            body: body,
            apiKey: apiKey,
            timeout: 120,
            maximumResponseBytes: Self.maximumImageResponseBytes
        )
        return try Self.parseGeneratedImage(data)
    }

    private func performJSONRequest(
        endpoint: URL,
        body: [String: Any],
        apiKey: String,
        timeout: TimeInterval,
        maximumResponseBytes: Int
    ) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Stream the body so a compromised or malformed upstream cannot make
        // URLSession buffer an unbounded JSON/image response in memory.
        let (bytes, response) = try await session.bytes(for: request)
        let responseTask = bytes.task
        guard let response = response as? HTTPURLResponse else {
            responseTask.cancel()
            throw HeroOpenAIServiceError.invalidHTTPResponse
        }
        guard (200...299).contains(response.statusCode) else {
            responseTask.cancel()
            throw HeroOpenAIServiceError.httpStatus(
                response.statusCode,
                requestID: response.value(forHTTPHeaderField: "x-request-id")
            )
        }

        if response.expectedContentLength > Int64(maximumResponseBytes) {
            responseTask.cancel()
            throw HeroOpenAIServiceError.responseTooLarge
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), maximumResponseBytes))
        }
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                responseTask.cancel()
                throw HeroOpenAIServiceError.responseTooLarge
            }
            data.append(byte)
        }
        return data
    }

    static func requireUnflaggedModeration(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let results = root["results"] as? [[String: Any]],
              let first = results.first,
              let flagged = first["flagged"] as? Bool else {
            throw HeroOpenAIServiceError.malformedResponse
        }
        if flagged { throw HeroOpenAIServiceError.contentRejected }
    }

    static func parseGeneratedImage(_ data: Data) throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let images = root["data"] as? [[String: Any]],
              let encoded = images.first?["b64_json"] as? String,
              encoded.utf8.count <= GeneratedHeroImageValidator.maximumBase64Bytes,
              let imageData = Data(base64Encoded: encoded),
              !imageData.isEmpty,
              imageData.count <= GeneratedHeroImageValidator.maximumEncodedImageBytes else {
            throw HeroOpenAIServiceError.malformedResponse
        }
        return imageData
    }

    static func isDecodableImage(_ data: Data) -> Bool {
        GeneratedHeroImageValidator.isValid(data)
    }
}

/// Validates encoded images before UIKit ever allocates their decoded pixels.
/// The generated format is deliberately narrow: one PNG frame, at most
/// 2048x2048 and four million pixels, with an eight MiB encoded body.
enum GeneratedHeroImageValidator {
    static let maximumEncodedImageBytes = 8 * 1_024 * 1_024
    static let maximumBase64Bytes = ((maximumEncodedImageBytes + 2) / 3) * 4
    static let maximumPixelDimension = 2_048
    static let maximumPixelCount = 4_194_304

    static func isValid(_ data: Data) -> Bool {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.starts(with: pngSignature),
              data.count <= maximumEncodedImageBytes,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any],
              let width = integerProperty(properties[kCGImagePropertyPixelWidth]),
              let height = integerProperty(properties[kCGImagePropertyPixelHeight]),
              width > 0,
              height > 0,
              width <= maximumPixelDimension,
              height <= maximumPixelDimension,
              width <= maximumPixelCount / height else {
            return false
        }

        let options = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options) != nil
    }

    private static func integerProperty(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? Int { return value }
        return nil
    }
}
