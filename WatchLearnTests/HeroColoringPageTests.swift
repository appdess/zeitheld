import Foundation
import UIKit
import XCTest
@testable import WatchLearn

final class HeroColoringPageTests: XCTestCase {
    override func tearDown() {
        ColoringURLProtocol.handler = nil
        super.tearDown()
    }

    func testColoringEditUsesOriginalImageAndModeratesBothImages() async throws {
        let image = try XCTUnwrap(Data(base64Encoded: Self.png))
        var calls = 0
        let session = session { request in
            calls += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            let body = try XCTUnwrap(Self.body(request))
            if calls == 2 {
                XCTAssertEqual(request.url?.path, "/v1/images/edits")
                XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
                XCTAssertNotNil(body.range(of: image), "The edit must receive the actual saved hero.")
                let text = String(decoding: body, as: UTF8.self)
                XCTAssertTrue(text.contains("name=\"image\"; filename=\"time-hero.png\""))
                XCTAssertTrue(text.contains("name=\"model\"\r\n\r\ngpt-image-2"))
                XCTAssertTrue(text.contains("name=\"quality\"\r\n\r\nlow"))
                XCTAssertTrue(text.contains("Preserve the same hero"))
                XCTAssertTrue(text.contains("numerals 1 through 12 and two clearly distinct hands"))
                return Self.response(request, json: "{\"data\":[{\"b64_json\":\"\(Self.png)\"}]}")
            }
            XCTAssertEqual(request.url?.path, "/v1/moderations")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let input = try XCTUnwrap(object["input"] as? [[String: Any]])
            let imageURL = try XCTUnwrap(input.first?["image_url"] as? [String: Any])
            XCTAssertEqual(imageURL["url"] as? String, "data:image/png;base64,\(Self.png)")
            return Self.response(request, json: #"{"results":[{"flagged":false}]}"#)
        }
        let result = try await HeroColoringPageService(session: session).generate(referenceImageData: image, credential: .parentKey("fixture"))
        XCTAssertEqual(result, image)
        XCTAssertEqual(calls, 3)
    }

    func testRejectedColoringOutputNeverReturnsAnImage() async throws {
        let image = try XCTUnwrap(Data(base64Encoded: Self.png))
        var calls = 0
        let session = session { request in
            calls += 1
            if calls == 2 { return Self.response(request, json: "{\"data\":[{\"b64_json\":\"\(Self.png)\"}]}") }
            return Self.response(request, json: calls == 3 ? #"{"results":[{"flagged":true}]}"# : #"{"results":[{"flagged":false}]}"#)
        }
        do {
            _ = try await HeroColoringPageService(session: session).generate(referenceImageData: image, credential: .parentKey("fixture"))
            XCTFail("Flagged output must not reach the preview.")
        } catch {
            XCTAssertEqual(error as? HeroOpenAIServiceError, .contentRejected)
        }
        XCTAssertEqual(calls, 3)
    }

    func testInvalidReferenceDoesNotMakeAnyNetworkRequest() async {
        var calls = 0
        let session = session { request in
            calls += 1
            return Self.response(request, json: "{}")
        }
        do {
            _ = try await HeroColoringPageService(session: session).generate(referenceImageData: Data("invalid".utf8), credential: .parentKey("fixture"))
            XCTFail("Invalid reference must be rejected before upload.")
        } catch {
            XCTAssertEqual(error as? HeroOpenAIServiceError, .invalidImage)
        }
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testColoringPreservesSavedHeroAndBackgroundAndClearsAfterDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coloring-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GeneratedHeroImageStore(directory: directory)
        let original = try XCTUnwrap(Self.makePNG(.blue))
        let coloring = try XCTUnwrap(Self.makePNG(.white))
        _ = try await store.saveLatest(original)
        _ = try await store.selectLatestAsBackground()
        let generator = ImmediateColoringGenerator(result: coloring)
        let model = HeroLabViewModel(coloringGenerator: generator, store: store, usageBudget: UnlimitedHeroCloudUsageBudget())
        await model.loadSavedImages()
        await model.generateColoring(credential: .parentKey("fixture"))
        XCTAssertEqual(model.coloringImageData, coloring)
        XCTAssertEqual(model.latestImageData, original)
        XCTAssertEqual(model.selectedBackgroundData, original)
        let latest = try await store.loadLatest()
        let background = try await store.loadSelectedBackground()
        XCTAssertEqual(latest?.imageData, original)
        XCTAssertEqual(background?.imageData, original)
        let received = await generator.reference
        XCTAssertEqual(received, original)
        model.cancelCloudWork()
        try await store.deleteAll()
        await model.loadSavedImages()
        XCTAssertNil(model.coloringImageData)
        XCTAssertNil(model.latestImageData)
    }

    @MainActor
    func testColoringUsesImageAllowanceAndNeverCallsProviderWhenExhausted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coloring-limit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GeneratedHeroImageStore(directory: directory)
        let image = try XCTUnwrap(Self.makePNG(.blue))
        _ = try await store.saveLatest(image)
        let generator = ImmediateColoringGenerator(result: image)
        let budget = ExhaustedColoringBudget()
        let model = HeroLabViewModel(coloringGenerator: generator, store: store, usageBudget: budget)
        await model.loadSavedImages()
        await model.generateColoring(credential: .managedAccount)
        XCTAssertEqual(model.issue, .usageLimit(.dailyLimit(operation: .coloring)))
        XCTAssertNil(model.coloringImageData)
        let called = await generator.reference
        XCTAssertNil(called)
        let operation = await budget.operation
        XCTAssertEqual(operation, .coloring)
    }

    @MainActor
    func testCancelledColoringCannotPublishLateResultOrReplaceOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coloring-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GeneratedHeroImageStore(directory: directory)
        let original = try XCTUnwrap(Self.makePNG(.blue))
        _ = try await store.saveLatest(original)
        let generator = GatedColoringGenerator()
        let model = HeroLabViewModel(coloringGenerator: generator, store: store, usageBudget: UnlimitedHeroCloudUsageBudget())
        await model.loadSavedImages()
        let task = model.startColoring(credential: .parentKey("fixture"))
        await generator.waitUntilStarted()
        XCTAssertEqual(model.phase, .coloring)
        model.cancelCloudWork()
        await generator.complete(with: try XCTUnwrap(Self.makePNG(.white)))
        await task.value
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.coloringImageData)
        XCTAssertEqual(model.latestImageData, original)
        XCTAssertNil(model.issue)
    }

    private func session(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
        ColoringURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ColoringURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(_ request: URLRequest, json: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    private static func body(_ request: URLRequest) -> Data? {
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

    @MainActor private static func makePNG(_ color: UIColor) -> Data? {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
}

private actor ImmediateColoringGenerator: HeroColoringPageGenerating {
    let result: Data
    private(set) var reference: Data?
    init(result: Data) { self.result = result }
    func generate(referenceImageData: Data, credential: HeroCredential) async throws -> Data {
        reference = referenceImageData
        return result
    }
}

private actor ExhaustedColoringBudget: HeroCloudUsageBudgeting {
    private(set) var operation: HeroCloudOperation?
    func authorize(_ operation: HeroCloudOperation, at date: Date) throws {
        self.operation = operation
        throw HeroCloudUsageBudgetError.dailyLimit(operation: operation)
    }
}

private actor GatedColoringGenerator: HeroColoringPageGenerating {
    private var completion: CheckedContinuation<Data, Never>?
    func generate(referenceImageData: Data, credential: HeroCredential) async throws -> Data {
        await withCheckedContinuation { completion = $0 }
    }
    func waitUntilStarted() async {
        while completion == nil { await Task.yield() }
    }
    func complete(with image: Data) {
        completion?.resume(returning: image)
        completion = nil
    }
}

private final class ColoringURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
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
