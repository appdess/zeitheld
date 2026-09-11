import Foundation

protocol RealtimeClientSecretProviding: Sendable {
    func clientSecret(
        options: RealtimeSessionOptions,
        safetyIdentifier: RealtimeSafetyIdentifier
    ) async throws -> RealtimeClientSecret
}

enum RealtimeClientSecretProviderError: LocalizedError, Equatable, Sendable {
    case missingCredential
    case insecureBrokerURL
    case invalidHTTPResponse
    case httpStatus(Int, requestID: String?)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            "The Realtime credential is missing."
        case .insecureBrokerURL:
            "The production token broker must use HTTPS."
        case .invalidHTTPResponse:
            "The token service returned an invalid response."
        case let .httpStatus(status, requestID):
            if let requestID = RealtimeCredentialSanitizer.requestID(requestID) {
                "The token service returned HTTP \(status) (request \(requestID))."
            } else {
                "The token service returned HTTP \(status)."
            }
        case .malformedResponse:
            "The token service returned a malformed client secret."
        }
    }
}

/// Prototype-only BYOK provider. The reusable parent key is sent only to the
/// client-secret endpoint and is never exposed through an error or description.
struct OpenAIAPIKeyClientSecretProvider: RealtimeClientSecretProviding {
    private let apiKey: String
    private let session: URLSession
    private let endpoint: URL

    init(
        apiKey: String,
        session: URLSession = .shared,
        endpoint: URL = RealtimeConstants.clientSecretURL
    ) {
        self.apiKey = apiKey
        self.session = session
        self.endpoint = endpoint
    }

    func clientSecret(
        options: RealtimeSessionOptions,
        safetyIdentifier: RealtimeSafetyIdentifier
    ) async throws -> RealtimeClientSecret {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RealtimeClientSecretProviderError.missingCredential
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(
            safetyIdentifier.headerValue,
            forHTTPHeaderField: "OpenAI-Safety-Identifier"
        )
        request.httpBody = try RealtimeEventEncoder.clientSecretRequest(options: options)

        return try await requestClientSecret(request)
    }

    private func requestClientSecret(_ request: URLRequest) async throws -> RealtimeClientSecret {
        let (data, response) = try await RealtimeBoundedHTTPResponseReader.read(
            request: request,
            session: session
        )
        return try RealtimeClientSecretResponseParser.parse(data: data, response: response)
    }
}

/// Production provider for an app-owned broker that mints the OpenAI ephemeral
/// secret on a trusted server. The broker may return the upstream OpenAI shape
/// directly or wrap it in `client_secret`.
struct BrokerClientSecretProvider: RealtimeClientSecretProviding {
    private let brokerURL: URL
    private let authorizationToken: String?
    private let session: URLSession

    init(
        brokerURL: URL,
        authorizationToken: String? = nil,
        session: URLSession = .shared
    ) {
        self.brokerURL = brokerURL
        self.authorizationToken = authorizationToken
        self.session = session
    }

    func clientSecret(
        options: RealtimeSessionOptions,
        safetyIdentifier: RealtimeSafetyIdentifier
    ) async throws -> RealtimeClientSecret {
        guard brokerURL.scheme?.lowercased() == "https" else {
            throw RealtimeClientSecretProviderError.insecureBrokerURL
        }

        var request = URLRequest(url: brokerURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            safetyIdentifier.headerValue,
            forHTTPHeaderField: "OpenAI-Safety-Identifier"
        )
        if let authorizationToken,
           !authorizationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(
                "Bearer \(authorizationToken)",
                forHTTPHeaderField: "Authorization"
            )
        }
        request.httpBody = try RealtimeEventEncoder.clientSecretRequest(options: options)

        let (data, response) = try await RealtimeBoundedHTTPResponseReader.read(
            request: request,
            session: session
        )
        return try RealtimeClientSecretResponseParser.parse(data: data, response: response)
    }
}

enum RealtimeBoundedHTTPResponseReader {
    static func read(
        request: URLRequest,
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RealtimeClientSecretProviderError.invalidHTTPResponse
        }

        // Error bodies are deliberately not consumed or surfaced. The status
        // and a sanitized request ID are the only troubleshooting values the
        // app needs.
        guard (200...299).contains(httpResponse.statusCode) else {
            return (Data(), response)
        }
        guard response.expectedContentLength <= 0
                || response.expectedContentLength <= RealtimeConstants.maxTokenResponseBytes else {
            throw RealtimeClientSecretProviderError.malformedResponse
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < RealtimeConstants.maxTokenResponseBytes else {
                throw RealtimeClientSecretProviderError.malformedResponse
            }
            data.append(byte)
        }
        return (data, response)
    }
}

enum RealtimeCredentialSanitizer {
    static func requestID(_ value: String?) -> String? {
        guard let value,
              value.hasPrefix("req_"),
              !value.isEmpty,
              value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (
                      CharacterSet.alphanumerics.contains(scalar)
                          || scalar == "_"
                          || scalar == "-"
                          || scalar == "."
                  )
              }) else {
            return nil
        }
        return value
    }
}

enum RealtimeClientSecretValidator {
    static func validate(
        value: String,
        expiresAt: Date,
        now: Date = Date()
    ) throws -> RealtimeClientSecret {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedValue == value,
              value.hasPrefix("ek_"),
              (4...512).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (
                      CharacterSet.alphanumerics.contains(scalar)
                          || scalar == "_"
                          || scalar == "-"
                  )
              }) else {
            throw RealtimeClientSecretProviderError.malformedResponse
        }

        let lifetime = expiresAt.timeIntervalSince(now)
        guard lifetime.isFinite,
              lifetime > RealtimeConstants.minimumUsableClientSecretLifetime,
              lifetime <= RealtimeConstants.maximumClientSecretLifetime else {
            throw RealtimeClientSecretProviderError.malformedResponse
        }

        return RealtimeClientSecret(value: value, expiresAt: expiresAt)
    }
}

enum RealtimeClientSecretResponseParser {
    static func parse(
        data: Data,
        response: URLResponse,
        now: Date = Date()
    ) throws -> RealtimeClientSecret {
        guard let response = response as? HTTPURLResponse else {
            throw RealtimeClientSecretProviderError.invalidHTTPResponse
        }
        guard data.count <= RealtimeConstants.maxTokenResponseBytes,
              response.expectedContentLength <= 0
                || response.expectedContentLength <= RealtimeConstants.maxTokenResponseBytes else {
            throw RealtimeClientSecretProviderError.malformedResponse
        }
        guard (200...299).contains(response.statusCode) else {
            throw RealtimeClientSecretProviderError.httpStatus(
                response.statusCode,
                requestID: RealtimeCredentialSanitizer.requestID(
                    response.value(forHTTPHeaderField: "x-request-id")
                )
            )
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw RealtimeClientSecretProviderError.malformedResponse
        }

        let secretObject: [String: Any]
        if let nested = root["client_secret"] as? [String: Any] {
            secretObject = nested
        } else {
            secretObject = root
        }

        guard let value = secretObject["value"] as? String
            ?? root["client_secret"] as? String
        else {
            throw RealtimeClientSecretProviderError.malformedResponse
        }

        guard let timestamp = (secretObject["expires_at"] as? NSNumber)?.doubleValue
            ?? (root["expires_at"] as? NSNumber)?.doubleValue else {
            throw RealtimeClientSecretProviderError.malformedResponse
        }
        return try RealtimeClientSecretValidator.validate(
            value: value,
            expiresAt: Date(timeIntervalSince1970: timestamp),
            now: now
        )
    }
}
