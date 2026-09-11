import Foundation
import UIKit
import XCTest
@testable import WatchLearn

final class HeroOpenAIServiceTests: XCTestCase {
    override func tearDown() {
        HeroMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testCompleteGenerationFlowModeratesTextGeneratesAndModeratesImage() async throws {
        let png = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNG))
        var call = 0
        let session = makeSession { request in
            call += 1
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer sk-fixture-never-real"
            )
            let bodyData = try XCTUnwrap(heroRequestBodyData(request))
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            )

            switch call {
            case 1:
                XCTAssertEqual(request.url?.path, "/v1/moderations")
                XCTAssertEqual(body["model"] as? String, "omni-moderation-latest")
                XCTAssertEqual(body["input"] as? String, "Curly hair and a robot fox")
                return self.response(request, json: #"{"results":[{"flagged":false}]}"#)
            case 2:
                XCTAssertEqual(request.url?.path, "/v1/images/generations")
                XCTAssertEqual(body["model"] as? String, "gpt-image-2")
                XCTAssertEqual(body["size"] as? String, "1024x1024")
                XCTAssertEqual(body["quality"] as? String, "low")
                XCTAssertEqual(body["output_format"] as? String, "png")
                let prompt = try XCTUnwrap(body["prompt"] as? String)
                XCTAssertTrue(prompt.contains("entirely original"))
                XCTAssertTrue(prompt.contains("No text, letters, numbers, logos"))
                let encoded = png.base64EncodedString()
                return self.response(request, json: "{\"data\":[{\"b64_json\":\"\(encoded)\"}]}")
            case 3:
                XCTAssertEqual(request.url?.path, "/v1/moderations")
                XCTAssertEqual(body["model"] as? String, "omni-moderation-latest")
                let input = try XCTUnwrap(body["input"] as? [[String: Any]])
                let imageURL = try XCTUnwrap(
                    (input.first?["image_url"] as? [String: Any])?["url"] as? String
                )
                XCTAssertTrue(imageURL.hasPrefix("data:image/png;base64,"))
                return self.response(request, json: #"{"results":[{"flagged":false}]}"#)
            default:
                XCTFail("Unexpected request \(call)")
                return self.response(request, json: "{}")
            }
        }

        let service = OpenAIHeroImageGenerationService(session: session)
        let generated = try await service.generate(
            design: HeroDesign(),
            description: "Curly hair and a robot fox",
            apiKey: "sk-fixture-never-real"
        )

        XCTAssertEqual(call, 3)
        XCTAssertEqual(generated.imageData, png)
        XCTAssertTrue(generated.prompt.contains("clock-learning app"))
    }

    func testFlaggedTextStopsBeforeGeneration() async {
        var calls = 0
        let session = makeSession { request in
            calls += 1
            return self.response(request, json: #"{"results":[{"flagged":true}]}"#)
        }
        let service = OpenAIHeroImageGenerationService(session: session)

        do {
            _ = try await service.generate(
                design: HeroDesign(),
                description: "An otherwise ordinary idea",
                apiKey: "sk-fixture-never-real"
            )
            XCTFail("Expected moderation rejection")
        } catch {
            XCTAssertEqual(error as? HeroOpenAIServiceError, .contentRejected)
            XCTAssertEqual(calls, 1)
        }
    }

    func testHTTPErrorDoesNotExposeCredentialOrBody() async {
        let session = makeSession { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["x-request-id": "req_hero_fixture"]
            )!
            return (response, Data(#"{"error":"sk-fixture-never-real"}"#.utf8))
        }
        let service = OpenAIHeroImageGenerationService(session: session)

        do {
            _ = try await service.generate(
                design: HeroDesign(),
                description: "Robot fox",
                apiKey: "sk-fixture-never-real"
            )
            XCTFail("Expected HTTP failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("sk-fixture-never-real"))
            XCTAssertTrue(error.localizedDescription.contains("req_hero_fixture"))
        }
    }

    func testTranscriptionUsesExpectedMultipartModelAndParsesText() async throws {
        let session = makeSession { request in
            XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer sk-audio-fixture"
            )
            let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
            let body = String(
                decoding: try XCTUnwrap(heroRequestBodyData(request)),
                as: UTF8.self
            )
            XCTAssertTrue(body.contains("gpt-4o-transcribe"))
            XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nde"))
            XCTAssertTrue(body.contains("name=\"file\""))
            return self.response(
                request,
                json: #"{"text":"  Lockige Haare und ein Roboter-Fuchs  "}"#
            )
        }
        let service = OpenAITranscriptionService(session: session)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hero-audio-\(UUID().uuidString).m4a")
        try Data([0x01, 0x02, 0x03]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let text = try await service.transcribe(
            fileURL: fileURL,
            language: .german,
            apiKey: "sk-audio-fixture"
        )
        XCTAssertEqual(text, "Lockige Haare und ein Roboter-Fuchs")
    }

    func testMultipartFilenameCannotInjectHeaders() {
        let body = HeroTranscriptionRequestBuilder.multipartBody(
            audioData: Data([0x01]),
            fileName: "idea\"\r\nX-Evil: yes.m4a",
            language: .english,
            boundary: "BoundaryFixture"
        )
        let text = String(decoding: body, as: UTF8.self)

        XCTAssertFalse(text.contains("filename=\"idea\"\r\nX-Evil"))
        XCTAssertFalse(text.contains("\r\nX-Evil:"))
        XCTAssertTrue(text.contains("filename=\"idea___X-Evil__yes.m4a\""))
        XCTAssertTrue(text.hasSuffix("--BoundaryFixture--\r\n"))
    }

    func testRejectsOversizedHTTPResponseBeforeReadingBody() async {
        var calls = 0
        let session = makeSession { request in
            calls += 1
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Length": "\(OpenAIHeroImageGenerationService.maximumModerationResponseBytes + 1)"
                ]
            )!
            return (response, Data(#"{"results":[{"flagged":false}]}"#.utf8))
        }

        do {
            _ = try await OpenAIHeroImageGenerationService(session: session).generate(
                design: HeroDesign(),
                description: "Robot fox",
                apiKey: "sk-fixture-never-real"
            )
            XCTFail("Expected response cap")
        } catch {
            XCTAssertEqual(error as? HeroOpenAIServiceError, .responseTooLarge)
            XCTAssertEqual(calls, 1)
        }
    }

    func testRejectsBase64BeforeDecodingAboveEncodedLimit() {
        let oversized = String(
            repeating: "A",
            count: GeneratedHeroImageValidator.maximumBase64Bytes + 1
        )
        let response = Data("{\"data\":[{\"b64_json\":\"\(oversized)\"}]}".utf8)

        XCTAssertThrowsError(
            try OpenAIHeroImageGenerationService.parseGeneratedImage(response)
        ) {
            XCTAssertEqual($0 as? HeroOpenAIServiceError, .malformedResponse)
        }
    }

    func testImageValidatorRejectsJPEGAndOversizedPNGDimensions() throws {
        let smallFormat = UIGraphicsImageRendererFormat()
        smallFormat.scale = 1
        smallFormat.opaque = true
        let smallRenderer = UIGraphicsImageRenderer(
            size: CGSize(width: 8, height: 8),
            format: smallFormat
        )
        let jpeg = smallRenderer.jpegData(withCompressionQuality: 0.8) { context in
            context.cgContext.setFillColor(UIColor.systemBlue.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        XCTAssertFalse(GeneratedHeroImageValidator.isValid(jpeg))

        let wideFormat = UIGraphicsImageRendererFormat()
        wideFormat.scale = 1
        wideFormat.opaque = true
        let wideRenderer = UIGraphicsImageRenderer(
            size: CGSize(
                width: GeneratedHeroImageValidator.maximumPixelDimension + 1,
                height: 1
            ),
            format: wideFormat
        )
        let widePNG = wideRenderer.pngData { context in
            context.cgContext.setFillColor(UIColor.systemOrange.cgColor)
            context.cgContext.fill(CGRect(
                x: 0,
                y: 0,
                width: GeneratedHeroImageValidator.maximumPixelDimension + 1,
                height: 1
            ))
        }
        XCTAssertFalse(GeneratedHeroImageValidator.isValid(widePNG))
    }

    func testTranscriptionRejectsOversizedInputWithoutNetwork() async throws {
        var calls = 0
        let session = makeSession { request in
            calls += 1
            return self.response(request, json: #"{"text":"unused"}"#)
        }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oversized-hero-audio-\(UUID().uuidString).m4a")
        try Data(
            repeating: 0x01,
            count: OpenAITranscriptionService.maximumAudioBytes + 1
        ).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        do {
            _ = try await OpenAITranscriptionService(session: session).transcribe(
                fileURL: fileURL,
                language: .english,
                apiKey: "sk-audio-fixture-never-real"
            )
            XCTFail("Expected audio cap")
        } catch {
            XCTAssertEqual(error as? HeroOpenAIServiceError, .responseTooLarge)
            XCTAssertEqual(calls, 0)
        }
    }

    func testTranscriptionRejectsOversizedResponseBeforeParsing() async throws {
        let session = makeSession { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Length": "\(OpenAITranscriptionService.maximumResponseBytes + 1)"
                ]
            )!
            return (response, Data(#"{"text":"unused"}"#.utf8))
        }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hero-audio-\(UUID().uuidString).m4a")
        try Data([0x01, 0x02, 0x03]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        do {
            _ = try await OpenAITranscriptionService(session: session).transcribe(
                fileURL: fileURL,
                language: .english,
                apiKey: "sk-audio-fixture-never-real"
            )
            XCTFail("Expected response cap")
        } catch {
            XCTAssertEqual(error as? HeroOpenAIServiceError, .responseTooLarge)
        }
    }

    private func makeSession(
        _ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        HeroMockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeroMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func response(
        _ request: URLRequest,
        json: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response, Data(json.utf8))
    }

    private static let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
}

private final class HeroMockURLProtocol: URLProtocol, @unchecked Sendable {
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

private func heroRequestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }

    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { return nil }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}
