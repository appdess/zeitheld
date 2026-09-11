import Foundation
import XCTest
@testable import WatchLearn

@MainActor
final class VoiceCoachCoordinatorSecurityTests: XCTestCase {
    func testManagedConnectionFailuresHaveSpecificSafeCodes() {
        let raw = Data(#"{"error":"session_already_active","message":"private child words"}"#.utf8)
        let failure = VoiceCoachFailure(error: ManagedAccountError.responseError(status: 409, data: raw))
        XCTAssertEqual(failure.code, .sessionAlreadyActive)
        XCTAssertFalse(failure.localizedMessage(language: .english).contains("private child words"))
        XCTAssertEqual(VoiceCoachFailure(error: ManagedAccountError.unavailable).code, .sessionSetup)
        XCTAssertEqual(VoiceCoachFailure(error: ManagedAccountError.trialExhausted).code, .trialExhausted)
    }

    func testTranscriptPolicyCapsEachDeltaAndAccumulatedTranscript() {
        let oversizedDelta = String(
            repeating: "x",
            count: VoiceCoachTranscriptPolicy.maximumDeltaScalars * 4
        )
        let first = VoiceCoachTranscriptPolicy.appending(
            oversizedDelta,
            to: ""
        )
        XCTAssertLessThanOrEqual(
            first.unicodeScalars.count,
            VoiceCoachTranscriptPolicy.maximumDeltaScalars
        )
        XCTAssertTrue(first.hasSuffix("…"))

        var accumulated = ""
        for _ in 0..<20 {
            accumulated = VoiceCoachTranscriptPolicy.appending(
                oversizedDelta,
                to: accumulated
            )
        }
        XCTAssertEqual(
            accumulated.unicodeScalars.count,
            VoiceCoachTranscriptPolicy.maximumTranscriptScalars
        )
        XCTAssertTrue(accumulated.hasSuffix("…"))
    }

    func testTranscriptPolicyCapsCompletedTranscriptWithoutBreakingUnicode() {
        let oversizedTranscript = String(
            repeating: "Zeitheld 🕰️ ",
            count: VoiceCoachTranscriptPolicy.maximumTranscriptScalars
        )

        let safeTranscript = VoiceCoachTranscriptPolicy.replacing(
            with: oversizedTranscript
        )

        XCTAssertLessThanOrEqual(
            safeTranscript.unicodeScalars.count,
            VoiceCoachTranscriptPolicy.maximumTranscriptScalars
        )
        XCTAssertTrue(safeTranscript.hasSuffix("…"))
        XCTAssertNotNil(safeTranscript.data(using: .utf8))
    }

    func testStartupDiagnosticIncludesSafeStageAndAllowListedErrorCode() {
        let providerError = RealtimeAPIError(
            type: "unsafe-type",
            code: "invalid_api_key",
            message: "secret request body and child transcript",
            parameter: "unsafe-parameter",
            eventID: "unsafe-event"
        )

        let message = VoiceCoachFailure(error: providerError).localizedMessage(
            language: .english,
            startupStage: .connection
        )

        XCTAssertTrue(message.contains("[VC-STAGE-CONNECTION]"))
        XCTAssertTrue(message.hasSuffix("[VC-TOKEN-401]"))
        XCTAssertFalse(message.contains("secret request body"))
        XCTAssertFalse(message.contains("child transcript"))
        XCTAssertFalse(message.contains("unsafe-event"))
    }

    func testTerminalSessionFailureClearsTransientTranscripts() async throws {
        let transport = VoiceSecurityTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_security"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_security"}}"#)
        ])
        let audio = VoiceSecurityAudio()
        let coordinator = VoiceCoachCoordinator(
            microphonePermission: VoiceSecurityMicrophonePermission(),
            sessionFactory: { _ in
                VoiceCoachSessionResources(
                    service: OpenAIRealtimeService(
                        tokenProvider: VoiceSecurityClientSecretProvider(),
                        transport: transport,
                        audioCapture: audio,
                        audioPlayback: audio
                    ),
                    audioEngine: audio
                )
            }
        )
        let defaultsName = "VoiceCoachSecurityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let preferences = ParentPreferences(defaults: defaults)
        preferences.cloudVoiceMode = .managedBroker
        preferences.brokerURLText = "https://voice-security.invalid/token"

        await coordinator.start(
            question: TimeQuestion(
                id: 911,
                time: ClockTime(hour: 4, minute: 0),
                level: .fullHour,
                choices: [ClockTime(hour: 4, minute: 0)],
                heroTheme: .skyGuardian
            ),
            preferences: preferences
        )
        XCTAssertTrue(coordinator.isSessionActive)

        await transport.enqueue(.text(
            #"{"type":"conversation.item.input_audio_transcription.delta","delta":"transient child words"}"#
        ))
        try await acknowledgeLatestResponseCreate(
            as: "resp_security",
            on: transport
        )
        await transport.enqueue(.text(
            #"{"type":"response.output_audio_transcript.delta","response_id":"resp_security","delta":"transient coach words"}"#
        ))
        try await waitUntil {
            !coordinator.childTranscript.isEmpty && !coordinator.coachTranscript.isEmpty
        }

        await transport.enqueue(.text(
            #"{"type":"error","error":{"type":"server_error","code":"terminal_fixture","message":"raw provider detail"}}"#
        ))
        try await waitUntil {
            if case .failed = coordinator.phase { return true }
            return false
        }

        XCTAssertEqual(coordinator.childTranscript, "")
        XCTAssertEqual(coordinator.coachTranscript, "")
        guard case let .failed(message) = coordinator.phase else {
            return XCTFail("Expected a terminal coach failure")
        }
        XCTAssertFalse(message.contains("raw provider detail"))
        await coordinator.stop()
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 where !predicate() {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard predicate() else { throw VoiceSecurityTestError.timedOut }
    }

    private func acknowledgeLatestResponseCreate(
        as responseID: String,
        on transport: VoiceSecurityTransport
    ) async throws {
        for _ in 0..<100 {
            for text in await transport.sentTexts().reversed() {
                guard let data = text.data(using: .utf8),
                      let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      event["type"] as? String == "response.create",
                      let response = event["response"] as? [String: Any],
                      let metadata = response["metadata"] as? [String: Any],
                      let requestID = metadata["watchlearn_request_id"] as? String else {
                    continue
                }
                let acknowledgement = try JSONSerialization.data(withJSONObject: [
                    "type": "response.created",
                    "response": [
                        "id": responseID,
                        "metadata": ["watchlearn_request_id": requestID]
                    ]
                ])
                let acknowledgementText = try XCTUnwrap(
                    String(data: acknowledgement, encoding: .utf8)
                )
                await transport.enqueue(.text(acknowledgementText))
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw VoiceSecurityTestError.timedOut
    }
}

private enum VoiceSecurityTestError: Error {
    case timedOut
    case disconnected
}

private struct VoiceSecurityClientSecretProvider: RealtimeClientSecretProviding {
    func clientSecret(
        options _: RealtimeSessionOptions,
        safetyIdentifier _: RealtimeSafetyIdentifier
    ) async throws -> RealtimeClientSecret {
        RealtimeClientSecret(
            value: "ek_voice_security_fixture",
            expiresAt: Date().addingTimeInterval(60)
        )
    }
}

private struct VoiceSecurityMicrophonePermission: MicrophonePermissionProviding {
    func currentPermission() -> MicrophonePermission { .granted }
    func requestPermission() async -> Bool { true }
}

@MainActor
private final class VoiceSecurityAudio: VoiceCoachAudioManaging {
    private let captureAuthorizationState = RealtimeAudioCaptureAuthorizationState()
    private var interruptionHandler: (@Sendable (Bool) -> Void)?

    func setInterruptionHandler(_ handler: (@Sendable (Bool) -> Void)?) {
        interruptionHandler = handler
    }

    func authorizeCaptureStart() -> RealtimeAudioCaptureAuthorization {
        captureAuthorizationState.issue()
    }

    func startCapture(
        authorizedBy authorization: RealtimeAudioCaptureAuthorization,
        onPCM16Chunk _: @escaping @Sendable (Data) -> Void,
        onCaptureFailure _: @escaping @Sendable (RealtimeAudioEngineError) -> Void
    ) async throws {
        try captureAuthorizationState.validate(authorization)
    }

    func stopCapture() { captureAuthorizationState.revoke() }

    func enqueuePCM16(
        _ data: Data,
        itemID _: String?,
        responseID _: String
    ) throws {
        XCTAssertFalse(data.isEmpty)
    }

    func notifyWhenPlaybackDrained(
        responseID: String,
        onDrained: @escaping @Sendable (String) -> Void
    ) {
        onDrained(responseID)
    }

    func stopPlayback() {}
    func stopAll() { captureAuthorizationState.revoke() }
}

private actor VoiceSecurityTransport: RealtimeWebSocketTransporting {
    private var incoming: [RealtimeWebSocketMessage]
    private var outgoing: [String] = []
    private var waiters: [CheckedContinuation<RealtimeWebSocketMessage, any Error>] = []
    private var connected = false

    init(openingMessages: [RealtimeWebSocketMessage]) {
        incoming = openingMessages
    }

    func connect(request _: URLRequest) async throws {
        connected = true
    }

    func send(text: String) async throws {
        guard connected else { throw VoiceSecurityTestError.disconnected }
        outgoing.append(text)
    }

    func receive() async throws -> RealtimeWebSocketMessage {
        guard connected else { throw VoiceSecurityTestError.disconnected }
        if !incoming.isEmpty {
            return incoming.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func disconnect() async {
        connected = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(throwing: CancellationError())
        }
    }

    func enqueue(_ message: RealtimeWebSocketMessage) {
        if waiters.isEmpty {
            incoming.append(message)
        } else {
            waiters.removeFirst().resume(returning: message)
        }
    }

    func sentTexts() -> [String] {
        outgoing
    }
}
