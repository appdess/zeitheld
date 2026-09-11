import Foundation
import XCTest
@testable import WatchLearn

/// Opt-in paid integration: production native service and actual AVAudioEngine
/// playback in Simulator. Only synthetic speech is uploaded. The reusable server
/// credential remains inside Scripts/live-native-smoke.py on the Mac.
@MainActor
final class LiveOpenAINativeTests: XCTestCase {
    func testGermanContinuousLiveConversation() async throws { try await conversation(language: .german) }
    func testEnglishContinuousLiveConversation() async throws { try await conversation(language: .english) }

    private func conversation(language: RealtimeCoachLanguage) async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["WATCHLEARN_RUN_NATIVE_LIVE"] == "1",
              let relayText = env["WATCHLEARN_TEST_LIVE_RELAY"], let relayURL = URL(string: relayText),
              relayURL.scheme == "ws", relayURL.host == "127.0.0.1",
              let path = env[language == .german ? "WATCHLEARN_LIVE_PCM_FILE" : "WATCHLEARN_LIVE_EN_PCM_FILE"] else {
            throw XCTSkip("Run Scripts/live-native-smoke.py for the paid native Live simulator test.")
        }
        let speech = try Data(contentsOf: URL(fileURLWithPath: path))
        let capture = LiveContinuousFixtureCapture()
        let playback = RealtimeAudioEngine()
        let service = OpenAILiveService(apiKey: "sk-fixture-loopback-only-never-forwarded", transport: LiveLoopbackTransport(url: relayURL), audioCapture: capture, audioPlayback: playback)
        var grades: [(ClockAnswerReport, ClockAnswerToolResult, Int)] = []
        var coach = ""
        var child = ""
        var audioBytes = 0
        var drains = 0
        var failure: RealtimeAPIError?
        let observer = Task {
            for await event in service.events {
                switch event {
                case .liveClockAnswerReported(let report, let result, let id):
                    grades.append((report, result, id))
                    print("NATIVE_GRADE language=\(language.rawValue) question=\(id) hour=\(String(describing: report.hour)) correct=\(String(describing: result.correct))")
                case .assistantAudio(let data, _): audioBytes += data.count
                case .assistantAudioFinished: drains += 1
                case .transcriptDelta(let speaker, let text):
                    if speaker == .coach { coach += text } else { child += text }
                case .serverError(let error): failure = error
                default: break
                }
            }
        }
        defer { observer.cancel(); capture.stopCapture(); playback.stopAll() }
        do {
            try await service.open(language: language, safetyIdentifier: .init(stableID: "native-synthetic-smoke"))
            try await service.setChallenge(.init(questionID: 1, hour: 3, minute: 0, difficulty: "fullHour", language: language))
            try await service.startVoice(authorizedBy: capture.authorizeCaptureStart())
            try await wait(seconds: 25) { !coach.isEmpty || failure != nil }
            XCTAssertNil(failure)
            // Input continues throughout model speech and delegation. A deliberate
            // interruption exercises the duplex path; no VAD/commit is sent.
            capture.say(speech)
            try await wait(seconds: 45) { !grades.isEmpty || failure != nil }
            XCTAssertNil(failure)
            XCTAssertEqual(grades.first?.0, .init(hour: 3, minute: 0, unknown: false))
            XCTAssertEqual(grades.first?.1.correct, true)
            XCTAssertEqual(grades.first?.2, 1)
            // Let the backend continuation and actual spoken result arrive.
            // A transcript preface such as "let me check" is not grade feedback.
            try await Task.sleep(for: .seconds(8))
            XCTAssertGreaterThan(drains, 0)
            XCTAssertTrue(language == .german ? coach.localizedCaseInsensitiveContains("stimmt") || coach.localizedCaseInsensitiveContains("klasse") || coach.localizedCaseInsensitiveContains("richtig") || coach.localizedCaseInsensitiveContains("genau") || coach.localizedCaseInsensitiveContains("gut") || coach.localizedCaseInsensitiveContains("toll") || coach.localizedCaseInsensitiveContains("super") : coach.localizedCaseInsensitiveContains("great") || coach.localizedCaseInsensitiveContains("right") || coach.localizedCaseInsensitiveContains("good") || coach.localizedCaseInsensitiveContains("correct"), "Inspect the attached synthetic transcript for spoken correctness feedback")
            print("NATIVE_TRANSCRIPT language=\(language.rawValue) first_child=\(child) coach=\(coach)")
            XCTAssertNil(failure)

            // Reuse this same socket/capture for a different target and an
            // intentionally incorrect answer. Old credit must not carry over.
            try await service.setChallenge(.init(questionID: 2, hour: 4, minute: 0, difficulty: "fullHour", language: language))
            try await Task.sleep(for: .seconds(4))
            capture.say(speech)
            try await wait(seconds: 45) { grades.contains(where: { $0.2 == 2 }) || failure != nil }
            XCTAssertNil(failure)
            let wrong = grades.first(where: { $0.2 == 2 })
            XCTAssertEqual(wrong?.0, .init(hour: 3, minute: 0, unknown: false))
            XCTAssertEqual(wrong?.1.correct, false)
            XCTAssertEqual(wrong?.1.expectedHour, 4)
            try await Task.sleep(for: .seconds(8))
            print("NATIVE_TRANSCRIPT language=\(language.rawValue) final_child=\(child) coach=\(coach)")
            // An "I don't know" / help request must not award success.
            let unknownPath = try XCTUnwrap(env[language == .german ? "WATCHLEARN_LIVE_UNKNOWN_PCM_FILE" : "WATCHLEARN_LIVE_EN_UNKNOWN_PCM_FILE"])
            let gradeCount = grades.count
            let beforeHelp = coach.count
            capture.say(try Data(contentsOf: URL(fileURLWithPath: unknownPath)))
            try await Task.sleep(for: .seconds(10))
            XCTAssertFalse(grades.dropFirst(gradeCount).contains(where: { $0.1.correct == true }))
            XCTAssertGreaterThan(coach.count, beforeHelp, "The coach should give spoken help for uncertainty")
            XCTAssertNil(failure)
            print("NATIVE_HELP language=\(language.rawValue) coach=\(String(coach.dropFirst(beforeHelp)))")
            XCTAssertGreaterThan(audioBytes, 24000)
            XCTAssertGreaterThan(drains, 0)
            XCTAssertEqual(capture.starts, 1)
            await service.disconnect()
            XCTAssertFalse(capture.running)
            let finalUsage = await service.finalUsageSeconds
            XCTAssertNotNil(finalUsage, "The real provider must confirm session.closed and final usage")
            print("NATIVE_FINAL language=\(language.rawValue) seconds=\(String(describing: finalUsage)) played_buffers=\(drains)")
        } catch {
            print("NATIVE_DIAGNOSTIC child=\(child) coach=\(coach) failure_code=\(failure?.code ?? "none")")
            await service.disconnect()
            throw error
        }
    }

    private func wait(seconds: Int, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(40))
        }
    }
}

