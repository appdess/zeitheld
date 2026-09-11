import Foundation
import AudioToolbox
import UIKit
@preconcurrency import WebRTC
import XCTest
@testable import WatchLearn

/// Paid, explicitly enabled tests. Credentials and synthetic audio live outside
/// the app bundle. The production session and WebRTC stack are unchanged; only
/// the physical microphone/speaker is replaced by a deterministic audio device.
@MainActor
final class ManagedLiveIntegrationTests: XCTestCase {
    /// Real provider output with silent synthetic input: verifies the hero
    /// greets first in both languages without transmitting microphone audio.
    func testSignedInParentGreetsAndAdvancesInBothLanguages() async throws {
        guard ProcessInfo.processInfo.environment["WATCHLEARN_RUN_SIGNED_IN_GREETING"] == "1" else {
            throw XCTSkip("Explicitly enable the paid signed-in greeting test.")
        }
        // External synthetic fixtures are copied to the device's temporary
        // directory explicitly; no microphone or real child speech is used.
        let fixtures = try ["de", "en"].map {
            try Data(contentsOf: FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-answer-\($0).pcm"))
        }
        for _ in 0..<100 where UIApplication.shared.applicationState != .active {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard UIApplication.shared.applicationState == .active else {
            throw XCTSkip("The signed-in test host must be in the foreground.")
        }
        for (index, language) in [RealtimeCoachLanguage.german, .english].enumerated() {
            let credential = try await ParentAccount.shared.voiceCredential()
            guard case let .managedLive(base, token) = credential else {
                XCTFail("Expected managed account"); return
            }
            let audio = SyntheticWebRTCAudioDevice()
            let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: audio)
            let service = ManagedLiveSession(baseURL: base, token: token, factory: factory)
            var greeting = ""
            var speaking = false
            var sawSpeech = false
            var grades: [(Int, Bool)] = []
            var advances: [Int] = []
            let observer = Task { @MainActor in
                for await event in service.events {
                    if case let .transcriptDelta(speaker, text) = event, speaker == .coach { greeting += text }
                    if case .assistantAudio = event { speaking = true; sawSpeech = true }
                    if case .assistantAudioFinished = event { speaking = false }
                    if case let .liveClockAnswerReported(_, result, id) = event { grades.append((id, result.correct == true)) }
                    if case let .liveAdvanceRequested(id) = event { advances.append(id) }
                }
            }
            do {
                try await service.open(language: language, safetyIdentifier: .init(stableID: "silent-greeting-test"))
                try await service.setChallenge(.init(questionID: 1, hour: 3, minute: 0, difficulty: "fullHour", language: language))
                try await service.startVoice(authorizedBy: service.authorizeCaptureStart())
                try await wait(20) {
                    greeting.lowercased().contains(language == .german ? "zeitheld" : "time hero")
                        && audio.nonSilentOutputFrames > 4800
                }
                print("FIRST_GREETING language=\(language.rawValue) before_input=true audible_output=true")
                try await wait(15) { sawSpeech && !speaking }
                audio.say(fixtures[index])
                try await wait(35) { !advances.isEmpty }
                XCTAssertEqual(grades.first?.0, 1)
                XCTAssertEqual(grades.first?.1, true)
                XCTAssertEqual(advances, [1])
                print("LIVE_PROGRESS language=\(language.rawValue) correct=true automatic_next=true")
                // Repeat the same spoken time on a different clock: it must
                // be graded wrong, with no automatic progress or extra star.
                sawSpeech = false
                try await service.setChallenge(.init(questionID: 2, hour: 4, minute: 0, difficulty: "fullHour", language: language))
                try await wait(15) { sawSpeech && !speaking }
                audio.say(fixtures[index])
                try await wait(35) { grades.contains { $0.0 == 2 } }
                XCTAssertEqual(grades.first { $0.0 == 2 }?.1, false)
                try await Task.sleep(for: .seconds(4))
                XCTAssertEqual(advances, [1])
                print("LIVE_PROGRESS language=\(language.rawValue) wrong_stays_on_clock=true")
                await service.disconnect()
                observer.cancel(); audio.finish()
                await ParentAccount.shared.refresh()
                XCTAssertEqual(ParentAccount.shared.allowance?.active, false)
            } catch {
                await service.disconnect(); observer.cancel(); audio.finish()
                let failure = error as NSError
                XCTFail("Greeting failed: \(failure.domain) code=\(failure.code)")
                return
            }
        }
    }

    /// Explicit real-device regression: includes native microphone/audio activation,
    /// which transport-only handshake checks do not exercise. Never logs speech.
    func testSignedInParentNativeVoiceStartAndStop() async throws {
        guard ProcessInfo.processInfo.environment["WATCHLEARN_RUN_SIGNED_IN_VOICE_START"] == "1" else {
            throw XCTSkip("Explicitly enable the paid signed-in native voice-start test.")
        }
        guard SystemMicrophonePermissionService().currentPermission() == .granted else {
            throw XCTSkip("An adult must grant microphone permission before this test.")
        }
        // App-hosted unit tests may run before the host becomes foreground.
        // Do not spend a session on an iOS background-audio rejection.
        for _ in 0..<100 where UIApplication.shared.applicationState != .active {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard UIApplication.shared.applicationState == .active else {
            throw XCTSkip("Use the foreground voice-button UI test on this device.")
        }
        let credential = try await ParentAccount.shared.voiceCredential()
        guard case let .managedLive(base, token) = credential else {
            XCTFail("Expected the parent's managed account"); return
        }
        let service = ManagedLiveSession(baseURL: base, token: token)
        service.diagnostics = { print("NATIVE_VOICE \($0)") }
        var greeted = false
        let observer = Task { @MainActor in
            for await event in service.events {
                if case let .transcriptDelta(speaker, text) = event, speaker == .coach, !text.isEmpty {
                    greeted = true
                }
            }
        }
        defer { observer.cancel() }
        do {
            print("NATIVE_VOICE opening")
            try await service.open(language: .german, safetyIdentifier: .init(stableID: "native-voice-start-test"))
            print("NATIVE_VOICE transport_connected")
            try await service.setChallenge(.init(questionID: 1, hour: 3, minute: 0, difficulty: "fullHour", language: .german))
            print("NATIVE_VOICE activating_audio")
            try await service.startVoice(authorizedBy: service.authorizeCaptureStart())
            print("NATIVE_VOICE audio_started")
            XCTAssertTrue(RTCAudioSession.sharedInstance().isAudioEnabled)
            XCTAssertTrue(RTCAudioSession.sharedInstance().categoryOptions.contains(.defaultToSpeaker))
            XCTAssertFalse(RTCAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInReceiver })
            try await wait(15) { greeted }
            print("NATIVE_VOICE greeting_received speaker_route_confirmed")
            service.stopAll()
            await service.disconnect()
            XCTAssertFalse(RTCAudioSession.sharedInstance().isAudioEnabled)
            await ParentAccount.shared.refresh()
            XCTAssertEqual(ParentAccount.shared.allowance?.active, false)
            print("NATIVE_VOICE audio_stopped provider_closed account_settled")
        } catch {
            await service.disconnect()
            let error = error as NSError
            XCTFail("Native voice start failed: \(error.domain) code=\(error.code)")
        }
    }

    /// Uses the actual signed-in parent and the production native audio device.
    /// Opens transport only: microphone capture is never enabled by this test.
    func testSignedInParentNativeAudioHandshake() async throws {
        guard ProcessInfo.processInfo.environment["WATCHLEARN_RUN_SIGNED_IN_HANDSHAKE"] == "1" else {
            throw XCTSkip("Explicitly enable the paid signed-in device handshake test.")
        }
        let credential = try await ParentAccount.shared.voiceCredential()
        guard case let .managedLive(base, token) = credential else {
            XCTFail("Expected the parent's managed account"); return
        }
        let service = ManagedLiveSession(baseURL: base, token: token)
        service.diagnostics = { print("NATIVE_HANDSHAKE \($0)") }
        do {
            try await service.open(language: .german, safetyIdentifier: .init(stableID: "native-handshake-test"))
            try await service.setChallenge(.init(questionID: 1, hour: 3, minute: 0, difficulty: "fullHour", language: .german))
            // Stop/background cancels the startup caller. Cleanup must still
            // reach the backend rather than inheriting URLSession cancellation.
            let cleanup = Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                await service.disconnect()
            }
            cleanup.cancel()
            await cleanup.value
            await ParentAccount.shared.refresh()
            XCTAssertEqual(ParentAccount.shared.allowance?.active, false)
            try await service.open(language: .german, safetyIdentifier: .init(stableID: "native-handshake-test"))
            await service.disconnect()
            await ParentAccount.shared.refresh()
            XCTAssertEqual(ParentAccount.shared.allowance?.active, false)
            print("NATIVE_HANDSHAKE connected context_sent cancelled_caller_closed reconnected account_settled")
        } catch {
            await service.disconnect()
            let failure = error as NSError
            XCTFail("Native handshake failed: \(failure.domain) code=\(failure.code)")
        }
    }

