import Foundation
import Observation
import SwiftUI

#if DEBUG
/// An explicit, non-network fixture for exercising the complete Hero Lab UI
/// lifecycle. It is activated only when both `--ui-testing` and this launch
/// argument are present, so normal and production launches always use OpenAI.
enum HeroGenerationUITestFixture {
    static let launchArgument = "--ui-testing-hero-generation-fixture"
    static let credential = "sk-ui-fixture-never-sent"

    static func storeDirectory(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("WatchLearn", isDirectory: true)
            .appendingPathComponent("GeneratedHeroes-UITestFixture", isDirectory: true)
    }

    static func resetStore(fileManager: FileManager = .default) {
        let directory = storeDirectory(fileManager: fileManager)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try? fileManager.removeItem(at: directory)
    }
}

/// The test explicitly releases pending work after observing the real UI state.
/// Wall-clock delays race with accessibility queries on slower hosted runners.
@MainActor @Observable
final class HeroUITestRequestGate {
    static let shared = HeroUITestRequestGate()
    enum Request: String, CaseIterable {
        case image, description, coloring
    }
    private(set) var pending = Set<Request>()

    func waitForRelease(_ request: Request) async throws {
        pending.insert(request)
        defer { pending.remove(request) }
        while pending.contains(request) {
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
    }

    func release(_ request: Request) { pending.remove(request) }
}

struct HeroUITestCompletionControls: View {
    @Bindable private var gate = HeroUITestRequestGate.shared
    var body: some View {
        ForEach(HeroUITestRequestGate.Request.allCases, id: \.self) { request in
            if gate.pending.contains(request) {
                Button("Complete simulated \(request.rawValue) request") {
                    gate.release(request)
                }
                .font(.caption)
                .accessibilityIdentifier("ui-test-fixture-complete-\(request.rawValue)")
            }
        }
    }
}

/// Returns a tiny valid PNG without network I/O after the test releases it.
struct ControlledHeroImageUITestGenerator: HeroImageGenerating {
    func generate(
        design _: HeroDesign,
        description _: String,
        apiKey _: String
    ) async throws -> GeneratedHeroImage {
        try await HeroUITestRequestGate.shared.waitForRelease(.image)

        let encodedPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2uAAAAABJRU5ErkJggg=="
        guard let imageData = Data(base64Encoded: encodedPNG) else {
            throw HeroOpenAIServiceError.invalidImage
        }
        return GeneratedHeroImage(imageData: imageData, prompt: "ui-test-fixture")
    }
}

/// A separate, gated edit fixture. Receiving the local hero and returning a
/// valid PNG exercises the real coloring lifecycle without any network call.
struct ControlledHeroColoringUITestGenerator: HeroColoringPageGenerating {
    func generate(referenceImageData: Data, credential _: HeroCredential) async throws -> Data {
        guard GeneratedHeroImageValidator.isValid(referenceImageData) else {
            throw HeroOpenAIServiceError.invalidImage
        }
        try await HeroUITestRequestGate.shared.waitForRelease(.coloring)
        let encodedPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        guard let data = Data(base64Encoded: encodedPNG) else {
            throw HeroOpenAIServiceError.invalidImage
        }
        return data
    }
}

/// Visual fixture only; never opens a microphone or sends a provider request.
@MainActor @Observable
final class HeroVoiceInputUITestRecorder: HeroDescriptionRecording {
    private(set) var isRecording = false
    private var startedAt = Date()
    private var completion: CheckedContinuation<URL, Error>?
    var audioLevel: Double { isRecording ? 0.7 : 0 }
    var elapsedSeconds: TimeInterval { isRecording ? Date().timeIntervalSince(startedAt) : 0 }
    func recordClip(maxDuration: TimeInterval) async throws -> URL {
        startedAt = Date(); isRecording = true
        return try await withCheckedThrowingContinuation { completion = $0 }
    }
    func stopRecording() {
        guard let completion else { return }
        self.completion = nil; isRecording = false
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("watchlearn-hero-\(UUID()).m4a")
        do { try Data().write(to: url); completion.resume(returning: url) }
        catch { completion.resume(throwing: error) }
    }
    func cancelRecording() {
        isRecording = false
        let completion = completion; self.completion = nil
        completion?.resume(throwing: CancellationError())
    }
}
struct HeroVoiceInputUITestTranscriber: HeroDescriptionTranscribing {
    func transcribe(fileURL: URL, language: LearningLanguage, apiKey: String) async throws -> String {
        try await HeroUITestRequestGate.shared.waitForRelease(.description)
        return language == .german ? "Ein freundlicher Held mit blauem Umhang." : "A friendly hero with a blue cape."
    }
}
#endif
