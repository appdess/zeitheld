import Foundation
import XCTest
@testable import WatchLearn

@MainActor
final class RealtimeServiceTests: XCTestCase {
    func testCompletedResponseCancellationIsHarmlessButOtherErrorsAreForwarded() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"cancel-race"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"cancel-race"}}"#)
        ])
        let service = OpenAIRealtimeService(tokenProvider: FakeClientSecretProvider(), transport: transport)
        try await service.connect(options: .init(), safetyIdentifier: .init(stableID: "cancel-race"))
        let firstError = Task {
            for await event in service.events {
                if case let .serverError(error) = event { return error.code }
            }
            return nil as String?
        }
        defer { firstError.cancel() }
        await transport.enqueue(.text(#"{"type":"error","error":{"code":"response_cancel_not_active","message":"Already completed"}}"#))
        await transport.enqueue(.text(#"{"type":"error","error":{"code":"rate_limit_exceeded","message":"Rate limited"}}"#))
        let code = await firstError.value
        XCTAssertEqual(code, "rate_limit_exceeded")
        await service.disconnect()
    }

    func testConsumedEphemeralTokenRetriesWithFreshSecret() async throws {
        let provider = RotatingFixtureSecretProvider()
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"error","error":{"type":"invalid_request_error","code":"ephemeral_token_already_used","message":"already used"}}"#),
            .text(#"{"type":"session.created","session":{"id":"retry"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"retry"}}"#)
        ])
        let service = OpenAIRealtimeService(tokenProvider: provider, transport: transport)
        try await service.connect(options: .init(), safetyIdentifier: .init(stableID: "retry"))
        let calls = await provider.count
        let request = await transport.connectionRequest()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer ek_rotating_fixture_2")
        await service.disconnect()
    }

    func testConsumedEphemeralTokenRetryIsBounded() async throws {
        let provider = RotatingFixtureSecretProvider()
        let rejection = RealtimeWebSocketMessage.text(#"{"type":"error","error":{"type":"invalid_request_error","code":"ephemeral_token_already_used","message":"already used"}}"#)
        let transport = FakeRealtimeTransport(openingMessages: [rejection, rejection, rejection])
        let service = OpenAIRealtimeService(tokenProvider: provider, transport: transport)
        do {
            try await service.connect(options: .init(), safetyIdentifier: .init(stableID: "retry-bound"))
            XCTFail("Expected second rejection to stop")
        } catch let error as RealtimeAPIError {
            XCTAssertEqual(error.code, "ephemeral_token_already_used")
        }
        let calls = await provider.count
        let disconnects = await transport.numberOfDisconnects()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(disconnects, 2)
    }

    func testConnectWaitsForSessionUpdatedBeforeAllowingChallenge() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_sync"}}"#)
        ])
        let service = OpenAIRealtimeService(
            tokenProvider: FakeClientSecretProvider(),
            transport: transport
        )
        let connect = Task {
            try await service.connect(
                options: .init(language: .german),
                safetyIdentifier: RealtimeSafetyIdentifier(stableID: "sync-fixture")
            )
        }

        _ = try await waitForSentEvent(on: transport) {
            $0["type"] as? String == "session.update"
        }
        do {
            try await service.updateChallenge(
                challenge(hour: 2, minute: 30),
                askCoachToStart: false
            )
            XCTFail("Challenge must remain blocked until session.updated")
        } catch {
            XCTAssertEqual(error as? RealtimeServiceError, .notConnected)
        }
        let eventsBeforeAcknowledgement = try await sentEvents(on: transport)
        XCTAssertFalse(eventsBeforeAcknowledgement.contains {
            $0["type"] as? String == "conversation.item.create"
        })

        await transport.enqueue(.text(
            #"{"type":"rate_limits.updated","rate_limits":[]}"#
        ))
        await transport.enqueue(.text(
            #"{"type":"session.updated","session":{"id":"sess_sync"}}"#
        ))
        try await connect.value
        try await service.updateChallenge(
            challenge(hour: 2, minute: 30),
            askCoachToStart: false
        )
        _ = try await waitForSentEvent(on: transport) {
            $0["type"] as? String == "conversation.item.create"
        }
        await service.disconnect()
    }

    func testSessionUpdateErrorFailsConnectAndCleansUpTransport() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_rejected"}}"#),
            .text(#"{"type":"error","error":{"type":"invalid_request_error","code":"invalid_session_configuration","message":"unsafe provider detail"}}"#)
        ])
        let service = OpenAIRealtimeService(
            tokenProvider: FakeClientSecretProvider(),
            transport: transport
        )

        do {
            try await service.connect(
                options: .init(),
                safetyIdentifier: RealtimeSafetyIdentifier(stableID: "reject-fixture")
            )
            XCTFail("Expected session.update rejection")
        } catch let error as RealtimeAPIError {
            XCTAssertEqual(error.code, "invalid_session_configuration")
        }

        let disconnectCount = await transport.numberOfDisconnects()
        XCTAssertEqual(disconnectCount, 1)
        let sent = try await sentEvents(on: transport)
        XCTAssertEqual(sent.map { $0["type"] as? String }, ["session.update"])
    }

    func testSessionUpdateAcknowledgementTimesOutAndCleansUpTransport() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_timeout"}}"#)
        ])
        let service = OpenAIRealtimeService(
            tokenProvider: FakeClientSecretProvider(),
            transport: transport,
            sessionUpdateAcknowledgementTimeout: .milliseconds(25)
        )

        do {
            try await service.connect(
                options: .init(),
                safetyIdentifier: RealtimeSafetyIdentifier(stableID: "timeout-fixture")
            )
            XCTFail("Expected a bounded session.updated timeout")
        } catch let error as RealtimeAPIError {
            XCTAssertEqual(error.code, "network_timeout")
            XCTAssertEqual(VoiceCoachFailure(error: error).code, .networkTimeout)
        }

        let disconnectCount = await transport.numberOfDisconnects()
        XCTAssertEqual(disconnectCount, 1)
        let sent = try await sentEvents(on: transport)
        XCTAssertEqual(sent.map { $0["type"] as? String }, ["session.update"])
    }

    func testOpeningEventTimesOutAndCleansUpTransport() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [])
        let service = OpenAIRealtimeService(
            tokenProvider: FakeClientSecretProvider(),
            transport: transport,
            openingEventAcknowledgementTimeout: .milliseconds(25)
        )

        do {
            try await service.connect(
                options: .init(),
                safetyIdentifier: RealtimeSafetyIdentifier(stableID: "opening-timeout")
            )
            XCTFail("Expected a bounded session.created timeout")
        } catch let error as RealtimeAPIError {
            XCTAssertEqual(error.code, "network_timeout")
            XCTAssertFalse(error.message.contains("token"))
        }

        let disconnectCount = await transport.numberOfDisconnects()
        let sentTexts = await transport.sentTexts()
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertTrue(sentTexts.isEmpty)
    }

    func testRuntimeCaptureFailureReportsOnceAndTerminatesSession() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_capture"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_capture"}}"#)
        ])
        let capture = FailingRealtimeCapture()
        let service = OpenAIRealtimeService(
            tokenProvider: FakeClientSecretProvider(),
            transport: transport,
            audioCapture: capture
        )
        try await service.connect(
            options: .init(),
            safetyIdentifier: RealtimeSafetyIdentifier(stableID: "capture-fixture")
        )
        try await service.startVoice(
            authorizedBy: capture.authorizeCaptureStart()
        )

        let errorEvent = Task {
            for await event in service.events {
                if case let .serverError(error) = event {
                    return error
                }
            }
            throw RealtimeServiceTestError.disconnected
        }
        capture.fail(.conversionFailed)
        capture.fail(.conversionFailed)

        let error = try await errorEvent.value
        XCTAssertEqual(error.code, "audio_format_invalid")
        try await waitUntil { capture.stopCaptureCount == 1 }
        let disconnectCount = await transport.numberOfDisconnects()
        XCTAssertEqual(disconnectCount, 1)
    }

    func testCaptureFailureGateOnlyReportsFirstFailure() {
        let gate = CaptureFailureGate()
        let recorder = CaptureFailureRecorder()

        gate.reportOnce(.conversionFailed) { error in
            recorder.append(error)
        }
        gate.reportOnce(.invalidAudioFormat) { error in
            recorder.append(error)
        }

        XCTAssertEqual(recorder.errors, [.conversionFailed])
    }

    func testSpeechStoppedFloodFailsClosedAtTrackingLimit() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_speech_flood"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_speech_flood"}}"#)
        ])
        let service = OpenAIRealtimeService(
            tokenProvider: FakeClientSecretProvider(),
            transport: transport
        )
        try await service.connect(
            options: .init(),
            safetyIdentifier: RealtimeSafetyIdentifier(stableID: "speech-flood")
        )
        let terminalError = nextServerError(in: service.events)

        for _ in 0...OpenAIRealtimeService.maximumTrackedResponsesPerSession {
            await transport.enqueue(.text(
                #"{"type":"input_audio_buffer.speech_stopped"}"#
            ))
        }

        let error = try await terminalError.value
        XCTAssertEqual(error.code, "response_tracking_limit_exceeded")
        try await waitForDisconnectCount(1, on: transport)
    }

    func testUnmatchedResponseCreatedFloodFailsClosedAtTrackingLimit() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_created_flood"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_created_flood"}}"#)
        ])
        let service = OpenAIRealtimeService(
            tokenProvider: FakeClientSecretProvider(),
            transport: transport
        )
        try await service.connect(
            options: .init(),
            safetyIdentifier: RealtimeSafetyIdentifier(stableID: "created-flood")
        )
        let terminalError = nextServerError(in: service.events)

        for index in 0...OpenAIRealtimeService.maximumTrackedResponsesPerSession {
            await transport.enqueue(.text(
                #"{"type":"response.created","response":{"id":"resp_unmatched_\#(index)"}}"#
            ))
        }

        let error = try await terminalError.value
        XCTAssertEqual(error.code, "response_tracking_limit_exceeded")
        try await waitForDisconnectCount(1, on: transport)
    }

    func testServiceGradesReportedAnswerAndReturnsFunctionOutput() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_fixture"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_fixture"}}"#)
        ])
        let service = OpenAIRealtimeService(
            tokenProvider: FakeClientSecretProvider(),
            transport: transport
        )
        let safety = RealtimeSafetyIdentifier(stableID: "fixture-profile")

        try await service.connect(options: .init(language: .german), safetyIdentifier: safety)
        try await service.updateChallenge(
            ClockChallengeContext(
                hour: 15,
                minute: 0,
                difficulty: "full-hour",
                language: .german
            ),
            askCoachToStart: false
        )

        await transport.enqueue(.text(#"{"type":"input_audio_buffer.speech_stopped"}"#))
        await transport.enqueue(.text(
            #"{"type":"response.created","response":{"id":"resp_answer"}}"#
        ))

        await transport.enqueue(.text(
            #"{"type":"response.done","response":{"id":"resp_answer","output":[{"type":"function_call","name":"report_clock_answer","call_id":"call_fixture","arguments":"{\"hour\":3,\"minute\":0,\"unknown\":false}"}]}}"#
        ))

        let (report, result) = try await nextClockAnswer(in: service.events)
        XCTAssertEqual(report, ClockAnswerReport(hour: 3, minute: 0, unknown: false))
        XCTAssertEqual(result.correct, true)

        let sent = try await waitForSentEvent(on: transport) { event in
            guard event["type"] as? String == "conversation.item.create",
                  let item = event["item"] as? [String: Any] else {
                return false
            }
            return item["type"] as? String == "function_call_output"
        }
        let item = try XCTUnwrap(sent["item"] as? [String: Any])
        XCTAssertEqual(item["call_id"] as? String, "call_fixture")
        let output = try XCTUnwrap(item["output"] as? String)
        let outputJSON = try XCTUnwrap(jsonObject(output))
        XCTAssertEqual(outputJSON["correct"] as? Bool, true)

        _ = try await waitForSentEvent(on: transport) {
            $0["type"] as? String == "response.create"
        }
        let request = await transport.connectionRequest()
        XCTAssertEqual(
            request?.value(forHTTPHeaderField: "Authorization"),
            "Bearer ek_service_fixture"
        )
        XCTAssertNil(request?.value(forHTTPHeaderField: "OpenAI-Beta"))

        await service.disconnect()
    }

    func testLateReportFromPreviousChallengeIsRejected() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_stale"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_stale"}}"#)
        ])
        let service = OpenAIRealtimeService(
            tokenProvider: FakeClientSecretProvider(),
            transport: transport
        )
        try await service.connect(
            options: .init(),
            safetyIdentifier: RealtimeSafetyIdentifier(stableID: "stale-fixture")
        )
        try await service.updateChallenge(challenge(hour: 3, minute: 0))
        try await acknowledgeLatestResponseCreate(as: "resp_a", on: transport)

        let challengeB = challenge(hour: 7, minute: 30)
        let update = Task {
            try await service.updateChallenge(challengeB)
        }
        _ = try await waitForSentEvent(on: transport) {
            $0["type"] as? String == "response.cancel"
        }

        await transport.enqueue(.text(
            #"{"type":"response.done","response":{"id":"resp_a","output":[{"type":"function_call","name":"report_clock_answer","call_id":"call_stale","arguments":"{\"hour\":3,\"minute\":0,\"unknown\":false}"}]}}"#
        ))
        try await update.value

        let staleOutput = try await waitForFunctionOutput(
            callID: "call_stale",
            on: transport
        )
        XCTAssertEqual(staleOutput["accepted"] as? Bool, false)

        // Complete B's invitation, then create a VAD response genuinely bound
        // to B. If A leaked a UI report, nextClockAnswer returns A and fails.
        try await acknowledgeLatestResponseCreate(as: "resp_b_intro", on: transport)
        await transport.enqueue(.text(
            #"{"type":"response.done","response":{"id":"resp_b_intro","output":[{"type":"function_call","name":"wait_for_user","call_id":"call_wait_b","arguments":"{}"}]}}"#
        ))
        _ = try await waitForFunctionOutput(callID: "call_wait_b", on: transport)
        await transport.enqueue(.text(#"{"type":"input_audio_buffer.speech_stopped"}"#))
        await transport.enqueue(.text(
            #"{"type":"response.created","response":{"id":"resp_b_answer"}}"#
        ))
        await transport.enqueue(.text(
            #"{"type":"response.done","response":{"id":"resp_b_answer","output":[{"type":"function_call","name":"report_clock_answer","call_id":"call_b","arguments":"{\"hour\":7,\"minute\":30,\"unknown\":false}"}]}}"#
        ))

        let (report, result) = try await nextClockAnswer(in: service.events)
        XCTAssertEqual(report, ClockAnswerReport(hour: 7, minute: 30, unknown: false))
        XCTAssertEqual(result.correct, true)

        try await waitForSentEventCount(type: "response.create", count: 3, on: transport)
        let responseCreateCount = try await sentEvents(on: transport).filter {
            $0["type"] as? String == "response.create"
        }.count
        XCTAssertEqual(responseCreateCount, 3, "A must not create stale feedback")
        await service.disconnect()
    }

    @MainActor
    func testChallengeUpdateCancelsAndDrainsFeedbackBeforeStartingNextResponse() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_drain"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_drain"}}"#)
        ])
        let playback = FakeRealtimePlayback()
        let service = OpenAIRealtimeService(
            tokenProvider: FakeClientSecretProvider(),
            transport: transport,
            audioPlayback: playback
        )
        try await service.connect(
            options: .init(),
            safetyIdentifier: RealtimeSafetyIdentifier(stableID: "drain-fixture")
        )
        try await service.updateChallenge(challenge(hour: 4, minute: 15))
        try await acknowledgeLatestResponseCreate(as: "resp_intro_a", on: transport)

        await transport.enqueue(.text(
            #"{"type":"response.done","response":{"id":"resp_intro_a","output":[{"type":"function_call","name":"wait_for_user","call_id":"call_intro","arguments":"{}"}]}}"#
        ))
        _ = try await waitForFunctionOutput(callID: "call_intro", on: transport)
        await transport.enqueue(.text(#"{"type":"input_audio_buffer.speech_stopped"}"#))
        await transport.enqueue(.text(
            #"{"type":"response.created","response":{"id":"resp_answer_a"}}"#
        ))
        await transport.enqueue(.text(
            #"{"type":"response.done","response":{"id":"resp_answer_a","output":[{"type":"function_call","name":"report_clock_answer","call_id":"call_a","arguments":"{\"hour\":4,\"minute\":15,\"unknown\":false}"}]}}"#
        ))
        try await waitForSentEventCount(type: "response.create", count: 2, on: transport)
        try await acknowledgeLatestResponseCreate(as: "resp_feedback_a", on: transport)

        await transport.enqueue(.text(
            #"{"type":"response.output_audio.delta","response_id":"resp_feedback_a","item_id":"feedback_a","delta":"AQI="}"#
        ))
        try await waitUntil { playback.enqueuedCount == 1 }
        let stopsBeforeUpdate = playback.stopCount

        let challengeB = challenge(hour: 8, minute: 45)
        let update = Task {
            try await service.updateChallenge(challengeB)
        }
        _ = try await waitForSentEvent(on: transport) {
            $0["type"] as? String == "response.cancel"
        }
        XCTAssertGreaterThan(playback.stopCount, stopsBeforeUpdate)
        let responseCreatesBeforeDrain = try await sentEvents(on: transport).filter {
            $0["type"] as? String == "response.create"
        }.count
        XCTAssertEqual(
            responseCreatesBeforeDrain,
            2,
            "B must wait until cancelled A is drained"
        )

        await transport.enqueue(.text(
            #"{"type":"response.output_audio.delta","response_id":"resp_feedback_a","item_id":"late_feedback_a","delta":"AwQ="}"#
        ))
        await transport.enqueue(.text(#"{"type":"response.done","response":{"id":"resp_feedback_a","status":"cancelled","output":[]}}"#))
        try await update.value
        XCTAssertEqual(playback.enqueuedCount, 1, "late A audio must stay muted")

        let texts = await transport.sentTexts()
        let cancelIndex = try XCTUnwrap(texts.firstIndex { text in
            (try? jsonObject(text)?["type"] as? String) == "response.cancel"
        })
        let challengeBIndex = try XCTUnwrap(texts.firstIndex { $0.contains("target hour=8") })
        let responseBIndex = try XCTUnwrap(texts.indices.first { index in
            index > challengeBIndex
                && (try? jsonObject(texts[index])?["type"] as? String) == "response.create"
        })
        XCTAssertLessThan(cancelIndex, challengeBIndex)
        XCTAssertLessThan(challengeBIndex, responseBIndex)
        await service.disconnect()
    }

    func testUnknownCompletionCannotConsumeOrRebindTrackedResponse() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_ids"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_ids"}}"#)
        ])
        let service = OpenAIRealtimeService(
            tokenProvider: FakeClientSecretProvider(),
            transport: transport
        )
        try await service.connect(
            options: .init(),
            safetyIdentifier: RealtimeSafetyIdentifier(stableID: "ids-fixture")
        )
        try await service.updateChallenge(challenge(hour: 2, minute: 0))
        try await acknowledgeLatestResponseCreate(as: "resp_trusted", on: transport)

        await transport.enqueue(.text(
            #"{"type":"response.done","response":{"id":"resp_unknown","output":[{"type":"function_call","name":"report_clock_answer","call_id":"call_unknown","arguments":"{\"hour\":2,\"minute\":0,\"unknown\":false}"}]}}"#
        ))
        let untrustedOutput = try await waitForFunctionOutput(
            callID: "call_unknown",
            on: transport
        )
        XCTAssertEqual(untrustedOutput["accepted"] as? Bool, false)

        let update = Task {
            try await service.updateChallenge(challenge(hour: 9, minute: 30))
        }
        let cancel = try await waitForSentEvent(on: transport) {
            $0["type"] as? String == "response.cancel"
        }
        XCTAssertEqual(cancel["response_id"] as? String, "resp_trusted")

        await transport.enqueue(.text(
            #"{"type":"response.done","response":{"id":"resp_trusted","status":"cancelled","output":[]}}"#
        ))
        try await update.value
        await service.disconnect()
    }

    func testResponseDrainTimeoutIsBoundedAndDoesNotStartNextChallenge() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_drain_timeout"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_drain_timeout"}}"#)
        ])
        let service = OpenAIRealtimeService(
            tokenProvider: FakeClientSecretProvider(),
            transport: transport,
            responseDrainTimeout: .milliseconds(25)
        )
        try await service.connect(
            options: .init(),
            safetyIdentifier: RealtimeSafetyIdentifier(stableID: "drain-timeout")
        )
        try await service.updateChallenge(challenge(hour: 1, minute: 0))
        try await acknowledgeLatestResponseCreate(as: "resp_never_finishes", on: transport)

        do {
            try await service.updateChallenge(challenge(hour: 10, minute: 30))
            XCTFail("Expected a bounded cancellation drain timeout")
        } catch let error as RealtimeAPIError {
            XCTAssertEqual(error.code, "response_drain_timeout")
            XCTAssertEqual(error.type, "client_error")
        }

        let events = try await sentEvents(on: transport)
        let cancel = try XCTUnwrap(events.first {
            $0["type"] as? String == "response.cancel"
        })
        XCTAssertEqual(cancel["response_id"] as? String, "resp_never_finishes")
        let sentTexts = await transport.sentTexts()
        XCTAssertFalse(sentTexts.contains("target hour=10"))
        await service.disconnect()
    }

    func testConnectRejectsMalformedProviderCredentialBeforeWebSocket() async throws {
        let invalidSecret = RealtimeClientSecret(
            value: "sk_not_ephemeral",
            expiresAt: Date().addingTimeInterval(60)
        )
        let transport = FakeRealtimeTransport(openingMessages: [])
        let service = OpenAIRealtimeService(
            tokenProvider: FakeClientSecretProvider(secret: invalidSecret),
            transport: transport
        )

        do {
            try await service.connect(
                options: .init(),
                safetyIdentifier: RealtimeSafetyIdentifier(stableID: "invalid-secret")
            )
            XCTFail("Expected malformed credential rejection")
        } catch {
            XCTAssertEqual(
                error as? RealtimeClientSecretProviderError,
                .malformedResponse
            )
        }

        let connectionRequest = await transport.connectionRequest()
        XCTAssertNil(connectionRequest)
    }

    func testWaitForUserAcknowledgesWithoutCreatingResponse() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_fixture"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_fixture"}}"#)
        ])
        let service = OpenAIRealtimeService(
            tokenProvider: FakeClientSecretProvider(),
            transport: transport
        )
        try await service.connect(
            options: .init(),
            safetyIdentifier: RealtimeSafetyIdentifier(stableID: "fixture")
        )
        let before = await transport.sentTexts().count

        await transport.enqueue(.text(
            #"{"type":"response.done","response":{"id":"resp_untracked","output":[{"type":"function_call","name":"wait_for_user","call_id":"call_wait","arguments":"{}"}]}}"#
        ))
        _ = try await waitForSentEvent(on: transport) { event in
            guard let item = event["item"] as? [String: Any] else { return false }
            return item["call_id"] as? String == "call_wait"
        }

        try await Task.sleep(for: .milliseconds(30))
        let afterEvents = try await transport.sentTexts().dropFirst(before).compactMap(jsonObject)
        XCTAssertFalse(afterEvents.contains { $0["type"] as? String == "response.create" })

        await service.disconnect()
    }

    func testInterruptedCoachResponseCannotReclaimSpeakingPhaseFromLateDelta() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_turn_state"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_turn_state"}}"#)
        ])
        let audio = FakeVoiceCoachAudio()
        let coordinator = VoiceCoachCoordinator(
            microphonePermission: GrantedMicrophonePermission(),
            sessionFactory: { _ in
                VoiceCoachSessionResources(
                    service: OpenAIRealtimeService(
                        tokenProvider: FakeClientSecretProvider(),
                        transport: transport,
                        audioCapture: audio,
                        audioPlayback: audio
                    ),
                    audioEngine: audio
                )
            }
        )
        let defaultsName = "VoiceCoachTurnStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let preferences = ParentPreferences(defaults: defaults)
        preferences.cloudVoiceMode = .managedBroker
        preferences.brokerURLText = "https://voice-fixture.invalid/token"
        let question = TimeQuestion(
            id: 42,
            time: ClockTime(hour: 8, minute: 0),
            level: .fullHour,
            choices: [ClockTime(hour: 8, minute: 0)],
            heroTheme: .skyGuardian
        )

        await coordinator.start(question: question, preferences: preferences)
        XCTAssertEqual(coordinator.phase, .listening)
        try await acknowledgeLatestResponseCreate(
            as: "resp_intro",
            on: transport
        )

        await transport.enqueue(.text(
            #"{"type":"response.output_audio.delta","response_id":"resp_intro","item_id":"item_intro","delta":"AQI="}"#
        ))
        try await waitUntil { coordinator.phase == .coachSpeaking }

        await transport.enqueue(.text(
            #"{"type":"input_audio_buffer.speech_started","item_id":"item_child"}"#
        ))
        try await waitUntil { coordinator.phase == .childSpeaking }
        await transport.enqueue(.text(
            #"{"type":"input_audio_buffer.speech_stopped","item_id":"item_child"}"#
        ))
        try await waitUntil { coordinator.phase == .listening }

        // Realtime delta events may still arrive concurrently after server VAD
        // has interrupted the response. A late delta from that old response
        // must not reclaim the visible coach turn.
        await transport.enqueue(.text(
            #"{"type":"response.output_audio_transcript.delta","response_id":"resp_intro","item_id":"item_intro","delta":"late intro"}"#
        ))
        await transport.enqueue(.text(
            #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item_child","delta":"barrier"}"#
        ))
        try await waitUntil { coordinator.childTranscript == "barrier" }

        XCTAssertEqual(coordinator.coachTranscript, "")
        XCTAssertEqual(coordinator.phase, .listening)
        await coordinator.stop()
    }

    func testAudioDoneStillForwardsFollowingCompletedTranscript() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_audio_order"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_audio_order"}}"#)
        ])
        let service = OpenAIRealtimeService(
            tokenProvider: FakeClientSecretProvider(),
            transport: transport
        )
        try await service.connect(
            options: .init(),
            safetyIdentifier: RealtimeSafetyIdentifier(stableID: "audio-order")
        )
        try await service.updateChallenge(challenge(hour: 10, minute: 0))
        try await acknowledgeLatestResponseCreate(
            as: "resp_audio_order",
            on: transport
        )

        let observedEvents = Task {
            var events: [RealtimeServiceEvent] = []
            for await event in service.events {
                events.append(event)
                if event == .transcriptCompleted(speaker: .child, text: "barrier") {
                    return events
                }
            }
            throw RealtimeServiceTestError.disconnected
        }

        await transport.enqueue(.text(
            #"{"type":"response.output_audio.done","response_id":"resp_audio_order"}"#
        ))
        await transport.enqueue(.text(
            #"{"type":"response.output_audio_transcript.done","response_id":"resp_audio_order","transcript":"Final coach words"}"#
        ))
        await transport.enqueue(.text(
            #"{"type":"response.done","response":{"id":"resp_audio_order","output":[]}}"#
        ))
        await transport.enqueue(.text(
            #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"barrier"}"#
        ))

        let events = try await observedEvents.value
        XCTAssertTrue(events.contains(
            .transcriptCompleted(speaker: .coach, text: "Final coach words")
        ))
        await service.disconnect()
    }

    func testCoachStaysSpeakingUntilScheduledPlaybackActuallyDrains() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_local_drain"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_local_drain"}}"#)
        ])
        let audio = FakeVoiceCoachAudio()
        let coordinator = VoiceCoachCoordinator(
            microphonePermission: GrantedMicrophonePermission(),
            sessionFactory: { _ in
                VoiceCoachSessionResources(
                    service: OpenAIRealtimeService(
                        tokenProvider: FakeClientSecretProvider(),
                        transport: transport,
                        audioCapture: audio,
                        audioPlayback: audio
                    ),
                    audioEngine: audio
                )
            }
        )
        let defaultsName = "VoiceCoachLocalDrainTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let preferences = ParentPreferences(defaults: defaults)
        preferences.cloudVoiceMode = .managedBroker
        preferences.brokerURLText = "https://voice-fixture.invalid/token"

        await coordinator.start(
            question: TimeQuestion(
                id: 43,
                time: ClockTime(hour: 10, minute: 0),
                level: .fullHour,
                choices: [ClockTime(hour: 10, minute: 0)],
                heroTheme: .skyGuardian
            ),
            preferences: preferences
        )
        try await acknowledgeLatestResponseCreate(
            as: "resp_local_drain",
            on: transport
        )
        await transport.enqueue(.text(
            #"{"type":"response.output_audio.delta","response_id":"resp_local_drain","item_id":"item_local_drain","delta":"AQI="}"#
        ))
        try await waitUntil { coordinator.phase == .coachSpeaking }

        await transport.enqueue(.text(
            #"{"type":"response.output_audio.done","response_id":"resp_local_drain"}"#
        ))
        await transport.enqueue(.text(
            #"{"type":"conversation.item.input_audio_transcription.delta","delta":"barrier"}"#
        ))
        try await waitUntil { coordinator.childTranscript == "barrier" }

        XCTAssertEqual(
            coordinator.phase,
            .coachSpeaking,
            "server generation completion must not claim local playback drained"
        )
        audio.drainPlayback(responseID: "resp_local_drain")
        try await waitUntil { coordinator.phase == .listening }
        await coordinator.stop()
    }

    func testSpokenCorrectAnswerAdvancesOnlyAfterAssociatedFeedbackPlaybackDrains() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_spoken_advance"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_spoken_advance"}}"#)
        ])
        let audio = FakeVoiceCoachAudio()
        let coordinator = VoiceCoachCoordinator(
            microphonePermission: GrantedMicrophonePermission(),
            sessionFactory: { _ in
                VoiceCoachSessionResources(
                    service: OpenAIRealtimeService(
                        tokenProvider: FakeClientSecretProvider(),
                        transport: transport,
                        audioCapture: audio,
                        audioPlayback: audio
                    ),
                    audioEngine: audio
                )
            }
        )
        let defaultsName = "VoiceCoachSpokenAdvanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let preferences = ParentPreferences(defaults: defaults)
        preferences.cloudVoiceMode = .managedBroker
        preferences.brokerURLText = "https://voice-fixture.invalid/token"
        let viewModel = LearningViewModel(seed: 709)
        let initialQuestion = viewModel.question

        coordinator.onClockAnswer = { report in
            guard let hour = report.hour,
                  let minute = report.minute,
                  !report.unknown else { return }
            viewModel.chooseSpoken(ClockTime(hour: hour, minute: minute))
        }
        coordinator.onSpokenCorrectAnswerFeedbackFinished = { questionID, _ in
            guard questionID == viewModel.question.id else { return }
            viewModel.continueAfterSpokenFeedback(questionID: questionID)
        }

        await coordinator.start(
            question: initialQuestion,
            preferences: preferences
        )
        try await acknowledgeLatestResponseCreate(
            as: "resp_spoken_answer",
            on: transport
        )
        await transport.enqueue(.text(
            #"{"type":"response.done","response":{"id":"resp_spoken_answer","output":[{"type":"function_call","name":"report_clock_answer","call_id":"call_spoken_correct","arguments":"{\"hour\":\#(initialQuestion.time.hour),\"minute\":\#(initialQuestion.time.minute),\"unknown\":false}"}]}}"#
        ))
        try await waitUntil { viewModel.evaluation?.isCorrect == true }
        XCTAssertEqual(viewModel.question.id, initialQuestion.id)
        XCTAssertTrue(viewModel.canContinue, "the Next button remains a fallback")

        try await waitForSentEventCount(
            type: "response.create",
            count: 2,
            on: transport
        )
        try await acknowledgeLatestResponseCreate(
            as: "resp_spoken_feedback",
            on: transport
        )
        await transport.enqueue(.text(
            #"{"type":"response.output_audio.delta","response_id":"resp_spoken_feedback","item_id":"item_spoken_feedback","delta":"AQI="}"#
        ))
        await transport.enqueue(.text(
            #"{"type":"response.output_audio.done","response_id":"resp_spoken_feedback"}"#
        ))
        try await waitUntil {
            audio.pendingDrainResponseIDs.contains("resp_spoken_feedback")
        }

        XCTAssertEqual(
            viewModel.question.id,
            initialQuestion.id,
            "server completion must not advance before local feedback playback drains"
        )
        audio.drainPlayback(responseID: "resp_spoken_feedback")

        try await waitUntil { viewModel.question.id != initialQuestion.id }
        await coordinator.stop()
    }

    func testCorrectFeedbackWithoutAudioNeverAutoAdvances() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_silent_feedback"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_silent_feedback"}}"#)
        ])
        let audio = FakeVoiceCoachAudio()
        let coordinator = VoiceCoachCoordinator(
            microphonePermission: GrantedMicrophonePermission(),
            sessionFactory: { _ in
                VoiceCoachSessionResources(
                    service: OpenAIRealtimeService(
                        tokenProvider: FakeClientSecretProvider(),
                        transport: transport,
                        audioCapture: audio,
                        audioPlayback: audio
                    ),
                    audioEngine: audio
                )
            }
        )
        let defaultsName = "VoiceCoachSilentFeedbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let preferences = ParentPreferences(defaults: defaults)
        preferences.cloudVoiceMode = .managedBroker
        preferences.brokerURLText = "https://voice-fixture.invalid/token"
        let viewModel = LearningViewModel(seed: 712)
        let initialQuestion = viewModel.question
        var completionCount = 0

        coordinator.onClockAnswer = { report in
            guard let hour = report.hour,
                  let minute = report.minute,
                  !report.unknown else { return }
            viewModel.chooseSpoken(ClockTime(hour: hour, minute: minute))
        }
        coordinator.onSpokenCorrectAnswerFeedbackFinished = { _, _ in
            completionCount += 1
        }

        await coordinator.start(
            question: initialQuestion,
            preferences: preferences
        )
        try await acknowledgeLatestResponseCreate(
            as: "resp_silent_answer",
            on: transport
        )
        await transport.enqueue(.text(
            #"{"type":"response.done","response":{"id":"resp_silent_answer","output":[{"type":"function_call","name":"report_clock_answer","call_id":"call_silent_correct","arguments":"{\"hour\":\#(initialQuestion.time.hour),\"minute\":\#(initialQuestion.time.minute),\"unknown\":false}"}]}}"#
        ))
        try await waitUntil { viewModel.evaluation?.isCorrect == true }
        try await waitForSentEventCount(
            type: "response.create",
            count: 2,
            on: transport
        )
        try await acknowledgeLatestResponseCreate(
            as: "resp_silent_feedback",
            on: transport
        )

        // A server-side audio completion without even one successfully
        // scheduled audio delta is not an audible coaching reply.
        await transport.enqueue(.text(
            #"{"type":"response.output_audio.done","response_id":"resp_silent_feedback"}"#
        ))
        try await waitUntil {
            audio.pendingDrainResponseIDs.contains("resp_silent_feedback")
        }
        audio.drainPlayback(responseID: "resp_silent_feedback")
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(completionCount, 0)
        XCTAssertEqual(viewModel.question.id, initialQuestion.id)
        XCTAssertTrue(viewModel.canContinue, "manual Next remains available")
        await coordinator.stop()
    }

    func testSynchronousStopDisarmsAutoAdvanceBeforeRetiredDrainCanFire() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_stop_advance"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_stop_advance"}}"#)
        ])
        let audio = FakeVoiceCoachAudio()
        let coordinator = VoiceCoachCoordinator(
            microphonePermission: GrantedMicrophonePermission(),
            sessionFactory: { _ in
                VoiceCoachSessionResources(
                    service: OpenAIRealtimeService(
                        tokenProvider: FakeClientSecretProvider(),
                        transport: transport,
                        audioCapture: audio,
                        audioPlayback: audio
                    ),
                    audioEngine: audio
                )
            }
        )
        let defaultsName = "VoiceCoachStopAdvanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let preferences = ParentPreferences(defaults: defaults)
        preferences.cloudVoiceMode = .managedBroker
        preferences.brokerURLText = "https://voice-fixture.invalid/token"
        let viewModel = LearningViewModel(seed: 713)
        let initialQuestion = viewModel.question
        var completionCount = 0

        coordinator.onClockAnswer = { report in
            guard let hour = report.hour,
                  let minute = report.minute,
                  !report.unknown else { return }
            viewModel.chooseSpoken(ClockTime(hour: hour, minute: minute))
        }
        coordinator.onSpokenCorrectAnswerFeedbackFinished = { questionID, _ in
            completionCount += 1
            viewModel.continueAfterSpokenFeedback(questionID: questionID)
        }
        coordinator.onSpokenAutoAdvanceCancelled = {
            viewModel.cancelSpokenAutoAdvance()
        }

        await coordinator.start(
            question: initialQuestion,
            preferences: preferences
        )
        try await acknowledgeLatestResponseCreate(
            as: "resp_stop_answer",
            on: transport
        )
        await transport.enqueue(.text(
            #"{"type":"response.done","response":{"id":"resp_stop_answer","output":[{"type":"function_call","name":"report_clock_answer","call_id":"call_stop_correct","arguments":"{\"hour\":\#(initialQuestion.time.hour),\"minute\":\#(initialQuestion.time.minute),\"unknown\":false}"}]}}"#
        ))
        try await waitUntil { viewModel.evaluation?.isCorrect == true }
        try await waitForSentEventCount(
            type: "response.create",
            count: 2,
            on: transport
        )
        try await acknowledgeLatestResponseCreate(
            as: "resp_stop_feedback",
            on: transport
        )
        await transport.enqueue(.text(
            #"{"type":"response.output_audio.delta","response_id":"resp_stop_feedback","item_id":"item_stop_feedback","delta":"AQI="}"#
        ))
        await transport.enqueue(.text(
            #"{"type":"response.output_audio.done","response_id":"resp_stop_feedback"}"#
        ))
        try await waitUntil {
            audio.pendingDrainResponseIDs.contains("resp_stop_feedback")
        }

        // This is the exact synchronous boundary used by the red Stop button.
        coordinator.stopLocalAudioImmediately()
        XCTAssertFalse(coordinator.isSessionActive)
        audio.drainRetiredPlayback(responseID: "resp_stop_feedback")
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(completionCount, 0)
        XCTAssertEqual(viewModel.question.id, initialQuestion.id)
        XCTAssertTrue(viewModel.canContinue, "Stop must leave manual Next available")
        await coordinator.stop()
    }

    func testChallengeAdvanceClearsPendingSpeakingResponseBeforeNextPlaybackDrains() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_challenge_drain"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_challenge_drain"}}"#)
        ])
        let audio = FakeVoiceCoachAudio()
        let coordinator = VoiceCoachCoordinator(
            microphonePermission: GrantedMicrophonePermission(),
            sessionFactory: { _ in
                VoiceCoachSessionResources(
                    service: OpenAIRealtimeService(
                        tokenProvider: FakeClientSecretProvider(),
                        transport: transport,
                        audioCapture: audio,
                        audioPlayback: audio
                    ),
                    audioEngine: audio
                )
            }
        )
        let defaultsName = "VoiceCoachChallengeDrainTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let preferences = ParentPreferences(defaults: defaults)
        preferences.cloudVoiceMode = .managedBroker
        preferences.brokerURLText = "https://voice-fixture.invalid/token"

        await coordinator.start(
            question: TimeQuestion(
                id: 51,
                time: ClockTime(hour: 9, minute: 0),
                level: .fullHour,
                choices: [ClockTime(hour: 9, minute: 0)],
                heroTheme: .skyGuardian
            ),
            preferences: preferences
        )
        try await acknowledgeLatestResponseCreate(
            as: "resp_challenge_a",
            on: transport
        )
        await transport.enqueue(.text(
            #"{"type":"response.output_audio.delta","response_id":"resp_challenge_a","item_id":"item_challenge_a","delta":"AQI="}"#
        ))
        try await waitUntil { coordinator.phase == .coachSpeaking }
        await transport.enqueue(.text(
            #"{"type":"response.output_audio.done","response_id":"resp_challenge_a"}"#
        ))
        await transport.enqueue(.text(
            #"{"type":"response.done","response":{"id":"resp_challenge_a","output":[]}}"#
        ))
        await transport.enqueue(.text(
            #"{"type":"conversation.item.input_audio_transcription.delta","delta":"barrier-a"}"#
        ))
        try await waitUntil { coordinator.childTranscript == "barrier-a" }

        await coordinator.updateChallenge(TimeQuestion(
            id: 52,
            time: ClockTime(hour: 9, minute: 30),
            level: .halfHour,
            choices: [ClockTime(hour: 9, minute: 30)],
            heroTheme: .skyGuardian
        ))
        XCTAssertEqual(coordinator.phase, .listening)
        try await acknowledgeLatestResponseCreate(
            as: "resp_challenge_b",
            on: transport
        )
        await transport.enqueue(.text(
            #"{"type":"response.output_audio.delta","response_id":"resp_challenge_b","item_id":"item_challenge_b","delta":"AwQ="}"#
        ))
        try await waitUntil { coordinator.phase == .coachSpeaking }
        await transport.enqueue(.text(
            #"{"type":"response.output_audio.done","response_id":"resp_challenge_b"}"#
        ))
        try await waitUntil {
            audio.pendingDrainResponseIDs.contains("resp_challenge_b")
        }
        audio.drainPlayback(responseID: "resp_challenge_b")

        try await waitUntil { coordinator.phase == .listening }
        await coordinator.stop()
    }

    func testInterruptedPlaybackCannotEmitStaleDrainCompletion() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_stale_drain"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_stale_drain"}}"#)
        ])
        let playback = FakeRealtimePlayback()
        let service = OpenAIRealtimeService(
            tokenProvider: FakeClientSecretProvider(),
            transport: transport,
            audioPlayback: playback
        )
        try await service.connect(
            options: .init(),
            safetyIdentifier: RealtimeSafetyIdentifier(stableID: "stale-drain")
        )
        try await service.updateChallenge(challenge(hour: 11, minute: 0))
        try await acknowledgeLatestResponseCreate(
            as: "resp_stale_drain",
            on: transport
        )

        let observedEvents = Task {
            var events: [RealtimeServiceEvent] = []
            for await event in service.events {
                events.append(event)
                if event == .assistantAudioFinished(responseID: "resp_after_stale") {
                    return events
                }
            }
            throw RealtimeServiceTestError.disconnected
        }

        await transport.enqueue(.text(
            #"{"type":"response.output_audio.delta","response_id":"resp_stale_drain","item_id":"item_stale_drain","delta":"AQI="}"#
        ))
        await transport.enqueue(.text(
            #"{"type":"response.output_audio.done","response_id":"resp_stale_drain"}"#
        ))
        try await waitUntil {
            playback.pendingDrainResponseIDs.contains("resp_stale_drain")
        }
        let stopCountBeforeInterruption = playback.stopCount
        await transport.enqueue(.text(
            #"{"type":"input_audio_buffer.speech_started"}"#
        ))
        try await waitUntil {
            playback.stopCount > stopCountBeforeInterruption
        }

        XCTAssertFalse(playback.pendingDrainResponseIDs.contains("resp_stale_drain"))
        XCTAssertTrue(playback.retiredDrainResponseIDs.contains("resp_stale_drain"))
        await transport.enqueue(.text(
            #"{"type":"input_audio_buffer.speech_stopped"}"#
        ))
        await transport.enqueue(.text(
            #"{"type":"response.created","response":{"id":"resp_after_stale"}}"#
        ))
        await transport.enqueue(.text(
            #"{"type":"response.output_audio.delta","response_id":"resp_after_stale","item_id":"item_after_stale","delta":"AwQ="}"#
        ))
        await transport.enqueue(.text(
            #"{"type":"response.output_audio.done","response_id":"resp_after_stale"}"#
        ))
        try await waitUntil {
            playback.pendingDrainResponseIDs.contains("resp_after_stale")
        }

        // A's cancelled completion arrives after B has been scheduled, then B
        // drains normally. Only B may emit a playback-finished service event.
        playback.drainRetiredPlayback(responseID: "resp_stale_drain")
        playback.drainPlayback(responseID: "resp_after_stale")
        let events = try await observedEvents.value
        XCTAssertFalse(events.contains(
            .assistantAudioFinished(responseID: "resp_stale_drain")
        ))
        XCTAssertTrue(events.contains(
            .assistantAudioFinished(responseID: "resp_after_stale")
        ))
        await service.disconnect()
    }

    func testRetryWaitsForTerminalTearDownAndKeepsNewSessionInstalled() async throws {
        let firstTransport = FakeRealtimeTransport(
            openingMessages: [
                .text(#"{"type":"session.created","session":{"id":"sess_first"}}"#),
                .text(#"{"type":"session.updated","session":{"id":"sess_first"}}"#)
            ],
            blocksDisconnect: true
        )
        let secondTransport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_second"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_second"}}"#)
        ])
        let firstAudio = FakeVoiceCoachAudio()
        let secondAudio = FakeVoiceCoachAudio()
        let harness = CoordinatorSessionHarness(sessions: [
            (firstTransport, firstAudio),
            (secondTransport, secondAudio)
        ])
        let coordinator = VoiceCoachCoordinator(
            microphonePermission: GrantedMicrophonePermission(),
            sessionFactory: { _ in harness.makeSession() }
        )
        let defaultsName = "VoiceCoachRaceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let preferences = ParentPreferences(defaults: defaults)
        preferences.cloudVoiceMode = .managedBroker
        preferences.brokerURLText = "https://voice-fixture.invalid/token"
        let question = TimeQuestion(
            id: 1,
            time: ClockTime(hour: 5, minute: 0),
            level: .fullHour,
            choices: [ClockTime(hour: 5, minute: 0)],
            heroTheme: .skyGuardian
        )

        await coordinator.start(question: question, preferences: preferences)
        XCTAssertTrue(coordinator.isSessionActive)

        await firstTransport.enqueue(.text(
            #"{"type":"error","error":{"type":"server_error","code":"terminal_fixture","message":"fixture disconnect"}}"#
        ))
        try await firstTransport.waitForDisconnectToStart()
        try await waitUntil {
            if case .failed = coordinator.phase { return true }
            return false
        }

        let retry = Task {
            await coordinator.start(question: question, preferences: preferences)
        }
        try await waitUntil { coordinator.isStarting }
        XCTAssertEqual(harness.createdSessionCount, 1, "retry must wait for old teardown")

        await firstTransport.releaseDisconnect()
        await retry.value

        XCTAssertEqual(harness.createdSessionCount, 2)
        XCTAssertTrue(coordinator.isSessionActive)
        XCTAssertEqual(coordinator.phase, .listening)
        let secondDisconnectCount = await secondTransport.numberOfDisconnects()
        XCTAssertEqual(secondDisconnectCount, 0)
        XCTAssertEqual(secondAudio.stopAllCount, 0)
        await coordinator.stop()
    }

    func testStartupFailureMappingUsesLocalizedAllowListedCodes() {
        let cases: [(Error, VoiceCoachFailureCode)] = [
            (RealtimeClientSecretProviderError.httpStatus(403, requestID: "unsafe"), .credentialForbidden),
            (RealtimeClientSecretProviderError.httpStatus(429, requestID: "unsafe"), .credentialRateLimited),
            (URLError(.notConnectedToInternet), .networkOffline),
            (URLError(.timedOut), .networkTimeout),
            (RealtimeClientSecretProviderError.malformedResponse, .malformedServiceResponse),
            (RealtimeWebSocketTransportError.disconnected, .sessionSetup),
            (RealtimeAudioEngineError.audioSessionConfigurationFailed, .audioConfiguration),
            (RealtimeAudioEngineError.audioSessionActivationFailed, .audioActivation),
            (RealtimeAudioEngineError.audioEngineStartFailed, .audioEngineStart),
            (RealtimeAudioEngineError.microphoneUnavailable, .audioInputRoute),
            (RealtimeAudioEngineError.invalidConverter, .audioConverter),
            (RealtimeAudioEngineError.invalidAudioFormat, .audioFormat)
        ]

        for (error, expectedCode) in cases {
            let failure = VoiceCoachFailure(error: error)
            XCTAssertEqual(failure.code, expectedCode)
            let german = failure.localizedMessage(language: .german)
            let english = failure.localizedMessage(language: .english)
            XCTAssertTrue(german.hasSuffix("[\(expectedCode.rawValue)]"))
            XCTAssertTrue(english.hasSuffix("[\(expectedCode.rawValue)]"))
            XCTAssertNotEqual(german, english)
            XCTAssertFalse(german.contains("unsafe"))
            XCTAssertFalse(english.contains("unsafe"))
        }

        let unsafeAPIError = RealtimeAPIError(
            type: "authentication_error",
            code: "invalid_api_key",
            message: "sk-live-secret and a child transcript",
            parameter: "secret",
            eventID: "event-secret"
        )
        let message = VoiceCoachFailure(error: unsafeAPIError)
            .localizedMessage(language: .english)
        XCTAssertTrue(message.hasSuffix("[VC-TOKEN-401]"))
        XCTAssertFalse(message.contains("sk-live-secret"))
        XCTAssertFalse(message.contains("child transcript"))
    }

    func testAudioStartFailureCleansUpSessionAndShowsSpecificCode() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_audio_fail"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_audio_fail"}}"#)
        ])
        let audio = FakeVoiceCoachAudio(startCaptureError: .audioEngineStartFailed)
        let harness = CoordinatorSessionHarness(sessions: [(transport, audio)])
        let coordinator = VoiceCoachCoordinator(
            microphonePermission: GrantedMicrophonePermission(),
            sessionFactory: { _ in harness.makeSession() }
        )
        let defaultsName = "VoiceCoachAudioFailureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let preferences = ParentPreferences(defaults: defaults)
        preferences.cloudVoiceMode = .managedBroker
        preferences.brokerURLText = "https://voice-fixture.invalid/token"
        let question = TimeQuestion(
            id: 2,
            time: ClockTime(hour: 9, minute: 30),
            level: .halfHour,
            choices: [ClockTime(hour: 9, minute: 30)],
            heroTheme: .skyGuardian
        )

        await coordinator.start(question: question, preferences: preferences)

        guard case let .failed(message) = coordinator.phase else {
            return XCTFail("Expected a categorized audio start failure")
        }
        XCTAssertTrue(message.hasSuffix("[VC-AUDIO-START]"))
        XCTAssertFalse(coordinator.isSessionActive)
        XCTAssertEqual(audio.startCaptureCount, 1)
        XCTAssertEqual(audio.stopAllCount, 1)
        let disconnectCount = await transport.numberOfDisconnects()
        XCTAssertEqual(disconnectCount, 1)
    }

    func testStopBeforeQueuedCaptureStartCannotReactivateMicrophone() async throws {
        let transport = FakeRealtimeTransport(openingMessages: [
            .text(#"{"type":"session.created","session":{"id":"sess_queued_audio"}}"#),
            .text(#"{"type":"session.updated","session":{"id":"sess_queued_audio"}}"#)
        ])
        let audio = SuspendedVoiceCoachAudio()
        let coordinator = VoiceCoachCoordinator(
            microphonePermission: GrantedMicrophonePermission(),
            sessionFactory: { _ in
                VoiceCoachSessionResources(
                    service: OpenAIRealtimeService(
                        tokenProvider: FakeClientSecretProvider(),
                        transport: transport,
                        audioCapture: audio,
                        audioPlayback: audio
                    ),
                    audioEngine: audio
                )
            }
        )
        let defaultsName = "VoiceCoachQueuedStartTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let preferences = ParentPreferences(defaults: defaults)
        preferences.cloudVoiceMode = .managedBroker
        preferences.brokerURLText = "https://voice-fixture.invalid/token"
        let question = TimeQuestion(
            id: 3,
            time: ClockTime(hour: 6, minute: 0),
            level: .fullHour,
            choices: [ClockTime(hour: 6, minute: 0)],
            heroTheme: .skyGuardian
        )

        let start = Task {
            await coordinator.start(question: question, preferences: preferences)
        }
        try await waitUntil { audio.captureStartIsSuspended }

        coordinator.stopLocalAudioImmediately()
        audio.resumeCaptureStart()
        await start.value

        XCTAssertEqual(audio.captureActivationCount, 0)
        XCTAssertGreaterThanOrEqual(audio.stopAllCount, 1)
        XCTAssertFalse(coordinator.isSessionActive)
        try await waitForDisconnectCount(1, on: transport)
        await coordinator.stop()
        XCTAssertEqual(coordinator.phase, .idle)
    }

    private func nextClockAnswer(
        in stream: AsyncStream<RealtimeServiceEvent>
    ) async throws -> (ClockAnswerReport, ClockAnswerToolResult) {
        try await withThrowingTaskGroup(
            of: (ClockAnswerReport, ClockAnswerToolResult).self
        ) { group in
            group.addTask {
                for await event in stream {
                    if case let .clockAnswerReported(report, result) = event {
                        return (report, result)
                    }
                }
                throw RealtimeServiceTestError.timedOut
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw RealtimeServiceTestError.timedOut
            }
            guard let answer = try await group.next() else {
                throw RealtimeServiceTestError.timedOut
            }
            group.cancelAll()
            return answer
        }
    }

    private func nextServerError(
        in stream: AsyncStream<RealtimeServiceEvent>
    ) -> Task<RealtimeAPIError, any Error> {
        Task {
            for await event in stream {
                if case let .serverError(error) = event {
                    return error
                }
            }
            throw RealtimeServiceTestError.disconnected
        }
    }

    private func waitForSentEvent(
        on transport: FakeRealtimeTransport,
        matching predicate: ([String: Any]) -> Bool
    ) async throws -> [String: Any] {
        for _ in 0..<100 {
            for text in await transport.sentTexts() {
                if let event = try jsonObject(text), predicate(event) {
                    return event
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RealtimeServiceTestError.timedOut
    }

    private func waitForFunctionOutput(
        callID: String,
        on transport: FakeRealtimeTransport
    ) async throws -> [String: Any] {
        let event = try await waitForSentEvent(on: transport) { event in
            guard let item = event["item"] as? [String: Any] else { return false }
            return item["type"] as? String == "function_call_output"
                && item["call_id"] as? String == callID
        }
        let item = try XCTUnwrap(event["item"] as? [String: Any])
        let output = try XCTUnwrap(item["output"] as? String)
        return try XCTUnwrap(jsonObject(output))
    }

    private func acknowledgeLatestResponseCreate(
        as responseID: String,
        on transport: FakeRealtimeTransport
    ) async throws {
        for _ in 0..<100 {
            let creates = try await sentEvents(on: transport).filter {
                $0["type"] as? String == "response.create"
            }
            if let create = creates.last,
               let response = create["response"] as? [String: Any],
               let metadata = response["metadata"] as? [String: Any],
               let requestID = metadata["watchlearn_request_id"] as? String {
                let data = try JSONSerialization.data(withJSONObject: [
                    "type": "response.created",
                    "response": [
                        "id": responseID,
                        "metadata": ["watchlearn_request_id": requestID]
                    ]
                ])
                let text = try XCTUnwrap(String(data: data, encoding: .utf8))
                await transport.enqueue(.text(text))
                try await Task.sleep(for: .milliseconds(10))
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RealtimeServiceTestError.timedOut
    }

    private func waitForSentEventCount(
        type: String,
        count: Int,
        on transport: FakeRealtimeTransport
    ) async throws {
        for _ in 0..<100 {
            let matches = try await sentEvents(on: transport).filter {
                $0["type"] as? String == type
            }.count
            if matches >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RealtimeServiceTestError.timedOut
    }

    private func waitForDisconnectCount(
        _ expectedCount: Int,
        on transport: FakeRealtimeTransport
    ) async throws {
        for _ in 0..<100 {
            if await transport.numberOfDisconnects() >= expectedCount { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RealtimeServiceTestError.timedOut
    }

    private func sentEvents(on transport: FakeRealtimeTransport) async throws -> [[String: Any]] {
        try await transport.sentTexts().compactMap(jsonObject)
    }

    @MainActor
    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<1_000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw RealtimeServiceTestError.timedOut
    }

    private func challenge(hour: Int, minute: Int) -> ClockChallengeContext {
        ClockChallengeContext(
            hour: hour,
            minute: minute,
            difficulty: "race-fixture",
            language: .german
        )
    }

    private func jsonObject(_ text: String) throws -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

@MainActor
private final class FakeRealtimePlayback: RealtimeAudioPlaying {
    private(set) var enqueuedCount = 0
    private(set) var stopCount = 0
    private var drainHandlers: [String: @Sendable (String) -> Void] = [:]
    private var retiredDrainHandlers: [String: [@Sendable (String) -> Void]] = [:]

    var pendingDrainResponseIDs: Set<String> {
        Set(drainHandlers.keys)
    }

    var retiredDrainResponseIDs: Set<String> {
        Set(retiredDrainHandlers.keys)
    }

    func enqueuePCM16(
        _ data: Data,
        itemID _: String?,
        responseID _: String
    ) throws {
        XCTAssertFalse(data.isEmpty)
        enqueuedCount += 1
    }

    func notifyWhenPlaybackDrained(
        responseID: String,
        onDrained: @escaping @Sendable (String) -> Void
    ) {
        drainHandlers[responseID] = onDrained
    }

    func drainPlayback(responseID: String) {
        drainHandlers.removeValue(forKey: responseID)?(responseID)
    }

    func drainRetiredPlayback(responseID: String) {
        guard var handlers = retiredDrainHandlers.removeValue(forKey: responseID),
              !handlers.isEmpty else { return }
        let handler = handlers.removeFirst()
        if !handlers.isEmpty {
            retiredDrainHandlers[responseID] = handlers
        }
        handler(responseID)
    }

    func stopPlayback() {
        stopCount += 1
        for (responseID, handler) in drainHandlers {
            retiredDrainHandlers[responseID, default: []].append(handler)
        }
        drainHandlers.removeAll()
    }
}

private enum RealtimeServiceTestError: Error {
    case timedOut
    case disconnected
}

private struct FakeClientSecretProvider: RealtimeClientSecretProviding {
    private let secret: RealtimeClientSecret

    init(secret: RealtimeClientSecret? = nil) {
        self.secret = secret ?? RealtimeClientSecret(
            value: "ek_service_fixture",
            expiresAt: Date().addingTimeInterval(60)
        )
    }

    func clientSecret(
        options _: RealtimeSessionOptions,
        safetyIdentifier _: RealtimeSafetyIdentifier
    ) async throws -> RealtimeClientSecret {
        secret
    }
}

private actor FakeRealtimeTransport: RealtimeWebSocketTransporting {
    private var incoming: [RealtimeWebSocketMessage]
    private var waiters: [CheckedContinuation<RealtimeWebSocketMessage, any Error>] = []
    private var request: URLRequest?
    private var outgoing: [String] = []
    private var connected = false
    private var blocksDisconnect: Bool
    private var disconnectCount = 0
    private var disconnectStarted = false
    private var disconnectStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var disconnectRelease: CheckedContinuation<Void, Never>?

    init(
        openingMessages: [RealtimeWebSocketMessage],
        blocksDisconnect: Bool = false
    ) {
        incoming = openingMessages
        self.blocksDisconnect = blocksDisconnect
    }

    func connect(request: URLRequest) async throws {
        self.request = request
        connected = true
    }

    func send(text: String) async throws {
        guard connected else { throw RealtimeServiceTestError.disconnected }
        outgoing.append(text)
    }

    func receive() async throws -> RealtimeWebSocketMessage {
        guard connected else { throw RealtimeServiceTestError.disconnected }
        if !incoming.isEmpty {
            return incoming.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func disconnect() async {
        disconnectCount += 1
        disconnectStarted = true
        connected = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(throwing: CancellationError())
        }
        let startedWaiters = disconnectStartedWaiters
        disconnectStartedWaiters.removeAll()
        for waiter in startedWaiters { waiter.resume() }
        if blocksDisconnect {
            await withCheckedContinuation { continuation in
                disconnectRelease = continuation
            }
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

    func connectionRequest() -> URLRequest? {
        request
    }

    func waitForDisconnectToStart() async throws {
        if disconnectStarted { return }
        await withCheckedContinuation { continuation in
            disconnectStartedWaiters.append(continuation)
        }
    }

    func releaseDisconnect() {
        blocksDisconnect = false
        disconnectRelease?.resume()
        disconnectRelease = nil
    }

    func numberOfDisconnects() -> Int {
        disconnectCount
    }
}

private struct GrantedMicrophonePermission: MicrophonePermissionProviding {
    func currentPermission() -> MicrophonePermission { .granted }
    func requestPermission() async -> Bool { true }
}

@MainActor
private final class FakeVoiceCoachAudio: VoiceCoachAudioManaging {
    private let captureAuthorizationState = RealtimeAudioCaptureAuthorizationState()
    private(set) var stopAllCount = 0
    private(set) var startCaptureCount = 0
    private let startCaptureError: RealtimeAudioEngineError?
    private var interruptionHandler: (@Sendable (Bool) -> Void)?
    private var drainHandlers: [String: @Sendable (String) -> Void] = [:]
    private var retiredDrainHandlers: [String: [@Sendable (String) -> Void]] = [:]

    var pendingDrainResponseIDs: Set<String> {
        Set(drainHandlers.keys)
    }

    init(startCaptureError: RealtimeAudioEngineError? = nil) {
        self.startCaptureError = startCaptureError
    }

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
        startCaptureCount += 1
        if let startCaptureError { throw startCaptureError }
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
        drainHandlers[responseID] = onDrained
    }
    func drainPlayback(responseID: String) {
        drainHandlers.removeValue(forKey: responseID)?(responseID)
    }
    func drainRetiredPlayback(responseID: String) {
        guard var handlers = retiredDrainHandlers.removeValue(forKey: responseID),
              !handlers.isEmpty else { return }
        let handler = handlers.removeFirst()
        if !handlers.isEmpty {
            retiredDrainHandlers[responseID] = handlers
        }
        handler(responseID)
    }
    func stopPlayback() {
        for (responseID, handler) in drainHandlers {
            retiredDrainHandlers[responseID, default: []].append(handler)
        }
        drainHandlers.removeAll()
    }
    func stopAll() {
        captureAuthorizationState.revoke()
        stopPlayback()
        stopAllCount += 1
    }
}

@MainActor
private final class FailingRealtimeCapture: RealtimeAudioCapturing {
    private let captureAuthorizationState = RealtimeAudioCaptureAuthorizationState()
    private var failureHandler: (@Sendable (RealtimeAudioEngineError) -> Void)?
    private(set) var stopCaptureCount = 0

    func authorizeCaptureStart() -> RealtimeAudioCaptureAuthorization {
        captureAuthorizationState.issue()
    }

    func startCapture(
        authorizedBy authorization: RealtimeAudioCaptureAuthorization,
        onPCM16Chunk _: @escaping @Sendable (Data) -> Void,
        onCaptureFailure: @escaping @Sendable (RealtimeAudioEngineError) -> Void
    ) async throws {
        try captureAuthorizationState.validate(authorization)
        failureHandler = onCaptureFailure
    }

    func stopCapture() {
        captureAuthorizationState.revoke()
        stopCaptureCount += 1
        failureHandler = nil
    }

    func fail(_ error: RealtimeAudioEngineError) {
        failureHandler?(error)
    }
}

@MainActor
private final class SuspendedVoiceCoachAudio: VoiceCoachAudioManaging {
    private let captureAuthorizationState = RealtimeAudioCaptureAuthorizationState()
    private var captureStartContinuation: CheckedContinuation<Void, Never>?
    private var interruptionHandler: (@Sendable (Bool) -> Void)?
    private(set) var captureStartIsSuspended = false
    private(set) var captureActivationCount = 0
    private(set) var stopAllCount = 0

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
        captureStartIsSuspended = true
        await withCheckedContinuation { continuation in
            captureStartContinuation = continuation
        }
        try Task.checkCancellation()
        try captureAuthorizationState.validate(authorization)
        captureActivationCount += 1
    }

    func resumeCaptureStart() {
        captureStartIsSuspended = false
        captureStartContinuation?.resume()
        captureStartContinuation = nil
    }

    func stopCapture() {
        captureAuthorizationState.revoke()
    }

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

    func stopAll() {
        captureAuthorizationState.revoke()
        stopAllCount += 1
    }
}

private final class CaptureFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedErrors: [RealtimeAudioEngineError] = []

    var errors: [RealtimeAudioEngineError] {
        lock.lock()
        defer { lock.unlock() }
        return storedErrors
    }

    func append(_ error: RealtimeAudioEngineError) {
        lock.lock()
        storedErrors.append(error)
        lock.unlock()
    }
}

@MainActor
private final class CoordinatorSessionHarness {
    private var sessions: [(FakeRealtimeTransport, FakeVoiceCoachAudio)]
    private(set) var createdSessionCount = 0

    init(sessions: [(FakeRealtimeTransport, FakeVoiceCoachAudio)]) {
        self.sessions = sessions
    }

    func makeSession() -> VoiceCoachSessionResources {
        let session = sessions[createdSessionCount]
        createdSessionCount += 1
        return VoiceCoachSessionResources(
            service: OpenAIRealtimeService(
                tokenProvider: FakeClientSecretProvider(),
                transport: session.0,
                audioCapture: session.1,
                audioPlayback: session.1
            ),
            audioEngine: session.1
        )
    }
}

private actor RotatingFixtureSecretProvider: RealtimeClientSecretProviding {
    private(set) var count = 0
    func clientSecret(options: RealtimeSessionOptions,
                      safetyIdentifier: RealtimeSafetyIdentifier) async throws -> RealtimeClientSecret {
        count += 1
        return RealtimeClientSecret(value: "ek_rotating_fixture_\(count)", expiresAt: Date().addingTimeInterval(60))
    }
}
