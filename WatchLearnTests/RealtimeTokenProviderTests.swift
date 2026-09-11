import Foundation
import XCTest
@testable import WatchLearn

final class RealtimeTokenProviderTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testParentAPIKeyProviderCreatesGAShortLivedSecretRequest() async throws {
        let expiresAt = Date().addingTimeInterval(600)
        let session = makeMockSession { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.openai.com/v1/realtime/client_secrets"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer sk-fixture-never-real"
            )
            XCTAssertNil(request.value(forHTTPHeaderField: "OpenAI-Beta"))

            let safety = try XCTUnwrap(
                request.value(forHTTPHeaderField: "OpenAI-Safety-Identifier")
            )
            XCTAssertTrue(safety.hasPrefix("watchlearn_"))
            XCTAssertLessThanOrEqual(safety.count, 64)
            XCTAssertFalse(safety.contains("child-profile-42"))

            let body = try XCTUnwrap(requestBodyData(request))
            let root = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let session = try XCTUnwrap(root["session"] as? [String: Any])
            XCTAssertEqual(session["type"] as? String, "realtime")
            XCTAssertEqual(session["model"] as? String, "gpt-realtime-2.1")
            XCTAssertEqual(Set(session.keys), ["type", "model"])

            let expiresAfter = try XCTUnwrap(root["expires_after"] as? [String: Any])
            XCTAssertEqual(expiresAfter["anchor"] as? String, "created_at")
            XCTAssertEqual((expiresAfter["seconds"] as? NSNumber)?.intValue, 600)

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["x-request-id": "req_fixture"]
            )!
            let data = try JSONSerialization.data(withJSONObject: [
                "value": "ek_fixture",
                "expires_at": expiresAt.timeIntervalSince1970
            ])
            return (response, data)
        }

        let provider = OpenAIAPIKeyClientSecretProvider(
            apiKey: "sk-fixture-never-real",
            session: session
        )
        let secret = try await provider.clientSecret(
            options: RealtimeSessionOptions(language: .german),
            safetyIdentifier: RealtimeSafetyIdentifier(stableID: "child-profile-42")
        )

        XCTAssertEqual(secret.value, "ek_fixture")
        XCTAssertEqual(
            secret.expiresAt.timeIntervalSince1970,
            expiresAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testBrokerProviderUsesHTTPSAndAcceptsWrappedSecret() async throws {
        let expiresAt = Date().addingTimeInterval(600)
        let session = makeMockSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://broker.example/realtime-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer app-fixture")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "OpenAI-Safety-Identifier"))
            XCTAssertFalse(
                String(data: requestBodyData(request) ?? Data(), encoding: .utf8)?
                    .contains("sk-") == true
            )

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = try JSONSerialization.data(withJSONObject: [
                "client_secret": [
                    "value": "ek_broker",
                    "expires_at": expiresAt.timeIntervalSince1970
                ]
            ])
            return (response, data)
        }

        let provider = BrokerClientSecretProvider(
            brokerURL: URL(string: "https://broker.example/realtime-token")!,
            authorizationToken: "app-fixture",
            session: session
        )
        let secret = try await provider.clientSecret(
            options: RealtimeSessionOptions(language: .english),
            safetyIdentifier: RealtimeSafetyIdentifier(stableID: "anonymous-install")
        )

        XCTAssertEqual(secret.value, "ek_broker")
        XCTAssertEqual(
            secret.expiresAt.timeIntervalSince1970,
            expiresAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testBrokerRejectsInsecureURLBeforeNetworking() async {
        let provider = BrokerClientSecretProvider(
            brokerURL: URL(string: "http://broker.example/token")!
        )

        do {
            _ = try await provider.clientSecret(
                options: .init(),
                safetyIdentifier: RealtimeSafetyIdentifier(stableID: "fixture")
            )
            XCTFail("Expected insecure URL rejection")
        } catch {
            XCTAssertEqual(
                error as? RealtimeClientSecretProviderError,
                .insecureBrokerURL
            )
        }
    }

    func testHTTPErrorDoesNotExposeResponseBodyOrCredential() async {
        let session = makeMockSession { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["x-request-id": "req_denied"]
            )!
            return (response, Data(#"{"error":"sk-fixture-never-real"}"#.utf8))
        }
        let provider = OpenAIAPIKeyClientSecretProvider(
            apiKey: "sk-fixture-never-real",
            session: session
        )

        do {
            _ = try await provider.clientSecret(
                options: .init(),
                safetyIdentifier: RealtimeSafetyIdentifier(stableID: "fixture")
            )
            XCTFail("Expected HTTP failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("sk-fixture-never-real"))
            XCTAssertTrue(error.localizedDescription.contains("req_denied"))
        }
    }

    func testRejectsMissingExpiryNonEphemeralSecretAndUnreasonableLifetime() async throws {
        let fixtures: [[String: Any]] = [
            ["value": "ek_missing_expiry"],
            [
                "value": "sk_not_ephemeral",
                "expires_at": Date().addingTimeInterval(600).timeIntervalSince1970
            ],
            [
                "value": "ek_too_long",
                "expires_at": Date().addingTimeInterval(
                    RealtimeConstants.maximumClientSecretLifetime + 60
                ).timeIntervalSince1970
            ],
            [
                "value": "ek_already_expired",
                "expires_at": Date().addingTimeInterval(-60).timeIntervalSince1970
            ]
        ]

        for fixture in fixtures {
            let data = try JSONSerialization.data(withJSONObject: fixture)
            let session = makeMockSession { request in
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, data)
            }
            let provider = OpenAIAPIKeyClientSecretProvider(
                apiKey: "sk-fixture-never-real",
                session: session
            )

            do {
                _ = try await provider.clientSecret(
                    options: .init(),
                    safetyIdentifier: RealtimeSafetyIdentifier(stableID: "fixture")
                )
                XCTFail("Expected malformed ephemeral credential rejection")
            } catch {
                XCTAssertEqual(
                    error as? RealtimeClientSecretProviderError,
                    .malformedResponse
                )
            }
        }
    }

    func testRejectsOversizedTokenResponseBeforeParsing() async {
        let data = Data(
            repeating: 0x41,
            count: RealtimeConstants.maxTokenResponseBytes + 1
        )
        let session = makeMockSession { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(data.count)"]
            )!
            return (response, data)
        }
        let provider = OpenAIAPIKeyClientSecretProvider(
            apiKey: "sk-fixture-never-real",
            session: session
        )

        do {
            _ = try await provider.clientSecret(
                options: .init(),
                safetyIdentifier: RealtimeSafetyIdentifier(stableID: "fixture")
            )
            XCTFail("Expected oversized response rejection")
        } catch {
            XCTAssertEqual(
                error as? RealtimeClientSecretProviderError,
                .malformedResponse
            )
        }
    }

    func testUnsafeRequestIdentifierIsNotReflected() async {
        let session = makeMockSession { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["x-request-id": "sk-reflected-secret"]
            )!
            return (response, Data())
        }
        let provider = OpenAIAPIKeyClientSecretProvider(
            apiKey: "sk-fixture-never-real",
            session: session
        )

        do {
            _ = try await provider.clientSecret(
                options: .init(),
                safetyIdentifier: RealtimeSafetyIdentifier(stableID: "fixture")
            )
            XCTFail("Expected HTTP failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("sk-reflected-secret"))
        }
    }

    private func makeMockSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        MockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: (
        (URLRequest) throws -> (HTTPURLResponse, Data)
    )?

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }

    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        result.append(buffer, count: count)
    }
    return result
}
