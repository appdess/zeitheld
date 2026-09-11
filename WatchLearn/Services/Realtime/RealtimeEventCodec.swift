import CoreFoundation
import Foundation

enum RealtimeEventEncodingError: Error, Equatable {
    case invalidJSONObject
    case invalidChallenge
    case invalidAudioChunk
}

enum RealtimeEventDecodingError: Error, Equatable {
    case invalidJSON
    case missingEventType
    case eventTooLarge
    case invalidField
    case fieldTooLarge
    case invalidAudioDelta
    case invalidFunctionArguments
}

struct RealtimeFunctionCall: Equatable, Sendable {
    let name: String
    let callID: String
    let arguments: String
}

enum DecodedRealtimeServerEvent: Equatable, Sendable {
    case sessionCreated(id: String?)
    case sessionUpdated(id: String?)
    case responseCreated(id: String, requestID: String?)
    case audioDelta(data: Data, itemID: String?, responseID: String?)
    case audioDone(responseID: String)
    case transcriptDelta(
        speaker: RealtimeTranscriptSpeaker,
        text: String,
        responseID: String?
    )
    case transcriptCompleted(
        speaker: RealtimeTranscriptSpeaker,
        text: String,
        responseID: String?
    )
    case speechStarted
    case speechStopped
    case responseDone(
        id: String?,
        requestID: String?,
        functionCalls: [RealtimeFunctionCall]
    )
    case responseFailed(id: String?, requestID: String?, error: RealtimeAPIError)
    case error(RealtimeAPIError)
    case ignored(type: String)
}

enum RealtimeEventEncoder {
    static func clientSecretRequest(
        options: RealtimeSessionOptions
    ) throws -> Data {
        try encodeData([
            "expires_after": [
                "anchor": "created_at",
                "seconds": options.clientSecretTTLSeconds
            ],
            // Keep client-secret minting deliberately minimal. The endpoint
            // binds the short-lived token to the model; the complete audio,
            // VAD, language, prompt, and tool configuration is applied with
            // `session.update` after the WebSocket opens. This also avoids a
            // server-side 500 observed when the full reasoning session was
            // embedded in the client-secret request.
            "session": [
                "type": "realtime",
                "model": RealtimeConstants.model
            ]
        ])
    }

    static func sessionUpdate(
        options: RealtimeSessionOptions
    ) throws -> String {
        try encodeText([
            "type": "session.update",
            "session": sessionConfiguration(options: options)
        ])
    }

    static func appendAudio(_ pcm16: Data) throws -> String {
        guard !pcm16.isEmpty,
              pcm16.count <= RealtimeConstants.maxInputAudioChunkBytes,
              pcm16.count.isMultiple(of: 2) else {
            throw RealtimeEventEncodingError.invalidAudioChunk
        }
        return try encodeText([
            "type": "input_audio_buffer.append",
            "audio": pcm16.base64EncodedString()
        ])
    }

    static func challengeContext(_ challenge: ClockChallengeContext) throws -> String {
        guard (0...23).contains(challenge.hour),
              (0...59).contains(challenge.minute),
              !challenge.difficulty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RealtimeEventEncodingError.invalidChallenge
        }

        var content: [[String: Any]] = [[
            "type": "input_text",
            "text": """
            NEW_CLOCK_CHALLENGE (trusted app context, not the child's answer): target hour=\(challenge.hour), target minute=\(challenge.minute), difficulty=\(challenge.difficulty), language=\(challenge.language.rawValue). Look at the supplied clock if present. Invite the child to read it without revealing the answer.
            """
        ]]

        if let base64 = challenge.clockImageBase64 {
            let allowedTypes = ["image/png", "image/jpeg"]
            guard allowedTypes.contains(challenge.clockImageMediaType),
                  base64.utf8.count <= Self.maximumBase64Length(
                      forDecodedByteCount: RealtimeConstants.maxChallengeImageBytes
                  ),
                  let imageData = Data(base64Encoded: base64),
                  imageData.count <= RealtimeConstants.maxChallengeImageBytes else {
                throw RealtimeEventEncodingError.invalidChallenge
            }
            content.append([
                "type": "input_image",
                "image_url": "data:\(challenge.clockImageMediaType);base64,\(base64)"
            ])
        }

