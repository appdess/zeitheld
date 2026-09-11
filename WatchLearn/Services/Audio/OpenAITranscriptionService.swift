import Foundation

protocol HeroDescriptionTranscribing: Sendable {
    func transcribe(
        fileURL: URL,
        language: LearningLanguage,
        apiKey: String
    ) async throws -> String
}

struct OpenAITranscriptionService: HeroDescriptionTranscribing, Sendable {
    static let maximumAudioBytes = 2 * 1_024 * 1_024
    static let maximumResponseBytes = 256 * 1_024

    private let session: URLSession
    private let endpoint: URL

    init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    ) {
        self.session = session
        self.endpoint = endpoint
    }

    func transcribe(
        fileURL: URL,
        language: LearningLanguage,
        apiKey: String
    ) async throws -> String {
        let credential = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else { throw HeroOpenAIServiceError.missingCredential }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let audioSize = attributes[.size] as? NSNumber,
              audioSize.intValue > 0,
              audioSize.intValue <= Self.maximumAudioBytes else {
            throw HeroOpenAIServiceError.responseTooLarge
        }
        let audioData = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let boundary = "WatchLearn-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = HeroTranscriptionRequestBuilder.multipartBody(
            audioData: audioData,
            fileName: fileURL.lastPathComponent,
            language: language,
            boundary: boundary
        )

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
        if response.expectedContentLength > Int64(Self.maximumResponseBytes) {
            responseTask.cancel()
            throw HeroOpenAIServiceError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(
            response.expectedContentLength > 0
                ? min(Int(response.expectedContentLength), Self.maximumResponseBytes)
                : 0
        )
        for try await byte in bytes {
            guard data.count < Self.maximumResponseBytes else {
                responseTask.cancel()
                throw HeroOpenAIServiceError.responseTooLarge
            }
            data.append(byte)
        }
        return try HeroTranscriptionRequestBuilder.parseTranscript(data)
    }
}

enum HeroTranscriptionRequestBuilder {
    static func multipartBody(
        audioData: Data,
        fileName: String,
        language: LearningLanguage,
        boundary: String
    ) -> Data {
        var result = Data()

        func append(_ value: String) {
            result.append(Data(value.utf8))
        }

        func appendField(name: String, value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        appendField(name: "model", value: "gpt-4o-transcribe")
        appendField(name: "language", value: language.rawValue)
        appendField(name: "response_format", value: "json")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFileName(fileName))\"\r\n")
        append("Content-Type: audio/mp4\r\n\r\n")
        result.append(audioData)
        append("\r\n--\(boundary)--\r\n")
        return result
    }

    static func parseTranscript(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let text = root["text"] as? String else {
            throw HeroOpenAIServiceError.malformedResponse
        }
        let sanitized = try HeroPromptPolicy.sanitize(text, allowEmpty: false)
        return sanitized
    }

    private static func safeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let safe = String(scalars)
        return safe.isEmpty ? "hero-description.m4a" : safe
    }
}
