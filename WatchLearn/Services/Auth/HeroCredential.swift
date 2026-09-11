import Foundation

enum HeroCredential: Sendable {
    case parentKey(String)
    case managedAccount

    var isAvailable: Bool {
        switch self {
        case .parentKey(let key): !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .managedAccount: true
        }
    }
}

extension HeroImageGenerating {
    func generate(design: HeroDesign, description: String, credential: HeroCredential) async throws -> GeneratedHeroImage {
        switch credential {
        case .parentKey(let key):
            return try await generate(design: design, description: description, apiKey: key)
        case .managedAccount:
            let approved = try HeroPromptPolicy.sanitize(description)
            let designObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(design))
            let body = try JSONSerialization.data(withJSONObject: ["design": designObject, "description": approved])
            let data = try await ParentAccount.shared.request(path: "v1/heroes/image", method: "POST", body: body,
                maximumResponseBytes: OpenAIHeroImageGenerationService.maximumImageResponseBytes, timeout: 240)
            let image = try OpenAIHeroImageGenerationService.parseGeneratedImage(data)
            guard GeneratedHeroImageValidator.isValid(image) else { throw HeroOpenAIServiceError.invalidImage }
            return GeneratedHeroImage(imageData: image, prompt: HeroGenerationPromptBuilder.prompt(design: design, approvedDescription: approved))
        }
    }
}

extension HeroDescriptionTranscribing {
    func transcribe(fileURL: URL, language: LearningLanguage, credential: HeroCredential) async throws -> String {
        switch credential {
        case .parentKey(let key):
            return try await transcribe(fileURL: fileURL, language: language, apiKey: key)
        case .managedAccount:
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue > 0,
                  size.intValue <= OpenAITranscriptionService.maximumAudioBytes else { throw HeroOpenAIServiceError.responseTooLarge }
            let audio = try Data(contentsOf: fileURL)
            let body = try JSONSerialization.data(withJSONObject: ["audio": audio.base64EncodedString(), "language": language.rawValue])
            let data = try await ParentAccount.shared.request(path: "v1/heroes/transcribe", method: "POST", body: body)
            return try HeroTranscriptionRequestBuilder.parseTranscript(data)
        }
    }
}
