import Foundation
import XCTest
@testable import WatchLearn

/// Opt-in, cost-bearing smoke test for the production Realtime protocol.
///
/// It is skipped in normal CI. To run it, explicitly set
/// Run Scripts/live-smoke.py with an authorized Keychain credential. The helper
/// supplies synthetic PCM and a loopback broker; no reusable key enters Xcode's
/// environment or arguments.
@MainActor
final class LiveOpenAIRealtimeTests: XCTestCase {
    func testGermanSpokenClockAnswerRoundTrip() async throws {
        try await spokenClockAnswerRoundTrip(language: .german, fixtureVariable: "WATCHLEARN_LIVE_PCM_FILE")
    }

    func testEnglishSpokenClockAnswerRoundTrip() async throws {
        try await spokenClockAnswerRoundTrip(language: .english, fixtureVariable: "WATCHLEARN_LIVE_EN_PCM_FILE")
    }

    func testParentSetupStoresKeyAndChecksRealConnection() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WATCHLEARN_RUN_LIVE_REALTIME"] == "1",
              let text = environment["WATCHLEARN_TEST_PARENT_KEY_BRIDGE"],
              let url = URL(string: text), url.scheme == "http", url.host == "127.0.0.1" else {
            throw XCTSkip("Use --install-simulator-key with the live smoke helper.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let key = String(data: data, encoding: .utf8), key.hasPrefix("sk-") else {
            return XCTFail("The one-use simulator key handoff failed.")
        }
        let preferences = ParentPreferences()
        try preferences.storeAPIKey(key)
        preferences.language = .german
        preferences.cloudVoiceMode = .parentKey
        preferences.hasCloudVoiceConsent = true
        await preferences.checkVoiceConnection()
        XCTAssertEqual(preferences.connectionCheck, .connected)
        XCTAssertTrue(ParentPreferences().hasStoredAPIKey)
    }