        return try encodeText([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": content
            ]
        ])
    }

    static func functionCallOutput(
        callID: String,
        result: ClockAnswerToolResult
    ) throws -> String {
        let outputData = try JSONEncoder().encode(result)
        guard let output = String(data: outputData, encoding: .utf8) else {
            throw RealtimeEventEncodingError.invalidJSONObject
        }
        return try functionCallOutput(callID: callID, output: output)
    }

    static func waitForUserOutput(callID: String) throws -> String {
        try functionCallOutput(callID: callID, output: #"{"waiting":true}"#)
    }

    static func responseCreate(requestID: String, spokenFeedbackLanguage: RealtimeCoachLanguage? = nil) throws -> String {
        guard isValidIdentifier(requestID) else {
            throw RealtimeEventEncodingError.invalidJSONObject
        }
        var response: [String: Any] = [
            "metadata": ["watchlearn_request_id": requestID]
        ]
        if let language = spokenFeedbackLanguage {
            // Grading has finished. A second wait_for_user tool call here can
            // otherwise replace spoken feedback entirely and stall progression.
            response["tool_choice"] = "none"
            response["instructions"] = ClockCoachPrompt.instructions(language: language) + """

            CURRENT RESPONSE
            The clock-answer tool has returned its authoritative grade. Speak now:
            give one brief celebration for a correct answer, or one gentle hint
            for an incorrect or unclear answer. Do not reveal a new clock or ask
            the child to press anything. This response is spoken feedback only;
            no tool call is needed. Follow the language and child-safety rules above.
            """
        }
        return try encodeText(["type": "response.create", "response": response])
    }

    static func responseCancel(responseID: String? = nil) throws -> String {
        var event: [String: Any] = ["type": "response.cancel"]
        if let responseID {
            guard isValidIdentifier(responseID) else {
                throw RealtimeEventEncodingError.invalidJSONObject
            }
            event["response_id"] = responseID
        }
        return try encodeText(event)
    }

    private static func functionCallOutput(
        callID: String,
        output: String
    ) throws -> String {
        try encodeText([
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callID,
                "output": output
            ]
        ])
    }

    private static func sessionConfiguration(
        options: RealtimeSessionOptions
    ) -> [String: Any] {
        return [
            "type": "realtime",
            "model": RealtimeConstants.model,
            "output_modalities": ["audio"],
            "instructions": ClockCoachPrompt.instructions(language: options.language),
            "reasoning": ["effort": "low"],
            "audio": [
                "input": [
                    "format": [
                        "type": "audio/pcm",
                        "rate": RealtimeConstants.sampleRate
                    ],
                    // The realtime model hears PCM directly and calls the grading
                    // tool itself. No separate speech-to-text request is needed.
                    "transcription": NSNull(),
                    "noise_reduction": [
                        "type": "near_field"
                    ],
                    "turn_detection": [
                        "type": "semantic_vad",
                        // Respond promptly when an answer is complete. Low eagerness
                        // waits longer and makes short answers feel turn-based.
                        "eagerness": "high",
                        "create_response": true,
                        "interrupt_response": true
                    ]
                ],
                "output": [
                    "format": [
                        "type": "audio/pcm",
                        "rate": RealtimeConstants.sampleRate
                    ],
                    "voice": options.voice.rawValue,
                    // JSONSerialization otherwise expands a Swift Double such
                    // as 0.95 to 17 decimal places, which the Realtime API
                    // rejects. NSDecimalNumber preserves the intended JSON.
                    "speed": NSDecimalNumber(string: "0.95")
                ]
            ],
            "tools": toolDefinitions,
            "tool_choice": "auto",
            "max_output_tokens": 600
        ]
    }

    private static var toolDefinitions: [[String: Any]] {
        [
            [
                "type": "function",
                "name": "report_clock_answer",
                "description": ClockCoachPrompt.reportClockAnswerDescription,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "hour": [
                            "anyOf": [
                                ["type": "integer", "minimum": 0, "maximum": 23],
                                ["type": "null"]
                            ],
                            "description": "The hour exactly as spoken, or null when unclear."
                        ],
                        "minute": [
                            "anyOf": [
                                ["type": "integer", "minimum": 0, "maximum": 59],
                                ["type": "null"]
                            ],
                            "description": "The minute exactly as spoken, or null when unclear."
                        ],
                        "unknown": [
                            "type": "boolean",
                            "description": "True when any required part could not be understood."
                        ]
                    ],
                    "required": ["hour", "minute", "unknown"],
                    "additionalProperties": false
                ]
            ],
            [
                "type": "function",
                "name": "wait_for_user",
                "description": ClockCoachPrompt.waitForUserDescription,
                "parameters": [
                    "type": "object",
                    "properties": [:],
                    "required": [],
                    "additionalProperties": false
                ]
            ]
        ]
    }

    private static func encodeText(_ object: Any) throws -> String {
        let data = try encodeData(object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeEventEncodingError.invalidJSONObject
        }
        return text
    }

    private static func encodeData(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw RealtimeEventEncodingError.invalidJSONObject
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func maximumBase64Length(forDecodedByteCount byteCount: Int) -> Int {
        ((byteCount + 2) / 3) * 4
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= RealtimeConstants.maxIdentifierBytes
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && (
                    CharacterSet.alphanumerics.contains(scalar)
                        || scalar == "_"
                        || scalar == "-"
                )
            }
    }
}

