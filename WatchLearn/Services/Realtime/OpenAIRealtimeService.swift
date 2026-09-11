import Foundation

actor OpenAIRealtimeService {
    /// A normal coaching turn has only one or two overlapping responses. Keep a
    /// small allowance for cancellation/barge-in races, but fail closed before
    /// untrusted server events can grow per-session correlation state without
    /// bound.
    static let maximumTrackedResponsesPerSession = 8

    private enum SessionHandshakeRaceResult: @unchecked Sendable {
        case received(Result<String?, any Error>)
        case timedOut
        case cancelled
    }

    private struct SessionHandshakeWaitOutcome: @unchecked Sendable {
        let result: Result<String?, any Error>
        let disconnectedTransport: Bool
    }

    private enum SessionHandshakeEvent: Equatable, Sendable {
        case created
        case updated
    }

    private struct ChallengeBinding: Sendable {
        let generation: UInt64
        let challenge: ClockChallengeContext
    }

    private enum ResponsePurpose: Sendable {
        case general
        case correctAnswerFeedback(questionID: Int?)
    }

    private struct CorrectFeedbackDrain: Sendable {
        let questionID: Int?
    }

    private struct TrackedResponse: Sendable {
        let id: UInt64
        let clientRequestID: String?
        var serverResponseID: String?
        let challenge: ChallengeBinding?
        let purpose: ResponsePurpose
    }

    nonisolated let events: AsyncStream<RealtimeServiceEvent>

    private let eventContinuation: AsyncStream<RealtimeServiceEvent>.Continuation
    private let tokenProvider: any RealtimeClientSecretProviding
    private let transport: any RealtimeWebSocketTransporting
    private let audioCapture: (any RealtimeAudioCapturing)?
    private let audioPlayback: (any RealtimeAudioPlaying)?
    private let answerHandler: any ClockAnswerToolHandling
    private let openingEventAcknowledgementTimeout: Duration
    private let sessionUpdateAcknowledgementTimeout: Duration
    private let responseDrainTimeout: Duration

    private var state: RealtimeConnectionState = .disconnected
    private var challengeGeneration: UInt64 = 0
    private var currentChallenge: ChallengeBinding?
    private var nextResponseID: UInt64 = 0
    private var activeResponses: [TrackedResponse] = []
    private var handlingResponseIDs: Set<UInt64> = []
    private var suppressedOutputResponseIDs: Set<UInt64> = []
    private var audioGenerationFinishedResponseIDs: Set<UInt64> = []
    private var responsesWithAudioData: Set<UInt64> = []
    private var pendingPlaybackDrainResponseIDs: Set<String> = []
    private var pendingCorrectFeedbackDrains: [String: CorrectFeedbackDrain] = [:]
    private var responseCancellationRequested = false
    private var receiveTask: Task<Void, Never>?
    private var audioSendTask: Task<Void, Never>?
    private var audioInputContinuation: AsyncStream<Data>.Continuation?
    private var terminalFailureInProgress = false
    private var disconnectInProgress = false

    init(
        tokenProvider: any RealtimeClientSecretProviding,
        transport: any RealtimeWebSocketTransporting = URLSessionRealtimeWebSocketTransport(),
        audioCapture: (any RealtimeAudioCapturing)? = nil,
        audioPlayback: (any RealtimeAudioPlaying)? = nil,
        answerHandler: any ClockAnswerToolHandling = DeterministicClockAnswerHandler(),
        openingEventAcknowledgementTimeout: Duration = .seconds(8),
        sessionUpdateAcknowledgementTimeout: Duration = .seconds(8),
        responseDrainTimeout: Duration = .seconds(3)
    ) {
        let pair = AsyncStream.makeStream(
            of: RealtimeServiceEvent.self,
            bufferingPolicy: .bufferingNewest(200)
        )
        events = pair.stream
        eventContinuation = pair.continuation
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.audioCapture = audioCapture
        self.audioPlayback = audioPlayback
        self.answerHandler = answerHandler
        self.openingEventAcknowledgementTimeout = openingEventAcknowledgementTimeout
        self.sessionUpdateAcknowledgementTimeout = sessionUpdateAcknowledgementTimeout
        self.responseDrainTimeout = responseDrainTimeout
    }

    deinit {
        receiveTask?.cancel()
        audioSendTask?.cancel()
        audioInputContinuation?.finish()
        eventContinuation.finish()
    }

    func connect(
        options: RealtimeSessionOptions,
        safetyIdentifier: RealtimeSafetyIdentifier
    ) async throws {
        do {
            try await connectAttempt(options: options, safetyIdentifier: safetyIdentifier)
        } catch let error as RealtimeAPIError where error.code == "ephemeral_token_already_used" {
            // A network reconnect can consume a single-use token before the
            // opening event arrives. Retry once with a newly minted secret;
            // never reuse the rejected credential or retry an active lesson.
            try Task.checkCancellation()
            try await connectAttempt(options: options, safetyIdentifier: safetyIdentifier)
        }
    }

    private func connectAttempt(
        options: RealtimeSessionOptions,
        safetyIdentifier: RealtimeSafetyIdentifier
    ) async throws {
        try Task.checkCancellation()
        guard state == .disconnected else {
            throw RealtimeServiceError.alreadyConnected
        }

        terminalFailureInProgress = false
        disconnectInProgress = false
        var transportNeedsCleanup = true
        setState(.requestingToken)
        do {
            let secret = try await tokenProvider.clientSecret(
                options: options,
                safetyIdentifier: safetyIdentifier
            )
            if secret.expiresAt <= Date().addingTimeInterval(
                RealtimeConstants.minimumUsableClientSecretLifetime
            ) {
                throw RealtimeServiceError.expiredClientSecret
            }
            _ = try RealtimeClientSecretValidator.validate(
                value: secret.value,
                expiresAt: secret.expiresAt
            )

            setState(.connecting)
            let request = RealtimeWebSocketRequestFactory.makeRequest(
                clientSecret: secret,
                safetyIdentifier: safetyIdentifier
            )
            try await transport.connect(request: request)
            let opening = await waitForSessionHandshakeEvent(
                .created,
                timeout: openingEventAcknowledgementTimeout
            )
            transportNeedsCleanup = !opening.disconnectedTransport
            let createdSessionID = try opening.result.get()
            try await transport.send(
                text: RealtimeEventEncoder.sessionUpdate(options: options)
            )
            let acknowledgement = await waitForSessionHandshakeEvent(
                .updated,
                timeout: sessionUpdateAcknowledgementTimeout
            )
            transportNeedsCleanup = !acknowledgement.disconnectedTransport
            let updatedSessionID = try acknowledgement.result.get()
            setState(.connected(sessionID: updatedSessionID ?? createdSessionID))
            startReceiveLoop()
        } catch {
            if transportNeedsCleanup {
                await transport.disconnect()
            }
            setState(.disconnected)
            throw error
        }
    }

    func disconnect() async {
        guard state != .disconnected,
              !disconnectInProgress,
              !terminalFailureInProgress else {
            return
        }
        disconnectInProgress = true
        receiveTask?.cancel()
        receiveTask = nil
        await stopVoice()
        await stopPlaybackAndInvalidateDrains()
        await transport.disconnect()
        currentChallenge = nil
        clearResponseTracking()
        setState(.disconnected)
        disconnectInProgress = false
    }

    func startVoice(
        authorizedBy authorization: RealtimeAudioCaptureAuthorization
    ) async throws {
        try Task.checkCancellation()
        guard case .connected = state else {
            throw RealtimeServiceError.notConnected
        }
        guard let audioCapture else {
            throw RealtimeServiceError.audioUnavailable
        }
        guard audioSendTask == nil else { return }

        let pair = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingNewest(50)
        )
        audioInputContinuation = pair.continuation
        audioSendTask = Task { [weak self] in
            do {
                for await chunk in pair.stream {
                    guard !Task.isCancelled else { break }
                    try await self?.sendAudioChunk(chunk)
                }
            } catch is CancellationError {
                // Normal shutdown.
            } catch {
                await self?.handleTransportFailure(error)
            }
        }

        do {
            try await audioCapture.startCapture(
                authorizedBy: authorization,
                onPCM16Chunk: { [continuation = pair.continuation] data in
                    continuation.yield(data)
                },
                onCaptureFailure: { [weak self] error in
                    Task {
                        await self?.handleAudioCaptureFailure(error)
                    }
                }
            )
            try Task.checkCancellation()
        } catch {
            pair.continuation.finish()
            audioInputContinuation = nil
            audioSendTask?.cancel()
            audioSendTask = nil
            await audioCapture.stopCapture()
            throw error
        }
    }

    func stopVoice() async {
        audioInputContinuation?.finish()
        audioInputContinuation = nil
        audioSendTask?.cancel()
        audioSendTask = nil
        if let audioCapture {
            await audioCapture.stopCapture()
        }
    }

    func updateChallenge(
        _ challenge: ClockChallengeContext,
        askCoachToStart: Bool = true
    ) async throws {
        guard case .connected = state else {
            throw RealtimeServiceError.notConnected
        }

        let contextEvent: String
        do {
            contextEvent = try RealtimeEventEncoder.challengeContext(challenge)
        } catch {
            throw RealtimeServiceError.invalidChallenge
        }

        challengeGeneration &+= 1
        let generation = challengeGeneration
        // Invalidate the old binding before the first suspension point. A
        // response that finishes while the UI is moving on must never be
        // graded against the new clock.
        currentChallenge = nil

        await stopPlaybackAndInvalidateDrains()
        try await cancelAndDrainResponses()
        guard generation == challengeGeneration else { return }
        guard case .connected = state else {
            throw RealtimeServiceError.notConnected
        }

        try await transport.send(text: contextEvent)
        guard generation == challengeGeneration else { return }
        let binding = ChallengeBinding(generation: generation, challenge: challenge)
        currentChallenge = binding
        if askCoachToStart {
            try await createResponse(for: binding)
        }
    }

    func cancelCoachResponse() async throws {
        guard case .connected = state else {
            throw RealtimeServiceError.notConnected
        }
        await stopPlaybackAndInvalidateDrains()
        try await cancelAndDrainResponses()
    }

    private func waitForSessionHandshakeEvent(
        _ expectedEvent: SessionHandshakeEvent,
        timeout: Duration
    ) async -> SessionHandshakeWaitOutcome {
        await withTaskGroup(of: SessionHandshakeRaceResult.self) { group in
            group.addTask { [transport] in
                do {
                    return .received(.success(
                        try await Self.receiveSessionHandshakeEvent(
                            expectedEvent,
                            from: transport
                        )
                    ))
                } catch {
                    return .received(.failure(error))
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }

            guard let first = await group.next() else {
                return SessionHandshakeWaitOutcome(
                    result: .failure(CancellationError()),
                    disconnectedTransport: false
                )
            }

            switch first {
            case let .received(result):
                group.cancelAll()
                return SessionHandshakeWaitOutcome(
                    result: result,
                    disconnectedTransport: false
                )

            case .timedOut:
                // Cancelling a generic transport receive is not guaranteed to
                // resume it. Closing the socket first makes the bounded wait
                // deterministic and lets the task group drain cleanly.
                group.cancelAll()
                await transport.disconnect()
                while await group.next() != nil {}
                let message = switch expectedEvent {
                case .created:
                    "The Realtime opening event timed out."
                case .updated:
                    "The Realtime session acknowledgement timed out."
                }
                return SessionHandshakeWaitOutcome(
                    result: .failure(clientError(
                        code: "network_timeout",
                        message: message
                    )),
                    disconnectedTransport: true
                )

            case .cancelled:
                group.cancelAll()
                await transport.disconnect()
                while await group.next() != nil {}
                return SessionHandshakeWaitOutcome(
                    result: .failure(CancellationError()),
                    disconnectedTransport: true
                )
            }
        }
    }

    private nonisolated static func receiveSessionHandshakeEvent(
        _ expectedEvent: SessionHandshakeEvent,
        from transport: any RealtimeWebSocketTransporting
    ) async throws -> String? {
        while true {
            let message = try await transport.receive()
            let decoded = try RealtimeEventDecoder.decode(try text(from: message))
            switch decoded {
            case let .sessionCreated(id) where expectedEvent == .created:
                return id
            case let .sessionUpdated(id) where expectedEvent == .updated:
                return id
            case let .error(error):
                throw error
            case .ignored:
                continue
            default:
                throw RealtimeServiceError.malformedServerEvent
            }
        }
    }

    private nonisolated static func text(
        from message: RealtimeWebSocketMessage
    ) throws -> String {
        try RealtimeWebSocketMessageValidator.validate(message)
        switch message {
        case let .text(text):
            return text
        case let .data(data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw RealtimeServiceError.unsupportedWebSocketMessage
            }
            return text
        }
    }

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                let message = try await transport.receive()
                let decoded = try RealtimeEventDecoder.decode(try text(from: message))
                try await handle(decoded)
            }
        } catch is CancellationError {
            // Normal disconnect.
        } catch {
            await handleTransportFailure(error)
        }
    }

    private func handle(_ event: DecodedRealtimeServerEvent) async throws {
        switch event {
        case let .sessionCreated(id):
            setState(.connected(sessionID: id))

        case let .sessionUpdated(id):
            if case let .connected(existingID) = state {
                setState(.connected(sessionID: id ?? existingID))
            }

        case let .responseCreated(id, requestID):
            try bindCreatedResponse(
                serverResponseID: id,
                clientRequestID: requestID
            )

        case let .audioDelta(data, itemID, responseID):
            // Cancellation can still leave already-buffered deltas in flight.
            // Once a challenge transition begins, discard them so old feedback
            // cannot restart local playback while the next clock is loading.
            guard let responseID,
                  let response = activeResponses.first(where: {
                      $0.serverResponseID == responseID
                  }),
                  isCurrent(response.challenge),
                  !suppressedOutputResponseIDs.contains(response.id),
                  !audioGenerationFinishedResponseIDs.contains(response.id),
                  !responseCancellationRequested else { return }
            if let audioPlayback {
                do {
                    try await audioPlayback.enqueuePCM16(
                        data,
                        itemID: itemID,
                        responseID: responseID
                    )
                    responsesWithAudioData.insert(response.id)
                    eventContinuation.yield(.assistantAudio(
                        data: data,
                        responseID: responseID
                    ))
                } catch {
                    eventContinuation.yield(.serverError(audioClientError(error)))
                }
            } else {
                eventContinuation.yield(.assistantAudio(
                    data: data,
                    responseID: responseID
                ))
            }

        case let .audioDone(responseID):
            guard let response = currentOpenResponse(
                serverResponseID: responseID
            ) else { return }
            guard audioGenerationFinishedResponseIDs.insert(response.id).inserted else {
                return
            }
            pendingPlaybackDrainResponseIDs.insert(responseID)
            if responsesWithAudioData.remove(response.id) != nil,
               case let .correctAnswerFeedback(questionID) = response.purpose {
                pendingCorrectFeedbackDrains[responseID] = CorrectFeedbackDrain(
                    questionID: questionID
                )
            }
            if let audioPlayback {
                await audioPlayback.notifyWhenPlaybackDrained(
                    responseID: responseID
                ) { [weak self] drainedResponseID in
                    Task {
                        await self?.handlePlaybackDrained(
                            responseID: drainedResponseID
                        )
                    }
                }
            } else {
                handlePlaybackDrained(responseID: responseID)
            }

        case let .transcriptDelta(speaker, text, responseID):
            guard !text.isEmpty,
                  shouldForwardTranscript(
                      speaker: speaker,
                      responseID: responseID
                  ) else { return }
            eventContinuation.yield(.transcriptDelta(speaker: speaker, text: text))

        case let .transcriptCompleted(speaker, text, responseID):
            guard shouldForwardTranscript(
                speaker: speaker,
                responseID: responseID
            ) else { return }
            eventContinuation.yield(.transcriptCompleted(speaker: speaker, text: text))

        case .speechStarted:
            suppressedOutputResponseIDs.formUnion(activeResponses.map(\.id))
            await stopPlaybackAndInvalidateDrains()
            eventContinuation.yield(.speechStarted)

        case .speechStopped:
            try trackAutomaticallyCreatedResponse()
            eventContinuation.yield(.speechStopped)

        case let .responseDone(responseID, requestID, functionCalls):
            let response = beginHandlingCompletedResponse(
                serverResponseID: responseID,
                clientRequestID: requestID
            )
            defer { finishHandling(response) }
            try await handle(
                functionCalls: functionCalls,
                challenge: response?.challenge
            )

        case let .responseFailed(responseID, requestID, error):
            let response = beginHandlingCompletedResponse(
                serverResponseID: responseID,
                clientRequestID: requestID
            )
            finishHandling(response)
            eventContinuation.yield(.serverError(error))

        case let .error(error):
            // Completion and cancellation can cross on the wire when the clock
            // advances after playback drains. Already-finished cancellation is
            // a harmless no-op. Still await response.done through the bounded
            // drain path; do not clear or rebind response tracking here.
            guard error.code != "response_cancel_not_active" else { return }
            eventContinuation.yield(.serverError(error))

        case .ignored:
            break
        }
    }

    private func handle(
        functionCalls: [RealtimeFunctionCall],
        challenge: ChallengeBinding?
    ) async throws {
        var shouldCreateResponse = false
        var responsePurpose = ResponsePurpose.general

        for call in functionCalls {
            switch call.name {
            case "report_clock_answer":
                let report: ClockAnswerReport
                do {
                    report = try RealtimeEventDecoder.clockAnswer(from: call.arguments)
                } catch {
                    report = ClockAnswerReport(hour: nil, minute: nil, unknown: true)
                }
                let gradedResult = await answerHandler.handle(
                    report: report,
                    challenge: challenge?.challenge
                )
                let wasCurrent = isCurrent(challenge)
                let result = wasCurrent
                    ? gradedResult
                    : ClockAnswerToolResult(
                        accepted: false,
                        correct: nil,
                        expectedHour: nil,
                        expectedMinute: nil
                    )
                try await transport.send(text: RealtimeEventEncoder.functionCallOutput(
                    callID: call.callID,
                    result: result
                ))
                guard isCurrent(challenge) else { continue }
                eventContinuation.yield(.clockAnswerReported(report, result))
                shouldCreateResponse = true
                if result.accepted, result.correct == true {
                    responsePurpose = .correctAnswerFeedback(
                        questionID: challenge?.challenge.questionID
                    )
                }

            case "wait_for_user":
                // Acknowledge the call so the conversation item is complete, but
                // intentionally do not create another response.
                try await transport.send(
                    text: RealtimeEventEncoder.waitForUserOutput(callID: call.callID)
                )

            default:
                break
            }
        }

        if shouldCreateResponse, let challenge, isCurrent(challenge) {
            // Register synchronously before sending. The UI may react to the
            // report immediately and request another challenge at the next
            // suspension point; it must then see and cancel this feedback turn.
            try await createResponse(
                for: challenge,
                purpose: responsePurpose,
                spokenFeedbackLanguage: challenge.challenge.language
            )
        }
    }

    private func isCurrent(_ binding: ChallengeBinding?) -> Bool {
        guard let binding, let currentChallenge else { return false }
        return binding.generation == challengeGeneration
            && currentChallenge.generation == binding.generation
    }

    private func currentOpenResponse(
        serverResponseID: String
    ) -> TrackedResponse? {
        guard !responseCancellationRequested,
              let response = activeResponses.first(where: {
                  $0.serverResponseID == serverResponseID
              }),
              isCurrent(response.challenge),
              !suppressedOutputResponseIDs.contains(response.id) else {
            return nil
        }
        return response
    }

    private func shouldForwardTranscript(
        speaker: RealtimeTranscriptSpeaker,
        responseID: String?
    ) -> Bool {
        guard speaker == .coach else { return true }
        guard let responseID else { return false }
        return currentOpenResponse(serverResponseID: responseID) != nil
    }

    private func createResponse(
        for challenge: ChallengeBinding?,
        purpose: ResponsePurpose = .general,
        spokenFeedbackLanguage: RealtimeCoachLanguage? = nil
    ) async throws {
        if let challenge, !isCurrent(challenge) { return }
        let requestID = "wl_\(UUID().uuidString)"
        let response = try trackResponse(
            for: challenge,
            clientRequestID: requestID,
            purpose: purpose
        )
        do {
            try await transport.send(
                text: RealtimeEventEncoder.responseCreate(requestID: requestID, spokenFeedbackLanguage: spokenFeedbackLanguage)
            )
        } catch {
            removeActiveResponse(id: response.id)
            throw error
        }
    }

    private func trackAutomaticallyCreatedResponse() throws {
        _ = try trackResponse(
            for: currentChallenge,
            clientRequestID: nil,
            purpose: .general
        )
    }

    @discardableResult
    private func trackResponse(
        for challenge: ChallengeBinding?,
        clientRequestID: String?,
        purpose: ResponsePurpose
    ) throws -> TrackedResponse {
        try reserveTrackedResponseCapacity()
        nextResponseID &+= 1
        let response = TrackedResponse(
            id: nextResponseID,
            clientRequestID: clientRequestID,
            serverResponseID: nil,
            challenge: challenge,
            purpose: purpose
        )
        activeResponses.append(response)
        return response
    }

    private func bindCreatedResponse(
        serverResponseID: String,
        clientRequestID: String?
    ) throws {
        guard !activeResponses.contains(where: {
            $0.serverResponseID == serverResponseID
        }) else { return }

        let index: Int?
        if let clientRequestID {
            index = activeResponses.firstIndex(where: {
                $0.clientRequestID == clientRequestID
                    && $0.serverResponseID == nil
            })
        } else {
            index = activeResponses.firstIndex(where: {
                $0.clientRequestID == nil
                    && $0.serverResponseID == nil
            })
        }

        if let index {
            activeResponses[index].serverResponseID = serverResponseID
        } else {
            try reserveTrackedResponseCapacity()
            nextResponseID &+= 1
            activeResponses.append(TrackedResponse(
                id: nextResponseID,
                clientRequestID: clientRequestID,
                serverResponseID: serverResponseID,
                challenge: nil,
                purpose: .general
            ))
        }
    }

    private func reserveTrackedResponseCapacity() throws {
        guard activeResponses.count < Self.maximumTrackedResponsesPerSession else {
            throw clientError(
                code: "response_tracking_limit_exceeded",
                message: "The Realtime response tracking limit was exceeded."
            )
        }
    }

    private func beginHandlingCompletedResponse(
        serverResponseID: String?,
        clientRequestID: String?
    ) -> TrackedResponse? {
        let response: TrackedResponse
        let matchedIndex = activeResponses.firstIndex(where: { tracked in
            if let serverResponseID {
                return tracked.serverResponseID == serverResponseID
            }
            if let clientRequestID {
                return tracked.clientRequestID == clientRequestID
            }
            return false
        })
        if let matchedIndex {
            response = activeResponses.remove(at: matchedIndex)
        } else {
            // An untracked completion has no trustworthy challenge identity.
            // Reject any tool report it carries instead of guessing that it
            // belongs to whichever clock happens to be current now.
            nextResponseID &+= 1
            response = TrackedResponse(
                id: nextResponseID,
                clientRequestID: clientRequestID,
                serverResponseID: serverResponseID,
                challenge: nil,
                purpose: .general
            )
        }
        suppressedOutputResponseIDs.remove(response.id)
        audioGenerationFinishedResponseIDs.remove(response.id)
        responsesWithAudioData.remove(response.id)
        handlingResponseIDs.insert(response.id)
        if activeResponses.isEmpty {
            responseCancellationRequested = false
        }
        return response
    }

    private func finishHandling(_ response: TrackedResponse?) {
        if let response {
            handlingResponseIDs.remove(response.id)
        }
    }

    private func removeActiveResponse(id: UInt64) {
        activeResponses.removeAll { $0.id == id }
        suppressedOutputResponseIDs.remove(id)
        audioGenerationFinishedResponseIDs.remove(id)
        responsesWithAudioData.remove(id)
        if activeResponses.isEmpty {
            responseCancellationRequested = false
        }
    }

    private func cancelAndDrainResponses() async throws {
        if !activeResponses.isEmpty, !responseCancellationRequested {
            responseCancellationRequested = true
            do {
                let responseID = activeResponses.first(where: {
                    $0.serverResponseID != nil
                })?.serverResponseID
                try await transport.send(
                    text: RealtimeEventEncoder.responseCancel(responseID: responseID)
                )
            } catch {
                responseCancellationRequested = false
                throw error
            }
        }
        guard hasOutstandingResponseWork else { return }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: responseDrainTimeout)
        while hasOutstandingResponseWork {
            guard clock.now < deadline else {
                clearResponseTracking()
                throw clientError(
                    code: "response_drain_timeout",
                    message: "The previous Realtime response did not stop in time."
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private var hasOutstandingResponseWork: Bool {
        !activeResponses.isEmpty || !handlingResponseIDs.isEmpty
    }

    private func clearResponseTracking() {
        activeResponses.removeAll()
        handlingResponseIDs.removeAll()
        suppressedOutputResponseIDs.removeAll()
        audioGenerationFinishedResponseIDs.removeAll()
        responsesWithAudioData.removeAll()
        pendingPlaybackDrainResponseIDs.removeAll()
        pendingCorrectFeedbackDrains.removeAll()
        responseCancellationRequested = false
    }

    private func sendAudioChunk(_ data: Data) async throws {
        guard case .connected = state else {
            throw RealtimeServiceError.notConnected
        }
        do {
            try await transport.send(text: RealtimeEventEncoder.appendAudio(data))
        } catch RealtimeEventEncodingError.invalidAudioChunk {
            throw RealtimeServiceError.invalidAudioChunk
        }
    }

    private func text(from message: RealtimeWebSocketMessage) throws -> String {
        try Self.text(from: message)
    }

    private func handleTransportFailure(_ error: Error) async {
        guard state != .disconnected,
              !terminalFailureInProgress,
              !disconnectInProgress else { return }
        terminalFailureInProgress = true
        eventContinuation.yield(.serverError(transportClientError(error)))
        await shutDownAfterTerminalFailure()
    }

    private func handleAudioCaptureFailure(_ error: RealtimeAudioEngineError) async {
        guard state != .disconnected,
              !terminalFailureInProgress,
              !disconnectInProgress else { return }
        terminalFailureInProgress = true
        eventContinuation.yield(.serverError(audioClientError(error)))
        await shutDownAfterTerminalFailure()
    }

    private func shutDownAfterTerminalFailure() async {
        receiveTask?.cancel()
        receiveTask = nil
        await stopVoice()
        await stopPlaybackAndInvalidateDrains()
        await transport.disconnect()
        currentChallenge = nil
        clearResponseTracking()
        setState(.disconnected)
    }

    private func setState(_ newState: RealtimeConnectionState) {
        guard state != newState else { return }
        state = newState
        eventContinuation.yield(.connectionStateChanged(newState))
    }

    private func handlePlaybackDrained(responseID: String) {
        guard pendingPlaybackDrainResponseIDs.remove(responseID) != nil else {
            return
        }
        let correctFeedback = pendingCorrectFeedbackDrains.removeValue(
            forKey: responseID
        )
        eventContinuation.yield(.assistantAudioFinished(responseID: responseID))
        if let correctFeedback {
            eventContinuation.yield(.spokenCorrectAnswerFeedbackFinished(
                responseID: responseID,
                questionID: correctFeedback.questionID
            ))
        }
    }

    private func stopPlaybackAndInvalidateDrains() async {
        pendingPlaybackDrainResponseIDs.removeAll()
        pendingCorrectFeedbackDrains.removeAll()
        if let audioPlayback {
            await audioPlayback.stopPlayback()
        }
    }

    private func clientError(code: String, message: String) -> RealtimeAPIError {
        RealtimeAPIError(
            type: "client_error",
            code: code,
            message: message,
            parameter: nil,
            eventID: nil
        )
    }

    private func audioClientError(_ error: Error) -> RealtimeAPIError {
        let code: String
        switch error as? RealtimeAudioEngineError {
        case .audioSessionConfigurationFailed:
            code = "audio_configuration_failed"
        case .audioSessionActivationFailed:
            code = "audio_activation_failed"
        case .audioEngineStartFailed:
            code = "audio_engine_start_failed"
        case .microphoneUnavailable:
            code = "audio_input_unavailable"
        case .invalidConverter:
            code = "audio_converter_invalid"
        case .invalidAudioFormat, .conversionFailed:
            code = "audio_format_invalid"
        case nil:
            code = "audio_playback_failed"
        }
        return clientError(
            code: code,
            message: "Realtime audio stopped."
        )
    }

    private func transportClientError(_ error: Error) -> RealtimeAPIError {
        if let apiError = error as? RealtimeAPIError {
            return apiError
        }
        let nsError = error as NSError
        let code: String
        if nsError.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: nsError.code) {
            case .timedOut:
                code = "network_timeout"
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .internationalRoamingOff, .dataNotAllowed:
                code = "network_offline"
            default:
                code = "transport_failed"
            }
        } else {
            code = "transport_failed"
        }
        return clientError(
            code: code,
            message: "The Realtime transport stopped unexpectedly."
        )
    }
}
