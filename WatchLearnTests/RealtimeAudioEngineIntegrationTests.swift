import XCTest
@preconcurrency import AVFoundation
@testable import WatchLearn

final class RealtimeAudioEngineIntegrationTests: XCTestCase {
    @MainActor
    func testRealtimeAudioEngineDefersHardwareSetupUntilAuthorizedStart() {
        let engine = RealtimeAudioEngine()
        defer { engine.stopAll() }

        XCTAssertFalse(engine.isVoiceProcessingEnabled)
    }

    func testPlaybackBudgetRejectsMalformedAndOversizedDeltas() throws {
        var budget = RealtimePlaybackQueueBudget()

        XCTAssertThrowsError(try budget.reservePCM16(byteCount: 0))
        XCTAssertThrowsError(try budget.reservePCM16(byteCount: 3))
        XCTAssertThrowsError(
            try budget.reservePCM16(
                byteCount: RealtimePlaybackQueueBudget.maximumDeltaBytes + 2
            )
        )
        XCTAssertEqual(budget.queuedFrames, 0)
    }

    func testPlaybackBudgetCapsQueueAndReleasesCompletedFrames() throws {
        var budget = RealtimePlaybackQueueBudget()
        let framesPerDelta = try budget.reservePCM16(
            byteCount: RealtimePlaybackQueueBudget.maximumDeltaBytes
        )
        XCTAssertEqual(framesPerDelta, RealtimeConstants.sampleRate * 4)

        for _ in 1..<5 {
            _ = try budget.reservePCM16(
                byteCount: RealtimePlaybackQueueBudget.maximumDeltaBytes
            )
        }
        XCTAssertEqual(
            budget.queuedFrames,
            RealtimePlaybackQueueBudget.maximumQueuedFrames
        )
        XCTAssertThrowsError(try budget.reservePCM16(byteCount: 2))

        budget.release(frames: framesPerDelta)
        XCTAssertEqual(
            try budget.reservePCM16(
                byteCount: RealtimePlaybackQueueBudget.maximumDeltaBytes
            ),
            framesPerDelta
        )

        budget.reset()
        XCTAssertEqual(budget.queuedFrames, 0)
    }

    func testPlaybackDrainStateInvalidatesStaleCompletionGeneration() {
        var state = RealtimePlaybackDrainState()
        var playbackGeneration: UInt64 = 7
        let token = state.scheduleBuffer(
            responseID: "resp_stale_generation",
            generation: playbackGeneration
        )
        XCTAssertFalse(state.markResponseAudioFinished(
            responseID: "resp_stale_generation",
            generation: playbackGeneration
        ))

        playbackGeneration &+= 1
        state.reset()

        XCTAssertEqual(
            state.completeBuffer(
                token,
                currentGeneration: playbackGeneration
            ),
            .stale
        )
    }