private actor LiveLoopbackTransport: RealtimeWebSocketTransporting {
    let url: URL
    let inner = URLSessionRealtimeWebSocketTransport()
    init(url: URL) { self.url = url }
    func connect(request: URLRequest) async throws {
        var local = request; local.url = url
        local.setValue(nil, forHTTPHeaderField: "Authorization")
        try await inner.connect(request: local)
    }
    func send(text: String) async throws { try await inner.send(text: text) }
    func receive() async throws -> RealtimeWebSocketMessage { try await inner.receive() }
    func disconnect() async { await inner.disconnect() }
}

@MainActor
private final class LiveContinuousFixtureCapture: RealtimeAudioCapturing {
    let authorization = RealtimeAudioCaptureAuthorizationState()
    var task: Task<Void, Never>?
    var pending = Data()
    private(set) var starts = 0
    private(set) var running = false
    func authorizeCaptureStart() -> RealtimeAudioCaptureAuthorization { authorization.issue() }
    func startCapture(authorizedBy token: RealtimeAudioCaptureAuthorization,
                      onPCM16Chunk: @escaping @Sendable (Data) -> Void,
                      onCaptureFailure: @escaping @Sendable (RealtimeAudioEngineError) -> Void) async throws {
        try authorization.validate(token)
        starts += 1; running = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let bytes = 960 // 20 ms, paced continuously including silence.
                var chunk = Data(self.pending.prefix(bytes))
                self.pending = Data(self.pending.dropFirst(min(bytes, self.pending.count)))
                if chunk.count < bytes { chunk.append(Data(repeating: 0, count: bytes - chunk.count)) }
                onPCM16Chunk(chunk)
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
    }
    func say(_ speech: Data) { pending = speech }
    func stopCapture() { authorization.revoke(); running = false; task?.cancel(); task = nil; pending = Data() }
}
