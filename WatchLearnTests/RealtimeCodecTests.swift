import Foundation
import XCTest
@testable import WatchLearn

final class RealtimeCodecTests: XCTestCase {
    func testPromptIsBilingualChildSafeAndRequiresDeterministicTool() {
        let german = ClockCoachPrompt.instructions(language: .german)
        let english = ClockCoachPrompt.instructions(language: .english)
        let bilingual = ClockCoachPrompt.instructions(language: .bilingual)

        XCTAssertTrue(german.contains("Speak German"))
        XCTAssertTrue(english.contains("Speak English"))
        XCTAssertTrue(bilingual.contains("German first"))
        XCTAssertTrue(german.contains("report_clock_answer exactly once"))
        XCTAssertTrue(german.contains("Never ask for a name"))
        XCTAssertTrue(german.contains("wait_for_user"))
    }

    func testAudioAppendEncodesPCM16AsBase64() throws {
        let pcm = Data([0x00, 0x01, 0xFE, 0xFF])
        let event = try RealtimeEventEncoder.appendAudio(pcm)
        let json = try XCTUnwrap(jsonObject(event))

        XCTAssertEqual(json["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(json["audio"] as? String, pcm.base64EncodedString())
    }

    func testAudioAppendRejectsOddByteCount() {
        XCTAssertThrowsError(try RealtimeEventEncoder.appendAudio(Data([0x01]))) { error in
            XCTAssertEqual(error as? RealtimeEventEncodingError, .invalidAudioChunk)
        }
    }

    func testDecodesGARealtimeAudioTranscriptAndSpeechEvents() throws {
        let audio = Data([0x00, 0x00, 0x01, 0x00])
        XCTAssertEqual(
            try RealtimeEventDecoder.decode(#"{"type":"response.output_audio.delta","response_id":"resp_1","item_id":"item_1","delta":"\#(audio.base64EncodedString())"}"#),
            .audioDelta(data: audio, itemID: "item_1", responseID: "resp_1")
        )
        XCTAssertEqual(
            try RealtimeEventDecoder.decode(
                #"{"type":"response.output_audio.done","response_id":"resp_1"}"#
            ),
            .audioDone(responseID: "resp_1")
        )
        XCTAssertEqual(
            try RealtimeEventDecoder.decode(#"{"type":"response.output_audio_transcript.delta","response_id":"resp_1","delta":"Super!"}"#),
            .transcriptDelta(
                speaker: .coach,
                text: "Super!",
                responseID: "resp_1"
            )
        )
        XCTAssertEqual(
            try RealtimeEventDecoder.decode(#"{"type":"conversation.item.input_audio_transcription.delta","delta":"drei"}"#),
            .transcriptDelta(
                speaker: .child,
                text: "drei",
                responseID: nil
            )
        )
        XCTAssertEqual(
            try RealtimeEventDecoder.decode(#"{"type":"input_audio_buffer.speech_started"}"#),
            .speechStarted
        )
        XCTAssertEqual(
            try RealtimeEventDecoder.decode(#"{"type":"input_audio_buffer.speech_stopped"}"#),
            .speechStopped
        )
    }

    func testDecodesSessionUpdatedAcknowledgement() throws {
        XCTAssertEqual(
            try RealtimeEventDecoder.decode(
                #"{"type":"session.updated","session":{"id":"sess_updated"}}"#
            ),
            .sessionUpdated(id: "sess_updated")
        )
    }

    func testResponseCreateMetadataAndProviderIdentifiersRoundTrip() throws {
        let create = try RealtimeEventEncoder.responseCreate(requestID: "wl_request_42")
        let createRoot = try XCTUnwrap(jsonObject(create))
        let response = try XCTUnwrap(createRoot["response"] as? [String: Any])
        let metadata = try XCTUnwrap(response["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["watchlearn_request_id"] as? String, "wl_request_42")

        XCTAssertEqual(
            try RealtimeEventDecoder.decode(
                #"{"type":"response.created","response":{"id":"resp_42","metadata":{"watchlearn_request_id":"wl_request_42"}}}"#
            ),
            .responseCreated(id: "resp_42", requestID: "wl_request_42")
        )

        let cancel = try RealtimeEventEncoder.responseCancel(responseID: "resp_42")
        XCTAssertEqual(try jsonObject(cancel)?["response_id"] as? String, "resp_42")
    }

    func testGradingFeedbackRequiresSpeechInsteadOfAnotherWaitTool() throws {
        let event = try RealtimeEventEncoder.responseCreate(requestID: "feedback", spokenFeedbackLanguage: .german)
        let response = try XCTUnwrap(try jsonObject(event)?["response"] as? [String: Any])
        XCTAssertEqual(response["tool_choice"] as? String, "none")
        let instructions = try XCTUnwrap(response["instructions"] as? String)
        XCTAssertTrue(instructions.contains("Speak German"))
        XCTAssertTrue(instructions.contains("CHILD SAFETY AND PRIVACY"))
        XCTAssertTrue(instructions.contains("Speak now"))
        let ordinary = try RealtimeEventEncoder.responseCreate(requestID: "ordinary")
        XCTAssertNil((try jsonObject(ordinary)?["response"] as? [String: Any])?["tool_choice"])
    }

    func testDecodesResponseDoneFunctionCallsAndClockArguments() throws {
        let fixture = #"{"type":"response.done","response":{"id":"resp_1","metadata":{"watchlearn_request_id":"wl_request_1"},"output":[{"type":"function_call","name":"report_clock_answer","call_id":"call_1","arguments":"{\"hour\":3,\"minute\":0,\"unknown\":false}"},{"type":"message"}]}}"#

        let event = try RealtimeEventDecoder.decode(fixture)
        XCTAssertEqual(
            event,
            .responseDone(id: "resp_1", requestID: "wl_request_1", functionCalls: [
                RealtimeFunctionCall(
                    name: "report_clock_answer",
                    callID: "call_1",
                    arguments: #"{"hour":3,"minute":0,"unknown":false}"#
                )
            ])
        )
        XCTAssertEqual(
            try RealtimeEventDecoder.clockAnswer(
                from: #"{"hour":3,"minute":0,"unknown":false}"#
            ),
            ClockAnswerReport(hour: 3, minute: 0, unknown: false)
        )
    }

    func testIncompleteClockAnswerIsUnknown() throws {
        XCTAssertEqual(
            try RealtimeEventDecoder.clockAnswer(
                from: #"{"hour":"7","minute":null,"unknown":false}"#
            ),
            ClockAnswerReport(hour: 7, minute: nil, unknown: true)
        )
    }

    func testDecodesStructuredServerError() throws {
        let event = try RealtimeEventDecoder.decode(
            #"{"type":"error","event_id":"event_1","error":{"type":"invalid_request_error","code":"invalid_value","message":"Bad event","param":"type"}}"#
        )
        XCTAssertEqual(
            event,
            .error(RealtimeAPIError(
                type: "invalid_request_error",
                code: "invalid_value",
                message: "Unknown Realtime API error.",
                parameter: "type",
                eventID: "event_1"
            ))
        )
    }

    func testServerErrorNeverReflectsUntrustedMessageOrIdentifiers() throws {
        let event = try RealtimeEventDecoder.decode(
            #"{"type":"error","event_id":"bad\nidentifier","error":{"type":"server_error","code":"invalid_value","message":"sk-reflected child transcript","param":"secret\nfield"}}"#
        )
        XCTAssertEqual(
            event,
            .error(RealtimeAPIError(
                type: "server_error",
                code: "invalid_value",
                message: "Unknown Realtime API error.",
                parameter: nil,
                eventID: nil
            ))
        )
    }

    func testRejectsOversizedEventsTranscriptFieldsAndAudioDeltas() {
        let oversizedEvent = String(
            repeating: "x",
            count: RealtimeConstants.maxServerEventBytes + 1
        )
        XCTAssertThrowsError(try RealtimeEventDecoder.decode(oversizedEvent)) { error in
            XCTAssertEqual(error as? RealtimeEventDecodingError, .eventTooLarge)
        }

        let transcript = String(
            repeating: "x",
            count: RealtimeConstants.maxTranscriptDeltaBytes + 1
        )
        XCTAssertThrowsError(try RealtimeEventDecoder.decode(
            #"{"type":"response.output_text.delta","delta":"\#(transcript)"}"#
        )) { error in
            XCTAssertEqual(error as? RealtimeEventDecodingError, .fieldTooLarge)
        }

        let base64 = String(
            repeating: "A",
            count: RealtimeConstants.maxAudioDeltaBase64Bytes + 4
        )
        XCTAssertThrowsError(try RealtimeEventDecoder.decode(
            #"{"type":"response.output_audio.delta","delta":"\#(base64)"}"#
        )) { error in
            XCTAssertEqual(error as? RealtimeEventDecodingError, .fieldTooLarge)
        }

        let arguments = String(
            repeating: "x",
            count: RealtimeConstants.maxFunctionArgumentsBytes + 1
        )
        XCTAssertThrowsError(try RealtimeEventDecoder.decode(
            #"{"type":"response.done","response":{"id":"resp_large","output":[{"type":"function_call","name":"report_clock_answer","call_id":"call_large","arguments":"\#(arguments)"}]}}"#
        )) { error in
            XCTAssertEqual(error as? RealtimeEventDecodingError, .fieldTooLarge)
        }

        let identifier = String(
            repeating: "i",
            count: RealtimeConstants.maxIdentifierBytes + 1
        )
        XCTAssertThrowsError(try RealtimeEventDecoder.decode(
            #"{"type":"response.created","response":{"id":"\#(identifier)"}}"#
        )) { error in
            XCTAssertEqual(error as? RealtimeEventDecodingError, .fieldTooLarge)
        }
    }

    func testWebSocketValidatorAndInputEncoderEnforceByteLimits() {
        let oversized = Data(
            repeating: 0,
            count: RealtimeConstants.maxServerEventBytes + 1
        )
        XCTAssertThrowsError(
            try RealtimeWebSocketMessageValidator.validate(.data(oversized))
        ) { error in
            XCTAssertEqual(error as? RealtimeWebSocketTransportError, .messageTooLarge)
        }

        let oversizedInput = Data(
            repeating: 0,
            count: RealtimeConstants.maxInputAudioChunkBytes + 2
        )
        XCTAssertThrowsError(try RealtimeEventEncoder.appendAudio(oversizedInput)) { error in
            XCTAssertEqual(error as? RealtimeEventEncodingError, .invalidAudioChunk)
        }
    }

    func testChallengeContextIncludesOptionalDataImage() throws {
        let image = Data([0x89, 0x50, 0x4E, 0x47])
        let challenge = ClockChallengeContext(
            hour: 8,
            minute: 0,
            difficulty: "full-hour",
            language: .german,
            clockImageData: image
        )

        let event = try RealtimeEventEncoder.challengeContext(challenge)
        let root = try XCTUnwrap(jsonObject(event))
        let item = try XCTUnwrap(root["item"] as? [String: Any])
        let content = try XCTUnwrap(item["content"] as? [[String: Any]])

        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        XCTAssertTrue((content[0]["text"] as? String)?.contains("target hour=8") == true)
        XCTAssertEqual(content[1]["type"] as? String, "input_image")
        XCTAssertEqual(
            content[1]["image_url"] as? String,
            "data:image/png;base64,\(image.base64EncodedString())"
        )
    }

    func testChallengeContextRejectsUndocumentedWebPInput() {
        let challenge = ClockChallengeContext(
            hour: 8,
            minute: 0,
            difficulty: "full-hour",
            language: .german,
            clockImageData: Data([0x52, 0x49, 0x46, 0x46]),
            clockImageMediaType: "image/webp"
        )

        XCTAssertThrowsError(try RealtimeEventEncoder.challengeContext(challenge)) { error in
            XCTAssertEqual(error as? RealtimeEventEncodingError, .invalidChallenge)
        }
    }

    func testChallengeContextRejectsOversizedBase64BeforeDecoding() {
        let maximumBase64Length = (
            (RealtimeConstants.maxChallengeImageBytes + 2) / 3
        ) * 4
        let challenge = ClockChallengeContext(
            hour: 8,
            minute: 0,
            difficulty: "full-hour",
            language: .german,
            clockImageBase64: String(
                repeating: "A",
                count: maximumBase64Length + 4
            )
        )

        XCTAssertThrowsError(try RealtimeEventEncoder.challengeContext(challenge)) { error in
            XCTAssertEqual(error as? RealtimeEventEncodingError, .invalidChallenge)
        }
    }

    func testLiveSpeechUsesResponsiveSemanticTurnsWithoutInputTranscription() throws {
        let german = try sessionConfiguration(language: .german)
        let english = try sessionConfiguration(language: .english)
        let bilingual = try sessionConfiguration(language: .bilingual)

        for session in [german, english, bilingual] {
            let audio = try XCTUnwrap(session["audio"] as? [String: Any])
            let input = try XCTUnwrap(audio["input"] as? [String: Any])
            XCTAssertTrue(input["transcription"] is NSNull)
            let vad = try XCTUnwrap(input["turn_detection"] as? [String: Any])
            XCTAssertEqual(vad["type"] as? String, "semantic_vad")
            XCTAssertEqual(vad["eagerness"] as? String, "high")
            XCTAssertEqual(vad["create_response"] as? Bool, true)
            XCTAssertEqual(vad["interrupt_response"] as? Bool, true)
        }

        let audio = try XCTUnwrap(german["audio"] as? [String: Any])
        let output = try XCTUnwrap(audio["output"] as? [String: Any])
        XCTAssertEqual((output["speed"] as? NSNumber)?.decimalValue, Decimal(string: "0.95"))
    }

    func testDecodesTranscriptionAndResponseFailuresAsServerErrors() throws {
        XCTAssertEqual(
            try RealtimeEventDecoder.decode(
                #"{"type":"conversation.item.input_audio_transcription.failed","event_id":"event_t","error":{"type":"transcription_error","code":"audio_unintelligible","message":"Could not understand audio."}}"#
            ),
            .error(RealtimeAPIError(
                type: "transcription_error",
                code: "audio_unintelligible",
                message: "The child's speech could not be transcribed.",
                parameter: nil,
                eventID: "event_t"
            ))
        )

        XCTAssertEqual(
            try RealtimeEventDecoder.decode(
                #"{"type":"response.done","event_id":"event_r","response":{"status":"incomplete","status_details":{"type":"incomplete","reason":"max_output_tokens"},"output":[]}}"#
            ),
            .responseFailed(
                id: nil,
                requestID: nil,
                error: RealtimeAPIError(
                    type: "incomplete",
                    code: "max_output_tokens",
                    message: "The Realtime response could not be completed.",
                    parameter: nil,
                    eventID: "event_r"
                )
            )
        )
    }

    func testDeterministicHandlerAcceptsTwelveHourEquivalent() async {
        let challenge = ClockChallengeContext(
            hour: 15,
            minute: 30,
            difficulty: "half-hour",
            language: .english
        )
        let result = await DeterministicClockAnswerHandler().handle(
            report: ClockAnswerReport(hour: 3, minute: 30, unknown: false),
            challenge: challenge
        )

        XCTAssertEqual(result.correct, true)
        XCTAssertEqual(result.expectedHour, 3)
        XCTAssertEqual(result.expectedMinute, 30)
    }

    func testWebSocketRequestUsesEphemeralTokenAndNoBetaHeader() {
        let safety = RealtimeSafetyIdentifier(stableID: "local-child-profile")
        let request = RealtimeWebSocketRequestFactory.makeRequest(
            clientSecret: RealtimeClientSecret(
                value: "ek_fixture",
                expiresAt: Date().addingTimeInterval(60)
            ),
            safetyIdentifier: safety
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ek_fixture")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "OpenAI-Safety-Identifier"),
            safety.headerValue
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "OpenAI-Beta"))
    }

    func testSafetyIdentifierIsStablePrivateAndHeaderSized() {
        let first = RealtimeSafetyIdentifier(stableID: "local-child-profile")
        let second = RealtimeSafetyIdentifier(stableID: "local-child-profile")
        let different = RealtimeSafetyIdentifier(stableID: "another-profile")

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, different)
        XCTAssertTrue(first.headerValue.hasPrefix("watchlearn_"))
        XCTAssertLessThanOrEqual(first.headerValue.utf8.count, 64)
        XCTAssertFalse(first.headerValue.contains("local-child-profile"))
    }

    private func jsonObject(_ text: String) throws -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func sessionConfiguration(
        language: RealtimeCoachLanguage
    ) throws -> [String: Any] {
        let text = try RealtimeEventEncoder.sessionUpdate(
            options: RealtimeSessionOptions(language: language)
        )
        let data = try XCTUnwrap(text.data(using: .utf8))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["type"] as? String, "session.update")
        return try XCTUnwrap(root["session"] as? [String: Any])
    }

}