    private func spokenClockAnswerRoundTrip(language: RealtimeCoachLanguage, fixtureVariable: String) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WATCHLEARN_RUN_LIVE_REALTIME"] == "1" else {
            throw XCTSkip("Set WATCHLEARN_RUN_LIVE_REALTIME=1 to opt in to this cost-bearing live test.")
        }
        // The test broker mints only short-lived tokens. A reusable API key
        // never enters the simulator environment or Xcode result attachments.
        let provider: any RealtimeClientSecretProviding
        if let urlText = environment["WATCHLEARN_TEST_TOKEN_BROKER"],
           let url = URL(string: urlText), url.scheme == "http", url.host == "127.0.0.1" {
            provider = LoopbackTestTokenProvider(url: url)
        } else {
            throw XCTSkip("Run Scripts/live-smoke.py to supply a loopback token broker.")
        }
        guard let fixturePath = environment[fixtureVariable],
              FileManager.default.fileExists(atPath: fixturePath) else {
            throw XCTSkip("Set WATCHLEARN_LIVE_PCM_FILE to a 24 kHz mono PCM16 speech fixture.")
        }

        let fixture = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        XCTAssertFalse(fixture.isEmpty)

        let timing = LiveSpeechTiming()
        let capture = RealtimeFixtureCapture(pcm16: fixture, timing: timing)
        let playback = RealtimeFixturePlayback()
        let service = OpenAIRealtimeService(
            tokenProvider: provider,
            audioCapture: capture,
            audioPlayback: playback
        )

        do {
            try await service.connect(
                options: RealtimeSessionOptions(language: language),
                safetyIdentifier: RealtimeSafetyIdentifier(stableID: "watchlearn-live-test")
            )
            try await service.updateChallenge(
                ClockChallengeContext(
                    hour: 3,
                    minute: 0,
                    difficulty: "full-hour",
                    language: language
                ),
                askCoachToStart: false
            )

            let resultTask = Task {
                try await Self.awaitSuccessfulRoundTrip(in: service.events, expectedHour: 3, correct: true, timing: timing)
            }
            defer { resultTask.cancel() }
            try await service.startVoice(
                authorizedBy: capture.authorizeCaptureStart()
            )
            let result = try await resultTask.value

            XCTAssertEqual(result.report, ClockAnswerReport(hour: 3, minute: 0, unknown: false))
            XCTAssertEqual(result.grade.correct, true)
            XCTAssertGreaterThan(result.coachAudioBytes, 0)

            // Keep the same live session and microphone stream for the next
            // clock. Repeating "three" against four o'clock must get a gentle
            // correction, not stale credit for the previous exercise.
            try await service.updateChallenge(
                ClockChallengeContext(hour: 4, minute: 0, difficulty: "full-hour", language: language),
                askCoachToStart: false
            )
            let secondTurn = Task {
                try await Self.awaitSuccessfulRoundTrip(in: service.events, expectedHour: 4, correct: false, timing: timing)
            }
            defer { secondTurn.cancel() }
            capture.repeatAnswer()
            let correction = try await secondTurn.value
            XCTAssertEqual(correction.report, ClockAnswerReport(hour: 3, minute: 0, unknown: false))
            XCTAssertEqual(correction.grade.correct, false)
            XCTAssertEqual(correction.grade.expectedHour, 4)
            XCTAssertGreaterThan(correction.coachAudioBytes, 0)
        } catch {
            await service.disconnect()
            throw error
        }
        await service.disconnect()
    }

    private static func awaitSuccessfulRoundTrip(
        in stream: AsyncStream<RealtimeServiceEvent>, expectedHour: Int, correct: Bool, timing: LiveSpeechTiming
    ) async throws -> LiveRoundTripResult {
        try await withThrowingTaskGroup(of: LiveRoundTripResult.self) { group in
            group.addTask {
                var report: ClockAnswerReport?
                var grade: ClockAnswerToolResult?
                var audioBytes = 0
                var feedbackFinished = false
                var measuredFirstAudio = false

                for await event in stream {
                    switch event {
                    case .speechStarted:
                        print("LIVE_EVENT clock=\(expectedHour) speech_started")
                    case .speechStopped:
                        print("LIVE_EVENT clock=\(expectedHour) speech_stopped")
                    case let .clockAnswerReported(value, result) where result.expectedHour == expectedHour:
                        print("LIVE_EVENT clock=\(expectedHour) graded correct=\(String(describing: result.correct))")
                        report = value
                        grade = result
                        audioBytes = 0
                        feedbackFinished = false
                    case let .assistantAudio(data, _) where grade != nil:
                        if !measuredFirstAudio {
                            measuredFirstAudio = true
                            if let latency = timing.secondsSinceSpeechEnd {
                                print(String(format: "LIVE_LATENCY clock=%d end-of-input-to-feedback=%.3fs", expectedHour, latency))
                            }
                        }
                        audioBytes += data.count
                    case .spokenCorrectAnswerFeedbackFinished where correct && audioBytes > 0:
                        feedbackFinished = true
                    case .assistantAudioFinished where !correct && audioBytes > 0:
                        feedbackFinished = true
                    case let .serverError(error):
                        throw LiveRealtimeTestError.server(error.code, error.message)
                    case let .clockAnswerReported(_, result):
                        print("LIVE_EVENT clock=\(expectedHour) unexpected_grade target=\(String(describing: result.expectedHour))")
                    case .assistantAudioFinished:
                        print("LIVE_EVENT clock=\(expectedHour) audio_finished_without_grade")
                    default:
                        break
                    }

                    if let report,
                       let grade,
                       audioBytes > 0, feedbackFinished {
                        return LiveRoundTripResult(
                            report: report,
                            grade: grade,
                            coachAudioBytes: audioBytes
                        )
                    }
                }
                throw LiveRealtimeTestError.streamEnded
            }
            group.addTask {
                try await Task.sleep(for: .seconds(45))
                throw LiveRealtimeTestError.timedOut
            }

            guard let result = try await group.next() else {
                throw LiveRealtimeTestError.streamEnded
            }
            group.cancelAll()
            return result
        }
    }
}