enum RealtimeEventDecoder {
    static func decode(_ text: String) throws -> DecodedRealtimeServerEvent {
        guard text.utf8.count <= RealtimeConstants.maxServerEventBytes else {
            throw RealtimeEventDecodingError.eventTooLarge
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let event = object as? [String: Any] else {
            throw RealtimeEventDecodingError.invalidJSON
        }
        guard event["type"] != nil else {
            throw RealtimeEventDecodingError.missingEventType
        }
        let type = try requiredString(
            event["type"],
            maximumBytes: 128
        )

        switch type {
        case "session.created":
            let session = event["session"] as? [String: Any]
            return .sessionCreated(id: try optionalIdentifier(session?["id"]))

        case "session.updated":
            let session = event["session"] as? [String: Any]
            return .sessionUpdated(id: try optionalIdentifier(session?["id"]))

        case "response.created":
            guard let response = event["response"] as? [String: Any] else {
                throw RealtimeEventDecodingError.invalidField
            }
            return .responseCreated(
                id: try requiredIdentifier(response["id"]),
                requestID: try requestID(from: response)
            )

        case "response.output_audio.delta":
            let delta = try requiredString(
                event["delta"],
                maximumBytes: RealtimeConstants.maxAudioDeltaBase64Bytes
            )
            guard let audio = Data(base64Encoded: delta),
                  audio.count <= RealtimeConstants.maxDecodedAudioDeltaBytes else {
                throw RealtimeEventDecodingError.invalidAudioDelta
            }
            return .audioDelta(
                data: audio,
                itemID: try optionalIdentifier(event["item_id"]),
                responseID: try optionalIdentifier(event["response_id"])
            )

        case "response.output_audio.done":
            return .audioDone(
                responseID: try requiredIdentifier(event["response_id"])
            )

        case "response.output_audio_transcript.delta", "response.output_text.delta":
            return .transcriptDelta(
                speaker: .coach,
                text: try requiredString(
                    event["delta"],
                    maximumBytes: RealtimeConstants.maxTranscriptDeltaBytes
                ),
                responseID: try requiredIdentifier(event["response_id"])
            )

        case "response.output_audio_transcript.done":
            return .transcriptCompleted(
                speaker: .coach,
                text: try requiredString(
                    event["transcript"],
                    maximumBytes: RealtimeConstants.maxCompletedTranscriptBytes
                ),
                responseID: try requiredIdentifier(event["response_id"])
            )

        case "response.output_text.done":
            return .transcriptCompleted(
                speaker: .coach,
                text: try requiredString(
                    event["text"],
                    maximumBytes: RealtimeConstants.maxCompletedTranscriptBytes
                ),
                responseID: try requiredIdentifier(event["response_id"])
            )

        case "conversation.item.input_audio_transcription.delta":
            return .transcriptDelta(
                speaker: .child,
                text: try requiredString(
                    event["delta"],
                    maximumBytes: RealtimeConstants.maxTranscriptDeltaBytes
                ),
                responseID: nil
            )

        case "conversation.item.input_audio_transcription.completed":
            return .transcriptCompleted(
                speaker: .child,
                text: try requiredString(
                    event["transcript"],
                    maximumBytes: RealtimeConstants.maxCompletedTranscriptBytes
                ),
                responseID: nil
            )

        case "conversation.item.input_audio_transcription.failed":
            return .error(apiError(
                from: event,
                fallbackMessage: "The child's speech could not be transcribed."
            ))

        case "input_audio_buffer.speech_started":
            return .speechStarted

        case "input_audio_buffer.speech_stopped":
            return .speechStopped

        case "response.done":
            guard let response = event["response"] as? [String: Any] else {
                throw RealtimeEventDecodingError.invalidField
            }
            let responseID = try optionalIdentifier(response["id"])
            let clientRequestID = try requestID(from: response)
            if let status = safeIdentifier(response["status"], maximumBytes: 32),
               status == "failed" || status == "incomplete" {
                let statusDetails = response["status_details"] as? [String: Any]
                let nestedError = statusDetails?["error"] as? [String: Any]
                let reason = safeIdentifier(statusDetails?["reason"], maximumBytes: 128)
                return .responseFailed(
                    id: responseID,
                    requestID: clientRequestID,
                    error: RealtimeAPIError(
                    type: safeIdentifier(nestedError?["type"], maximumBytes: 128) ?? status,
                    code: safeIdentifier(nestedError?["code"], maximumBytes: 128) ?? reason,
                    message: "The Realtime response could not be completed.",
                    parameter: safeIdentifier(nestedError?["param"], maximumBytes: 128),
                    eventID: safeIdentifier(event["event_id"], maximumBytes: 128)
                    )
                )
            }
            let output = response["output"] as? [[String: Any]] ?? []
            var calls: [RealtimeFunctionCall] = []
            for item in output where item["type"] as? String == "function_call" {
                guard calls.count < RealtimeConstants.maxFunctionCallsPerResponse else {
                    throw RealtimeEventDecodingError.fieldTooLarge
                }
                calls.append(RealtimeFunctionCall(
                    name: try requiredIdentifier(item["name"]),
                    callID: try requiredIdentifier(item["call_id"]),
                    arguments: try requiredString(
                        item["arguments"],
                        maximumBytes: RealtimeConstants.maxFunctionArgumentsBytes
                    )
                ))
            }
            return .responseDone(
                id: responseID,
                requestID: clientRequestID,
                functionCalls: calls
            )

        case "error":
            return .error(apiError(
                from: event,
                fallbackMessage: "Unknown Realtime API error."
            ))

        default:
            return .ignored(type: type)
        }
    }

    static func clockAnswer(from arguments: String) throws -> ClockAnswerReport {
        guard arguments.utf8.count <= RealtimeConstants.maxFunctionArgumentsBytes,
              let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let values = object as? [String: Any] else {
            throw RealtimeEventDecodingError.invalidFunctionArguments
        }

        let hour = integer(values["hour"]).flatMap { (0...23).contains($0) ? $0 : nil }
        let minute = integer(values["minute"]).flatMap { (0...59).contains($0) ? $0 : nil }
        let explicitUnknown = values["unknown"] as? Bool ?? false

        return ClockAnswerReport(
            hour: hour,
            minute: minute,
            unknown: explicitUnknown || hour == nil || minute == nil
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let double = number.doubleValue
        guard double.rounded() == double else { return nil }
        return number.intValue
    }

    private static func apiError(
        from event: [String: Any],
        fallbackMessage: String
    ) -> RealtimeAPIError {
        let payload = event["error"] as? [String: Any] ?? event
        return RealtimeAPIError(
            type: safeIdentifier(payload["type"], maximumBytes: 128),
            code: safeIdentifier(payload["code"], maximumBytes: 128),
            message: fallbackMessage,
            parameter: safeIdentifier(payload["param"], maximumBytes: 128),
            eventID: safeIdentifier(payload["event_id"], maximumBytes: 128)
                ?? safeIdentifier(event["event_id"], maximumBytes: 128)
        )
    }

    private static func requestID(from response: [String: Any]) throws -> String? {
        guard let metadata = response["metadata"] as? [String: Any] else {
            return nil
        }
        return try optionalIdentifier(metadata["watchlearn_request_id"])
    }

    private static func requiredIdentifier(_ value: Any?) throws -> String {
        let identifier = try requiredString(
            value,
            maximumBytes: RealtimeConstants.maxIdentifierBytes
        )
        guard isSafeIdentifier(identifier) else {
            throw RealtimeEventDecodingError.invalidField
        }
        return identifier
    }

    private static func optionalIdentifier(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        return try requiredIdentifier(value)
    }

    private static func requiredString(
        _ value: Any?,
        maximumBytes: Int
    ) throws -> String {
        guard let value = value as? String, !value.isEmpty else {
            throw RealtimeEventDecodingError.invalidField
        }
        guard value.utf8.count <= maximumBytes else {
            throw RealtimeEventDecodingError.fieldTooLarge
        }
        return value
    }

    private static func safeIdentifier(
        _ value: Any?,
        maximumBytes: Int
    ) -> String? {
        guard let value = value as? String,
              !value.isEmpty,
              value.utf8.count <= maximumBytes,
              isSafeIdentifier(value) else {
            return nil
        }
        return value
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "_"
                    || scalar == "-"
                    || scalar == "."
            )
        }
    }
}
