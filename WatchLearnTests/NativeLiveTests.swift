import Foundation
import XCTest
@preconcurrency import WebRTC
@testable import WatchLearn

@MainActor
final class NativeLiveTests: XCTestCase {
    func testGreetingIsLocalizedAndFirstClockWithoutHistoryStillWaitsForAudio() throws {
        for language in [RealtimeCoachLanguage.german, .english] {
            let context = ClockChallengeContext(questionID: 1, hour: 3, minute: 0, difficulty: "fullHour", language: language)
            let first = LiveClockCoachPrompt.challengeInstructions(context, firstInSession: true)
            XCTAssertTrue(first.contains("VOICE_READY"))
            XCTAssertFalse(first.contains("previous exercise is over"))
            let next = LiveClockCoachPrompt.challengeInstructions(context, firstInSession: false)
            XCTAssertFalse(next.contains("VOICE_READY"))
            let opening = LiveClockCoachPrompt.voiceReady(language: language)
            XCTAssertTrue(opening.contains(language == .german ? "ich bin dein Zeitheld" : "I'm your Time Hero"))
            XCTAssertTrue(opening.contains("Speak first now"))
            XCTAssertFalse(opening.contains("3:00"))
        }
    }

    func testUnownedWebRTCCallbacksCannotConnectOrDisconnectTheService() async throws {
        let factory = RTCPeerConnectionFactory()
        let service = ManagedLiveSession(baseURL: URL(string: "https://service.invalid")!, token: "fixture", factory: factory)
        let foreignPeer = try XCTUnwrap(factory.peerConnection(with: RTCConfiguration(),
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil))
        let foreignChannel = try XCTUnwrap(foreignPeer.dataChannel(forLabel: "stale", configuration: RTCDataChannelConfiguration()))
        defer { foreignChannel.close(); foreignPeer.close() }
        var received = [RealtimeServiceEvent]()
        let observer = Task { @MainActor in
            for await event in service.events { received.append(event) }
        }
        defer { observer.cancel() }
        service.dataChannel(foreignChannel, didReceiveMessageWith: RTCDataBuffer(
            data: Data(#"{"type":"session.started"}"#.utf8), isBinary: false))
        service.peerConnection(foreignPeer, didChange: RTCIceConnectionState.failed)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(received.isEmpty, "Late callbacks from an unowned transport must not change the session or emit connection events.")
    }

    func testFirstConversationAndReturningGuidanceNeverRestartOnEveryClock() {
        let first = ClockChallengeContext(questionID: 7, hour: 3, minute: 0, difficulty: "fullHour", language: .german,
                                          learner: .init(needsIntroduction: true, totalAttempts: 0, recentAttempts: 0, recentCorrect: 0))
        let introduction = LiveClockCoachPrompt.challengeInstructions(first, firstInSession: true)
        XCTAssertTrue(introduction.contains("FIRST_CONVERSATION"))
        XCTAssertTrue(introduction.contains("do not grade or delegate them"))
        XCTAssertTrue(introduction.contains("not ask both questions at once"))
        let next = LiveClockCoachPrompt.challengeInstructions(first, firstInSession: false)
        XCTAssertFalse(next.contains("FIRST_CONVERSATION"))
        XCTAssertTrue(next.contains("question_id=7"))
        let returning = ClockChallengeContext(questionID: 8, hour: 4, minute: 0, difficulty: "fullHour", language: .english,
                                              learner: .init(needsIntroduction: false, totalAttempts: 10, recentAttempts: 5, recentCorrect: 2))
        let context = LiveClockCoachPrompt.challengeInstructions(returning, firstInSession: true)
        XCTAssertTrue(context.contains("RETURNING_LEARNER"))
        XCTAssertTrue(context.contains("recent correct=2 of 5"))
        XCTAssertFalse(context.contains("FIRST_CONVERSATION"))
    }

    private let fixtureKey = "sk-fixture-native-offline-only"

    func testNativeWireFormatNeverConfiguresRealtimeTurns() throws {
        let message = try LiveEventCodec.sessionStart(language: .german)
        let event = try object(message)
        let session = try XCTUnwrap(event["session"] as? [String: Any])
        XCTAssertNil(session["turn_detection"])
        XCTAssertNil(session["tools"])
        XCTAssertNil(session["type"])
        XCTAssertFalse(message.contains("wait_for_user"))
        XCTAssertTrue(message.contains("report_clock_answer"))
        XCTAssertEqual(event["type"] as? String, "session.start")
        XCTAssertEqual(session["model"] as? String, "gpt-live-1")
        XCTAssertTrue(message.contains("simple German"))
        XCTAssertTrue(try LiveEventCodec.sessionStart(language: .english).contains("simple English"))
        let audio = try object(LiveEventCodec.appendAudio(Data([0, 0])))
        XCTAssertEqual(audio["type"] as? String, "session.input_audio.append")
        XCTAssertThrowsError(try LiveEventCodec.appendAudio(Data([0])))
        XCTAssertThrowsError(try LiveEventCodec.appendAudio(Data()))
    }

    func testContextByteLimitPreservesGermanAndEmoji() throws {
        let original = String(repeating: "Über die Uhr 🕰️! ", count: 100)
        let messages = try LiveEventCodec.context(original, delegationID: "grade-1")
        var restored = ""
        for message in messages {
            let event = try object(message)
            XCTAssertEqual(event["type"] as? String, "session.commentary.append")
            XCTAssertEqual(event["delegation_id"] as? String, "grade-1")
            let text = try XCTUnwrap(event["content"] as? String)
            XCTAssertLessThanOrEqual(text.utf8.count, 500)
            restored += text
        }
        XCTAssertEqual(restored, original)
    }

    func testDecoderSeparatesLiveFromRealtimeAndRejectsBadAudio() throws {
        XCTAssertEqual(try LiveEventCodec.decode(.text(#"{"type":"response.output_audio.delta","delta":"AAA="}"#)), .ignored)
        XCTAssertEqual(try LiveEventCodec.decode(.text(#"{"type":"session.output_audio.delta","delta":"AAA="}"#)), .audio(Data([0, 0])))
        XCTAssertThrowsError(try LiveEventCodec.decode(.text(#"{"type":"session.output_audio.delta","delta":"AA=="}"#)))
        XCTAssertThrowsError(try LiveEventCodec.decode(.text(String(repeating: "x", count: RealtimeConstants.maxServerEventBytes + 1))))
        XCTAssertEqual(try LiveEventCodec.decode(.text(#"{"type":"session.input_transcript.delta","delta":"drei Uhr"}"#)), .transcript(.child, "drei Uhr"))
        XCTAssertEqual(try LiveEventCodec.decode(.text(#"{"type":"turn.done","turn":{"role":"assistant","transcript":"Gut!"}}"#)), .ignored)
    }

    func testSilenceDoesNotMarkCoachAsSpeaking() {
        XCTAssertFalse(LiveAudioActivity.hasAudibleSamples(Data(repeating: 0, count: 4800)))
        XCTAssertFalse(LiveAudioActivity.hasAudibleSamples(Data([20, 0, 10, 0])))
        XCTAssertTrue(LiveAudioActivity.hasAudibleSamples(Data([0, 32, 0, 0])))
    }

    func testProviderErrorCannotExposeKeyOrChildWords() throws {
        let decoded = try LiveEventCodec.decode(.text(#"{"type":"error","error":{"code":"forbidden","message":"sk-private child words"}}"#))
        guard case .error(let error) = decoded else { return XCTFail("Expected error") }
        XCTAssertEqual(error.code, "forbidden")
        XCTAssertFalse(error.message.contains("sk-private"))
        XCTAssertFalse(error.message.contains("child words"))
        XCTAssertEqual(VoiceCoachFailure(error: LiveServiceError.accessDenied).code, .liveAccessDenied)
        XCTAssertTrue(VoiceCoachFailure(error: LiveServiceError.accessDenied).localizedMessage(language: .english).contains("GPT-Live"))
    }

    func testAccessDeniedFailsBeforeMicrophoneAndDoesNotFallback() async throws {
        let transport = NativeFixtureTransport([#"{"type":"error","error":{"code":"forbidden","message":"Voice session access denied."}}"#])
        let audio = NativeFixtureAudio()
        let service = OpenAILiveService(apiKey: fixtureKey, transport: transport, audioCapture: audio)
        do { try await service.open(language: .german, safetyIdentifier: .init(stableID: "test")); XCTFail("Expected denial") }
        catch { XCTAssertEqual(error as? LiveServiceError, .accessDenied) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/v1/live/sessions")
        XCTAssertNil(requests.first?.url?.query)
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "OpenAI-Alpha"))
        XCTAssertEqual(audio.starts, 0)
        let types = try await sentTypes(transport)
        XCTAssertEqual(types, ["session.start"])
        let disconnected = await transport.disconnected
        XCTAssertTrue(disconnected)
    }

    func testUpdatedIsNotProofOfSessionStartedAndTimeoutClosesSocket() async throws {
        let transport = NativeFixtureTransport([#"{"type":"session.updated"}"#])
        let service = OpenAILiveService(apiKey: fixtureKey, transport: transport, handshakeTimeout: .milliseconds(40))
        do { try await service.open(language: .english, safetyIdentifier: .init(stableID: "test")); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? LiveServiceError, .handshakeTimeout) }
        try await eventually { await transport.disconnected }
    }

    func testCancelDuringHandshakeNeverStartsCapture() async throws {
        let transport = NativeFixtureTransport([])
        let audio = NativeFixtureAudio()
        let service = OpenAILiveService(apiKey: fixtureKey, transport: transport, audioCapture: audio)
        let opening = Task { try await service.open(language: .german, safetyIdentifier: .init(stableID: "cancel")) }
        try await eventually { await transport.sent.count == 1 }
        opening.cancel()
        do { try await opening.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        try await eventually { await transport.disconnected }
        XCTAssertEqual(audio.starts, 0)
    }

    func testAudioFlowsBothWaysWhileDelegationWaitsAndStaleGradeIsDiscarded() async throws {
        let transport = NativeFixtureTransport([#"{"type":"session.started"}"#])
        let audio = NativeFixtureAudio()
        let grader = NativeSuspendedGrader()
        let service = OpenAILiveService(apiKey: fixtureKey, transport: transport, audioCapture: audio, audioPlayback: audio, answerHandler: grader)
        var reports: [ClockAnswerReport] = []
        let observer = Task { for await event in service.events { if case .liveClockAnswerReported(let report, _, _) = event { reports.append(report) } } }
        defer { observer.cancel() }
        try await service.open(language: .german, safetyIdentifier: .init(stableID: "duplex"))
        try await service.setChallenge(challenge(1, hour: 3))
        let beforeCapture = try await transport.sent.map { try object($0) }
        XCTAssertTrue(beforeCapture.contains {
            ($0["content"] as? String)?.contains("Current question_id=1, target hour=3, minute=0") == true
        }, "The displayed time must be supplied before listening to the first answer")
        XCTAssertFalse(beforeCapture.contains { ($0["content"] as? String)?.hasPrefix("VOICE_READY:") == true })
        try await service.startVoice(authorizedBy: audio.authorizeCaptureStart())
        try await enqueueAnswer(transport, id: "d1", questionID: 1)

        try await eventually { await grader.waiting }
        await transport.enqueue(#"{"type":"session.output_audio.delta","delta":"AAA="}"#)
        try await eventually { audio.played.count == 1 }
        audio.emit(Data([1, 0, 2, 0]))
        try await eventually { try await self.sentTypes(transport).contains("session.input_audio.append") }
        XCTAssertEqual(audio.starts, 1)
        XCTAssertEqual(audio.stops, 0)
        try await service.setChallenge(challenge(2, hour: 4))
        let afterNewClock = try await transport.sent.map { try object($0) }
        XCTAssertTrue(afterNewClock.contains {
            ($0["content"] as? String)?.contains("Current question_id=2, target hour=4, minute=0") == true
        }, "The next clock context is supplied on the same connection")
        XCTAssertEqual(audio.starts, 1)
        XCTAssertEqual(audio.stops, 0)
        XCTAssertEqual(afterNewClock.filter { ($0["content"] as? String)?.hasPrefix("VOICE_READY:") == true }.count, 1,
                       "Audio-ready greeting is sent once, after capture starts, not for every clock.")
        await grader.finish()
        try await eventually { try await self.sentTypes(transport).contains("response.item.create") }
        XCTAssertTrue(reports.isEmpty, "A grade for the old question must not reach the current clock")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1, "Clock changes reuse the same continuous session")
        let messages = await transport.sent.joined()
        XCTAssertTrue(messages.contains("response.create"), "Only delegated backend continuation uses this command")
        XCTAssertFalse(messages.contains("input_audio_buffer.commit"))
        XCTAssertFalse(messages.contains("response.cancel"))
        XCTAssertTrue(messages.contains("displayed clock changed"))
        await service.disconnect()
        XCTAssertEqual(audio.stops, 1)
        XCTAssertEqual(audio.playbackStops, 1)
    }

    func testValidDelegationGradesOnceAndNeverTreatsTranscriptAsAudioCompletion() async throws {
        let transport = NativeFixtureTransport([#"{"type":"session.started"}"#])
        let service = OpenAILiveService(apiKey: fixtureKey, transport: transport)
        var grades: [ClockAnswerToolResult] = []
        var advances = 0
        var failures = 0
        let observer = Task {
            for await event in service.events {
                if case .liveClockAnswerReported(_, let result, _) = event { grades.append(result) }
                if case .spokenCorrectAnswerFeedbackFinished = event { advances += 1 }
                if case .liveAdvanceRequested = event { advances += 1 }
                if case .serverError = event { failures += 1 }
            }
        }
        defer { observer.cancel() }
        try await service.open(language: .english, safetyIdentifier: .init(stableID: "grade"))
        try await service.setChallenge(challenge(7, hour: 3))
        try await enqueueAnswer(transport, id: "d7", questionID: 7)
        try await enqueueAnswer(transport, id: "d7", questionID: 7)
        try await eventually { grades.count == 1 }
        await transport.enqueue(#"{"type":"turn.done","turn":{"role":"assistant","transcript":"Great!"}}"#)
        await service.disconnect()
        XCTAssertEqual(grades.first?.correct, true)
        XCTAssertEqual(advances, 0)
        XCTAssertEqual(failures, 0)
        let count = try await sentTypes(transport).filter { $0 == "response.item.create" }.count
        XCTAssertEqual(count, 1)
    }

    func testLiveAdvanceWaitsForAudibleFeedbackAndQuietThenFiresOnlyOnce() {
        var gate = LiveExerciseAdvanceGate()
        XCTAssertNil(gate.takeReadyQuestion(at: 100))
        gate.arm(questionID: 7, at: 100)
        XCTAssertNil(gate.takeReadyQuestion(at: 120), "No audio means manual Next remains available")
        gate.observeAudibleOutput(at: 121)
        XCTAssertNil(gate.takeReadyQuestion(at: 122))
        gate.observeAudibleOutput(at: 122)
        XCTAssertNil(gate.takeReadyQuestion(at: 123))
        XCTAssertEqual(gate.takeReadyQuestion(at: 123.6), 7)
        XCTAssertNil(gate.takeReadyQuestion(at: 130))
        gate.arm(questionID: 8, at: 140)
        gate.observeAudibleOutput(at: 140.1)
        XCTAssertNil(gate.takeReadyQuestion(at: 142), "Keep feedback on screen at least three seconds")
        gate.cancel()
        XCTAssertNil(gate.takeReadyQuestion(at: 145), "Stop/new clock cancels pending progress")
    }

    func testWebRTCAudioActivityRejectsMissingProgressAndCounterResets() {
        var activity = LiveInboundAudioActivity()
        XCTAssertNil(activity.observe(energy: 0, duration: 0))
        XCTAssertEqual(activity.observe(energy: 0.001, duration: 1), true)
        XCTAssertNil(activity.observe(energy: 0.001, duration: 1))
        XCTAssertEqual(activity.observe(energy: 0.001, duration: 2), false)
        XCTAssertNil(activity.observe(energy: 0, duration: 0))
        XCTAssertNil(activity.observe(energy: .nan, duration: 1))
    }

    func testLiveAudibleFeedbackAdvancesTheGradedClockWithoutAnotherTap() async throws {
        let transport = NativeFixtureTransport([#"{"type":"session.started"}"#])
        let audio = NativeFixtureAudio()
        let service = OpenAILiveService(apiKey: fixtureKey, transport: transport, audioPlayback: audio)
        var graded = false
        var advances: [Int] = []
        let observer = Task {
            for await event in service.events {
                if case .liveClockAnswerReported(_, let result, _) = event { graded = result.correct == true }
                if case .liveAdvanceRequested(let id) = event { advances.append(id) }
            }
        }
        defer { observer.cancel() }
        try await service.open(language: .english, safetyIdentifier: .init(stableID: "auto-next-test"))
        try await service.setChallenge(challenge(7, hour: 3))
        try await enqueueAnswer(transport, id: "correct", questionID: 7)
        try await eventually { graded }
        let audible = Data([0xff, 0x3f, 0xff, 0x3f]).base64EncodedString()
        await transport.enqueue("{\"type\":\"session.output_audio.delta\",\"delta\":\"\(audible)\"}")
        try await eventually { audio.played.count == 1 }
        try await Task.sleep(for: .seconds(3.5))
        XCTAssertEqual(advances, [7])
        await service.disconnect()
    }

    func testNativeDenialReachesCoordinatorAsLiveErrorWithoutCapture() async throws {
        let transport = NativeFixtureTransport([#"{"type":"error","error":{"code":"forbidden","message":"private provider detail"}}"#])
        let audio = NativeFixtureAudio()
        let coordinator = VoiceCoachCoordinator(microphonePermission: NativeGrantedPermission(), sessionFactory: { _ in
            VoiceCoachSessionResources(service: OpenAILiveService(apiKey: "sk-fixture-native-coordinator", transport: transport, audioCapture: audio, audioPlayback: audio), audioEngine: audio)
        })
        let domain = "NativeCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = ParentPreferences(secureStore: NativeEmptySecureStore(), defaults: defaults)
        preferences.hasCloudVoiceConsent = true
        preferences.cloudVoiceMode = .managedBroker
        preferences.brokerURLText = "https://fixture.invalid/token"
        await coordinator.start(question: .init(id: 7, time: .init(hour: 3, minute: 0), level: .fullHour, choices: [.init(hour: 3, minute: 0)], heroTheme: .skyGuardian), preferences: preferences)
        guard case .failed(let message) = coordinator.phase else { return XCTFail("Expected native access error") }
        XCTAssertTrue(message.contains("VC-LIVE-ACCESS"))
        XCTAssertFalse(message.contains("private provider detail"))
        XCTAssertFalse(coordinator.isSessionActive)
        XCTAssertEqual(audio.starts, 0)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/v1/live/sessions")
    }

    func testNativeGradeReachesLessonAndStopRevokesAudioImmediately() async throws {
        let transport = NativeFixtureTransport([#"{"type":"session.started"}"#])
        let audio = NativeFixtureAudio()
        let service = OpenAILiveService(apiKey: fixtureKey, transport: transport, audioCapture: audio, audioPlayback: audio)
        let coordinator = VoiceCoachCoordinator(microphonePermission: NativeGrantedPermission(), sessionFactory: { _ in
            VoiceCoachSessionResources(service: service, audioEngine: audio)
        })
        let domain = "NativeLesson.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = ParentPreferences(secureStore: NativeEmptySecureStore(), defaults: defaults)
        preferences.hasCloudVoiceConsent = true
        preferences.cloudVoiceMode = .managedBroker
        preferences.brokerURLText = "https://fixture.invalid/token"
        let lesson = LearningViewModel(language: .english)
        coordinator.onLiveClockAnswer = { report, id in
            guard id == lesson.question.id, !report.unknown, let hour = report.hour, let minute = report.minute else { return }
            lesson.chooseSpoken(.init(hour: hour, minute: minute))
        }
        await coordinator.start(question: lesson.question, preferences: preferences)
        XCTAssertTrue(coordinator.isSessionActive)
        try await enqueueAnswer(transport, id: "lesson", questionID: lesson.question.id, hour: lesson.question.time.hour)
        try await eventually { lesson.canContinue }
        XCTAssertNotNil(lesson.evaluation?.reward)
        // Late captions must not leave a silent coach labelled as speaking.
        await transport.enqueue(#"{"type":"session.output_transcript.delta","delta":"Well done!"}"#)
        try await eventually { !coordinator.coachTranscript.isEmpty }
        XCTAssertEqual(coordinator.phase, .listening)
        let capturedBeforeStop = await transport.sent.count
        coordinator.stopLocalAudioImmediately()
        XCTAssertGreaterThan(audio.stops, 0)
        audio.emit(Data([1, 0]))
        await coordinator.stop()
        XCTAssertFalse(coordinator.isSessionActive)
        XCTAssertEqual(coordinator.coachTranscript, "")
        XCTAssertEqual(coordinator.phase, .idle)
        let later = Array(await transport.sent.dropFirst(capturedBeforeStop))
        XCTAssertFalse(later.contains(where: { $0.contains("session.input_audio.append") }))
        let usage = await service.finalUsageSeconds
        XCTAssertEqual(usage, 1)
    }

    func testInvalidAnswerCannotBeSilentlyNormalizedIntoCorrectGrade() throws {
        for text in [#"{"question_id":1,"hour":27,"minute":0,"unknown":false}"#,
                     #"{"question_id":1,"hour":3,"minute":60,"unknown":false}"#,
                     #"{"question_id":1,"hour":3,"minute":null,"unknown":false}"#] {
            XCTAssertNil(try JSONDecoder().decode(LiveClockAnswerDelegation.self, from: Data(text.utf8)).report)
        }
    }

    private func enqueueAnswer(_ transport: NativeFixtureTransport, id: String, questionID: Int, hour: Int = 3) async throws {
        let args = try LiveEventCodec.encode(["question_id": questionID, "hour": hour, "minute": 0, "unknown": false])
        let events: [[String: Any]] = [
            ["type": "response.created", "response": ["id": id]],
            ["type": "response.output_item.done", "item": ["type": "function_call", "name": "report_clock_answer", "call_id": "call-" + id, "arguments": args]],
            ["type": "response.completed", "response": ["id": id, "output": []]]
        ]
        for event in events { await transport.enqueue(try LiveEventCodec.encode(["type": "response.event", "delegation_id": "delegation-" + id, "event": event])) }
    }

    private func challenge(_ id: Int, hour: Int) -> ClockChallengeContext {
        .init(questionID: id, hour: hour, minute: 0, difficulty: "fullHour", language: .german)
    }
    private func object(_ text: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) }
    private func sentTypes(_ transport: NativeFixtureTransport) async throws -> [String] { try await transport.sent.map { try object($0)["type"] as? String ?? "" } }
    private func eventually(_ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while try await !condition() {
            if ContinuousClock.now >= deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor NativeFixtureTransport: RealtimeWebSocketTransporting {
    var requests: [URLRequest] = []
    var sent: [String] = []
    var disconnected = false
    private var queue: [String]
    private var waiter: CheckedContinuation<RealtimeWebSocketMessage, any Error>?
    init(_ messages: [String]) { queue = messages }
    func connect(request: URLRequest) { requests.append(request); disconnected = false }
    func send(text: String) throws {
        guard !disconnected else { throw CancellationError() }; sent.append(text)
        if text.contains("session.close") { enqueue(#"{"type":"session.closed","usage":{"seconds":1}}"#) }
    }
    func receive() async throws -> RealtimeWebSocketMessage {
        if !queue.isEmpty { return .text(queue.removeFirst()) }
        guard !disconnected else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func enqueue(_ text: String) { if let pending = waiter { waiter = nil; pending.resume(returning: .text(text)) } else { queue.append(text) } }
    func disconnect() { disconnected = true; waiter?.resume(throwing: CancellationError()); waiter = nil }
}

@MainActor
private final class NativeFixtureAudio: VoiceCoachAudioManaging {
    func setInterruptionHandler(_ handler: (@Sendable (Bool) -> Void)?) {}
    func stopAll() { stopCapture(); stopPlayback() }
    var starts = 0; var stops = 0; var playbackStops = 0
    var played: [Data] = []
    private let authorization = RealtimeAudioCaptureAuthorizationState()
    private var onChunk: (@Sendable (Data) -> Void)?
    func authorizeCaptureStart() -> RealtimeAudioCaptureAuthorization { authorization.issue() }
    func startCapture(authorizedBy token: RealtimeAudioCaptureAuthorization, onPCM16Chunk: @escaping @Sendable (Data) -> Void, onCaptureFailure: @escaping @Sendable (RealtimeAudioEngineError) -> Void) async throws {
        try authorization.validate(token); starts += 1; onChunk = onPCM16Chunk
    }
    func emit(_ data: Data) { onChunk?(data) }
    func stopCapture() { authorization.revoke(); stops += 1; onChunk = nil }
    func enqueuePCM16(_ data: Data, itemID: String?, responseID: String) { played.append(data) }
    func notifyWhenPlaybackDrained(responseID: String, onDrained: @escaping @Sendable (String) -> Void) { onDrained(responseID) }
    func stopPlayback() { playbackStops += 1 }
}

private actor NativeSuspendedGrader: ClockAnswerToolHandling {
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func handle(report: ClockAnswerReport, challenge: ClockChallengeContext?) async -> ClockAnswerToolResult {
        waiting = true
        await withCheckedContinuation { continuation = $0 }
        return .init(accepted: true, correct: true, expectedHour: 3, expectedMinute: 0)
    }
    func finish() { continuation?.resume(); continuation = nil }
}

private struct NativeGrantedPermission: MicrophonePermissionProviding {
    func currentPermission() -> MicrophonePermission { .granted }
    func requestPermission() async -> Bool { true }
}
private struct NativeEmptySecureStore: SecureStore {
    func data(for key: String) throws -> Data? { nil }
    func set(_ data: Data, for key: String) throws {}
    func removeValue(for key: String) throws {}
}