private struct LiveRoundTripResult: Sendable {
    let report: ClockAnswerReport
    let grade: ClockAnswerToolResult
    let coachAudioBytes: Int
}

private enum LiveRealtimeTestError: Error {
    case server(String?, String)
    case streamEnded
    case timedOut
}

@MainActor
private final class RealtimeFixtureCapture: RealtimeAudioCapturing {
    private let captureAuthorizationState = RealtimeAudioCaptureAuthorizationState()
    private let pcm16: Data
    private let timing: LiveSpeechTiming
    private var task: Task<Void, Never>?
    private var sink: (@Sendable (Data) -> Void)?

    init(pcm16: Data, timing: LiveSpeechTiming) {
        self.pcm16 = pcm16
        self.timing = timing
    }

    func authorizeCaptureStart() -> RealtimeAudioCaptureAuthorization {
        captureAuthorizationState.issue()
    }

    func startCapture(
        authorizedBy authorization: RealtimeAudioCaptureAuthorization,
        onPCM16Chunk: @escaping @Sendable (Data) -> Void,
        onCaptureFailure _: @escaping @Sendable (RealtimeAudioEngineError) -> Void
    ) async throws {
        try captureAuthorizationState.validate(authorization)
        sink = onPCM16Chunk
        repeatAnswer()
    }

    func repeatAnswer() {
        guard let onPCM16Chunk = sink else { return }
        task?.cancel()
        let data = pcm16
        timing.reset()
        task = Task {
            // 100 ms at 24 kHz, mono Int16. Pacing it like a microphone makes
            // semantic VAD exercise the same boundary detection as the app.
            let bytesPerChunk = 4_800
            var offset = 0
            while offset < data.count, !Task.isCancelled {
                let end = min(offset + bytesPerChunk, data.count)
                onPCM16Chunk(data.subdata(in: offset..<end))
                offset = end
                try? await Task.sleep(for: .milliseconds(100))
            }

            timing.markSpeechEnd()

            // Always provide up to ten seconds of silence so semantic VAD observes a
            // complete turn even when the supplied fixture ends immediately
            // after speech.
            let silence = Data(repeating: 0, count: bytesPerChunk)
            for _ in 0..<100 where !Task.isCancelled {
                onPCM16Chunk(silence)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stopCapture() {
        captureAuthorizationState.revoke()
        sink = nil
        task?.cancel()
        task = nil
    }
}

@MainActor
private final class RealtimeFixturePlayback: RealtimeAudioPlaying {
    func enqueuePCM16(_: Data, itemID _: String?, responseID _: String) {}
    func notifyWhenPlaybackDrained(
        responseID: String,
        onDrained: @escaping @Sendable (String) -> Void
    ) {
        onDrained(responseID)
    }
    func stopPlayback() {}
}


private struct LoopbackTestTokenProvider: RealtimeClientSecretProviding {
    let url: URL
    func clientSecret(options: RealtimeSessionOptions,
                      safetyIdentifier: RealtimeSafetyIdentifier) async throws -> RealtimeClientSecret {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.httpBody = try RealtimeEventEncoder.clientSecretRequest(options: options)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        return try RealtimeClientSecretResponseParser.parse(data: data, response: response)
    }
}

private final class LiveSpeechTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var speechEnd: TimeInterval?
    func reset() { lock.withLock { speechEnd = nil } }
    func markSpeechEnd() { lock.withLock { speechEnd = ProcessInfo.processInfo.systemUptime } }
    var secondsSinceSpeechEnd: TimeInterval? {
        lock.withLock { speechEnd.map { ProcessInfo.processInfo.systemUptime - $0 } }
    }
}