    @MainActor
    func testCaptureTapCallbackRunsOffMainExecutor() async throws {
        let sourceFormat = try XCTUnwrap(
            AVAudioFormat(
                standardFormatWithSampleRate: 48_000,
                channels: 1
            )
        )
        let targetFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(RealtimeConstants.sampleRate),
                channels: AVAudioChannelCount(RealtimeConstants.channels),
                interleaved: false
            )
        )
        let converter = try XCTUnwrap(
            AVAudioConverter(from: sourceFormat, to: targetFormat)
        )
        let inputBuffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: 480
            )
        )
        inputBuffer.frameLength = 480

        let callbackExpectation = expectation(
            description: "capture tap callback executes off the main executor"
        )
        let probe = CaptureTapCallbackProbe(expectation: callbackExpectation)
        let tap = RealtimeAudioEngine.makeCaptureTap(
            converter: converter,
            targetFormat: targetFormat,
            failureGate: CaptureFailureGate(),
            onPCM16Chunk: { _ in probe.recordCallback() },
            onCaptureFailure: { _ in probe.recordCallback() }
        )
        let invocation = CaptureTapInvocation(
            tap: tap,
            buffer: inputBuffer,
            time: AVAudioTime(sampleTime: 0, atRate: sourceFormat.sampleRate)
        )

        DispatchQueue(label: "RealtimeAudioEngineTests.capture-tap").async {
            invocation.invoke()
        }

        await fulfillment(of: [callbackExpectation], timeout: 2)
        XCTAssertEqual(probe.callbackWasOnMainThread, false)
    }

    @MainActor
    func testPlaybackCompletionHopsToMainActorFromNonMainQueue() async {
        let callbackExpectation = expectation(
            description: "playback completion reaches MainActor"
        )
        let completion = RealtimeAudioEngine.makePlaybackCompletionHandler {
            XCTAssertTrue(Thread.isMainThread)
            callbackExpectation.fulfill()
        }
        let invocation = PlaybackCompletionInvocation(completion: completion)

        DispatchQueue(label: "RealtimeAudioEngineTests.playback-completion").async {
            invocation.invoke()
        }

        await fulfillment(of: [callbackExpectation], timeout: 2)
    }

    @MainActor
    func testInterruptionNotificationHopsToMainActorFromNonMainQueue() async {
        let engine = RealtimeAudioEngine()
        defer { engine.stopAll() }

        let callbackExpectation = expectation(
            description: "interruption handler reaches MainActor"
        )
        let probe = CaptureTapCallbackProbe(expectation: callbackExpectation)
        engine.setInterruptionHandler { interrupted in
            guard interrupted else { return }
            probe.recordCallback()
        }
        let notification = Notification(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
            ]
        )
        let invocation = NotificationPostInvocation(notification: notification)

        DispatchQueue(label: "RealtimeAudioEngineTests.interruption-notification").async {
            invocation.invoke()
        }

        await fulfillment(of: [callbackExpectation], timeout: 2)
        XCTAssertEqual(probe.callbackWasOnMainThread, true)
    }

    @MainActor
    func testSimulatorAudioSessionCaptureStartsAndStops() async throws {
        guard ProcessInfo.processInfo.environment["WATCHLEARN_RUN_AUDIO_ENGINE_SMOKE"] == "1" else {
            throw XCTSkip(
                "Set WATCHLEARN_RUN_AUDIO_ENGINE_SMOKE=1 and grant Simulator microphone access to run the audio-route smoke."
            )
        }

        let engine = RealtimeAudioEngine()
        let captured = LiveAudioChunkCounter()
        defer { engine.stopAll() }

        try await engine.startCapture(
            authorizedBy: engine.authorizeCaptureStart(),
            onPCM16Chunk: { data in captured.add(data.count) },
            onCaptureFailure: { _ in }
        )
        XCTAssertTrue(engine.isVoiceProcessingEnabled)
        try await Task.sleep(for: .seconds(2))
        engine.stopAll()
        XCTAssertGreaterThan(captured.byteCount, 0, "The real microphone route must deliver PCM, not just start an engine.")
    }
}

private final class CaptureTapInvocation: @unchecked Sendable {
    private let tap: AVAudioNodeTapBlock
    private let buffer: AVAudioPCMBuffer
    private let time: AVAudioTime

    init(
        tap: @escaping AVAudioNodeTapBlock,
        buffer: AVAudioPCMBuffer,
        time: AVAudioTime
    ) {
        self.tap = tap
        self.buffer = buffer
        self.time = time
    }

    func invoke() {
        tap(buffer, time)
    }
}

private final class PlaybackCompletionInvocation: @unchecked Sendable {
    private let completion: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void

    init(
        completion: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
    ) {
        self.completion = completion
    }

    func invoke() {
        completion(.dataPlayedBack)
    }
}

private final class NotificationPostInvocation: @unchecked Sendable {
    private let notification: Notification

    init(notification: Notification) {
        self.notification = notification
    }

    func invoke() {
        NotificationCenter.default.post(notification)
    }
}

private final class CaptureTapCallbackProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let expectation: XCTestExpectation
    private var didRecordCallback = false
    private var recordedMainThreadValue: Bool?

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    var callbackWasOnMainThread: Bool? {
        lock.withLock { recordedMainThreadValue }
    }

    func recordCallback() {
        let shouldFulfill = lock.withLock {
            guard !didRecordCallback else { return false }
            didRecordCallback = true
            recordedMainThreadValue = Thread.isMainThread
            return true
        }
        if shouldFulfill {
            expectation.fulfill()
        }
    }
}

private final class LiveAudioChunkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var byteCount: Int { lock.withLock { count } }
    func add(_ bytes: Int) { lock.withLock { count += bytes } }
}