    func testGermanDirectWebRTC() async throws { try await conversation(.german) }
    func testEnglishDirectWebRTC() async throws { try await conversation(.english) }

    private func conversation(_ language: RealtimeCoachLanguage) async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["WATCHLEARN_RUN_MANAGED_LIVE"] == "1",
              let tokenPath = env["WATCHLEARN_MANAGED_TOKEN_FILE"],
              let speechPath = env[language == .german ? "WATCHLEARN_LIVE_PCM_FILE" : "WATCHLEARN_LIVE_EN_PCM_FILE"] else {
            throw XCTSkip("Explicitly enable the paid managed Live integration test.")
        }
        let token = try String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let audio = SyntheticWebRTCAudioDevice()
        let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: audio)
        let baseURL = try XCTUnwrap(ManagedServiceConfiguration.baseURL)
        let service = ManagedLiveSession(baseURL: baseURL, token: token, factory: factory)
        service.diagnostics = { print("MANAGED_EVENT \(language.rawValue) \($0)") }
        var coach = "", child = ""
        var grades: [(ClockAnswerReport, ClockAnswerToolResult, Int)] = []
        var failed = false
        let observer = Task {
            for await event in service.events {
                switch event {
                case .transcriptDelta(let speaker, let text):
                    if speaker == .coach { coach += text } else { child += text }
                    print("MANAGED_TEXT \(language.rawValue) \(speaker) \(text)")
                case .liveClockAnswerReported(let report, let result, let id): grades.append((report, result, id))
                case .serverError: failed = true
                default: break
                }
            }
        }
        defer { observer.cancel(); audio.finish() }
        do {
            try await service.open(language: language, safetyIdentifier: .init(stableID: "managed-synthetic-test"))
            try await service.setChallenge(.init(questionID: 1, hour: 3, minute: 0, difficulty: "fullHour", language: language))
            try await service.startVoice(authorizedBy: service.authorizeCaptureStart())
            try await wait(25) { !coach.isEmpty || failed }
            XCTAssertFalse(failed)
            audio.say(try Data(contentsOf: URL(fileURLWithPath: speechPath)))
            try await wait(40) { !grades.isEmpty || failed }
            XCTAssertFalse(failed)
            XCTAssertEqual(grades.first?.0, .init(hour: 3, minute: 0, unknown: false))
            XCTAssertEqual(grades.first?.1.correct, true)
            XCTAssertEqual(grades.first?.2, 1)
            try await Task.sleep(for: .seconds(6))
            try await service.setChallenge(.init(questionID: 2, hour: 4, minute: 0, difficulty: "fullHour", language: language))
            try await Task.sleep(for: .seconds(4))
            audio.say(try Data(contentsOf: URL(fileURLWithPath: speechPath)))
            try await wait(40) { grades.contains { $0.2 == 2 } || failed }
            XCTAssertFalse(failed)
            XCTAssertEqual(grades.first { $0.2 == 2 }?.1.correct, false)
            XCTAssertGreaterThan(audio.nonSilentOutputFrames, 4800)
            print("MANAGED_SYNTHETIC language=\(language.rawValue) child=\(child) coach=\(coach) grades=\(grades.count) audio_frames=\(audio.nonSilentOutputFrames)")
            await service.disconnect()
            var request = URLRequest(url: baseURL.appendingPathComponent("v1/account"))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let account = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(account?["active"] as? Bool, false, "Provider close must settle the active reservation")
        } catch {
            print("MANAGED_SYNTHETIC_DIAGNOSTIC language=\(language.rawValue) child=\(child) coach=\(coach) failed=\(failed)")
            await service.disconnect()
            throw error
        }
    }
    private func wait(_ seconds: Int, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(Double(seconds))
        while !condition() {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

private final class SyntheticWebRTCAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    let deviceInputSampleRate = 48000.0, deviceOutputSampleRate = 48000.0
    let inputIOBufferDuration = 0.01, outputIOBufferDuration = 0.01
    let inputNumberOfChannels = 1, outputNumberOfChannels = 1
    let inputLatency = 0.0, outputLatency = 0.0
    var isInitialized = false, isPlayoutInitialized = false, isRecordingInitialized = false
    var isPlaying = false, isRecording = false
    private var deviceDelegate: RTCAudioDeviceDelegate?
    private let lock = NSLock()
    private var pending = Data()
    private var outputFrames = 0
    private var thread: Thread?
    private var ended = false
    var nonSilentOutputFrames: Int { lock.withLock { outputFrames } }
    func say(_ data: Data) { lock.withLock { pending = data } }
    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        deviceDelegate = delegate; isInitialized = true
        let thread = Thread { [weak self] in self?.pump() }; self.thread = thread
        thread.qualityOfService = .userInteractive
        thread.start(); return true
    }
    func terminateDevice() -> Bool { finish(); deviceDelegate = nil; isInitialized = false; return true }
    func initializePlayout() -> Bool { isPlayoutInitialized = true; return true }
    func initializeRecording() -> Bool { isRecordingInitialized = true; return true }
    func startPlayout() -> Bool { lock.withLock { isPlaying = true }; return true }
    func stopPlayout() -> Bool { lock.withLock { isPlaying = false }; return true }
    func startRecording() -> Bool { lock.withLock { isRecording = true }; return true }
    func stopRecording() -> Bool { lock.withLock { isRecording = false }; return true }
    func finish() { lock.withLock { ended = true } }
    private func pump() {
        var sampleTime = 0.0
        var nextTick = ProcessInfo.processInfo.systemUptime
        let samples = UnsafeMutablePointer<Int16>.allocate(capacity: 480)
        defer { samples.deallocate() }
        while true {
            let state = lock.withLock { (ended, isPlaying, isRecording) }
            if state.0 { return }
            if let delegate = deviceDelegate {
                var timestamp = AudioTimeStamp(); timestamp.mSampleTime = sampleTime; timestamp.mFlags = .sampleTimeValid
                var flags = AudioUnitRenderActionFlags()
                var buffer = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 960, mData: samples))
                if state.1 {
                    samples.update(repeating: 0, count: 480)
                    _ = delegate.getPlayoutData(&flags, &timestamp, 0, 480, &buffer)
                    if UnsafeBufferPointer(start: samples, count: 480).contains(where: { abs(Int($0)) > 50 }) { lock.withLock { outputFrames += 480 } }
                }
                if state.2 {
                    let bytes = lock.withLock { let chunk = Data(pending.prefix(960)); pending.removeFirst(min(960,pending.count)); return chunk }
                    samples.update(repeating: 0, count: 480)
                    bytes.copyBytes(to: UnsafeMutableRawBufferPointer(start: samples, count: bytes.count))
                    _ = delegate.deliverRecordedData(&flags, &timestamp, 0, 480, &buffer, nil, nil)
                }
            }
            sampleTime += 480
            nextTick += 0.01
            Thread.sleep(forTimeInterval: max(0, nextTick - ProcessInfo.processInfo.systemUptime))
        }
    }
}
