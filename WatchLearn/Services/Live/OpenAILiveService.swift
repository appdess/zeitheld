import Foundation

protocol VoiceCoachingService: Sendable {
    var events: AsyncStream<RealtimeServiceEvent> { get }
    func open(language: RealtimeCoachLanguage, safetyIdentifier: RealtimeSafetyIdentifier) async throws
    func setChallenge(_ challenge: ClockChallengeContext) async throws
    func startVoice(authorizedBy authorization: RealtimeAudioCaptureAuthorization) async throws
    func disconnect() async
}

extension OpenAIRealtimeService: VoiceCoachingService {
    func open(language: RealtimeCoachLanguage, safetyIdentifier: RealtimeSafetyIdentifier) async throws {
        try await connect(options: .init(language: language), safetyIdentifier: safetyIdentifier)
    }
    func setChallenge(_ challenge: ClockChallengeContext) async throws { try await updateChallenge(challenge) }
}

/// Released GPT-Live: continuous PCM in both directions with model-owned speech timing.
/// Responses delegation extracts answers; the app remains the grading authority.
/// No VAD, audio commit, or voice response.create is involved.
actor OpenAILiveService: VoiceCoachingService {
    nonisolated let events: AsyncStream<RealtimeServiceEvent>
    private let continuation: AsyncStream<RealtimeServiceEvent>.Continuation
    private let apiKey: String
    private let transport: any RealtimeWebSocketTransporting
    private let capture: (any RealtimeAudioCapturing)?
    private let playback: (any RealtimeAudioPlaying)?
    private let answerHandler: any ClockAnswerToolHandling
    private let handshakeTimeout: Duration
    private var generation: UInt64 = 0
    private var connecting = false
    private var connected = false
    private var closing = false
    private var handshake: CheckedContinuation<Void, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var input: AsyncStream<Data>.Continuation?
    private var delegations: [String: Task<Void, Never>] = [:]
    private var seenDelegations: Set<String> = []
    private var challenge: ClockChallengeContext?
    private var challengeRevision: UInt64 = 0
    private var outputSequence: UInt64 = 0
    private var advanceGate = LiveExerciseAdvanceGate()
    private var advanceTask: Task<Void, Never>?
    private var audibleBuffers: Set<String> = []
    private var solvedQuestionID: Int?
    private struct BackendWork {
        let challenge: ClockChallengeContext?
        let revision: UInt64
        var calls: [RealtimeFunctionCall] = []
    }
    private var backendWork: [String: BackendWork] = [:]
    private var delegationResponses: [String: String] = [:]
    private var closeWaiter: CheckedContinuation<Void, Never>?
    private(set) var finalUsageSeconds: Double?


    init(apiKey: String,
         transport: any RealtimeWebSocketTransporting = URLSessionRealtimeWebSocketTransport(),
         audioCapture: (any RealtimeAudioCapturing)? = nil,
         audioPlayback: (any RealtimeAudioPlaying)? = nil,
         answerHandler: any ClockAnswerToolHandling = DeterministicClockAnswerHandler(),
         handshakeTimeout: Duration = .seconds(10)) {
        self.apiKey = apiKey
        self.transport = transport
        capture = audioCapture; playback = audioPlayback
        self.answerHandler = answerHandler; self.handshakeTimeout = handshakeTimeout
        let pair = AsyncStream.makeStream(of: RealtimeServiceEvent.self, bufferingPolicy: .bufferingNewest(200))
        events = pair.stream; continuation = pair.continuation
    }

    deinit {
        advanceTask?.cancel()
        timeoutTask?.cancel(); receiveTask?.cancel(); sendTask?.cancel()
        for task in delegations.values { task.cancel() }
        input?.finish(); continuation.finish()
        handshake?.resume(throwing: CancellationError())
    }

    func open(language: RealtimeCoachLanguage, safetyIdentifier: RealtimeSafetyIdentifier) async throws {
        try Task.checkCancellation()
        guard !connected, !connecting, !closing else { throw RealtimeServiceError.alreadyConnected }
        guard apiKey.hasPrefix("sk-"), (20...512).contains(apiKey.utf8.count),
              apiKey.utf8.allSatisfy({ (45...57).contains($0) && $0 != 46 && $0 != 47 || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }) else {
            throw LiveServiceError.invalidCredential
        }
        connecting = true; finalUsageSeconds = nil; generation &+= 1
        let current = generation
        continuation.yield(.connectionStateChanged(.connecting))
        var request = URLRequest(url: LiveConstants.webSocketURL)
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(safetyIdentifier.headerValue, forHTTPHeaderField: "OpenAI-Safety-Identifier")
        let startEvent = try LiveEventCodec.sessionStart(language: language)
        do {
            try await transport.connect(request: request)
            try ensureCurrent(current)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                    handshake = waiter
                    timeoutTask = Task { [weak self, handshakeTimeout] in
                        do { try await Task.sleep(for: handshakeTimeout) } catch { return }
                        await self?.fail(LiveServiceError.handshakeTimeout, generation: current)
                    }
                    receiveTask = Task { [weak self, transport] in
                        do {
                            try await transport.send(text: startEvent)
                            while !Task.isCancelled {
                                let event = try LiveEventCodec.decode(await transport.receive())
                                guard let self else { return }
                                try await self.handle(event, generation: current)
                            }
                        } catch { await self?.fail(error, generation: current) }
                    }
                }
            } onCancel: { Task { await self.fail(CancellationError(), generation: current) } }
            try Task.checkCancellation()
            try ensureCurrent(current)
        } catch {
            await fail(error, generation: current)
            throw error
        }
    }

    func setChallenge(_ newChallenge: ClockChallengeContext) async throws {
        guard connected else { throw RealtimeServiceError.notConnected }
        guard let id = newChallenge.questionID,
              (0...23).contains(newChallenge.hour), (0...59).contains(newChallenge.minute) else {
            throw RealtimeServiceError.invalidChallenge
        }
        let current = generation
        let firstInSession = challenge == nil
        challengeRevision &+= 1
        advanceTask?.cancel(); advanceTask = nil; advanceGate.cancel(); solvedQuestionID = nil
        challenge = nil
        let revision = challengeRevision
        // Clock data is trusted app context. Images and Realtime conversation
        // items are not part of the verified native text-context contract.
        let text = LiveClockCoachPrompt.challengeInstructions(newChallenge, firstInSession: firstInSession)
        try await transport.send(text: LiveEventCodec.backendContext(questionID: id))
        try ensureCurrent(current)
        guard revision == challengeRevision else { throw CancellationError() }
        for event in try LiveEventCodec.context(text, instructions: true) {
            try await transport.send(text: event)
            try ensureCurrent(current)
            guard revision == challengeRevision else { throw CancellationError() }
        }
        challenge = newChallenge
    }

    func startVoice(authorizedBy authorization: RealtimeAudioCaptureAuthorization) async throws {
        guard connected else { throw RealtimeServiceError.notConnected }
        guard let capture else { throw RealtimeServiceError.audioUnavailable }
        guard sendTask == nil else { return }
        let current = generation
        let pair = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingOldest(50))
        input = pair.continuation
        sendTask = Task { [weak self, transport] in
            do {
                for await data in pair.stream {
                    try Task.checkCancellation()
                    try await transport.send(text: LiveEventCodec.appendAudio(data))
                }
            } catch { await self?.fail(error, generation: current) }
        }
        do {
            try await capture.startCapture(authorizedBy: authorization, onPCM16Chunk: { [weak self] data in
                if case .dropped = pair.continuation.yield(data) {
                    Task { await self?.fail(LiveServiceError.audioBackpressure, generation: current) }
                }
            }, onCaptureFailure: { [weak self] error in
                Task { await self?.fail(error, generation: current) }
            })
            try ensureCurrent(current)
            try Task.checkCancellation()
            for event in try LiveEventCodec.context(LiveClockCoachPrompt.voiceReady(language: challenge?.language ?? .german), instructions: true) {
                try await transport.send(text: event)
                try ensureCurrent(current)
            }
        } catch {
            await fail(error, generation: current)
            throw error
        }
    }

    func disconnect() async {
        guard !closing, connecting || connected else { return }
        let wasConnected = connected
        closing = true; connecting = false; connected = false
        advanceTask?.cancel(); advanceTask = nil; advanceGate.cancel(); audibleBuffers.removeAll()
        timeoutTask?.cancel(); timeoutTask = nil
        input?.finish(); input = nil; sendTask?.cancel(); sendTask = nil
        for task in delegations.values { task.cancel() }
        delegations.removeAll(); seenDelegations.removeAll()
        backendWork.removeAll(); delegationResponses.removeAll()
        let pending = handshake; handshake = nil
        pending?.resume(throwing: CancellationError())
        challenge = nil; challengeRevision &+= 1
        // Privacy and the Stop button take effect before network finalization.
        await capture?.stopCapture(); await playback?.stopPlayback()
        if wasConnected && finalUsageSeconds == nil {
            await withCheckedContinuation { waiter in
                closeWaiter = waiter
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    await self?.finishClose()
                }
                sendTask = Task { [weak self, transport] in
                    do { try await transport.send(text: LiveEventCodec.encode(["type": "session.close"])) }
                    catch { await self?.finishClose() }
                }
            }
        }
        timeoutTask?.cancel(); timeoutTask = nil
        sendTask?.cancel(); sendTask = nil
        receiveTask?.cancel(); receiveTask = nil
        await transport.disconnect()
        generation &+= 1; closing = false
        continuation.yield(.connectionStateChanged(.disconnected))
    }

    private func finishClose() {
        let waiter = closeWaiter; closeWaiter = nil
        waiter?.resume()
    }

    private func ensureCurrent(_ current: UInt64) throws {
        guard generation == current, !closing, connecting || connected else { throw CancellationError() }
    }

    private func handle(_ event: DecodedLiveEvent, generation current: UInt64) async throws {
        guard generation == current else { throw CancellationError() }
        if case .closed(let seconds) = event {
            finalUsageSeconds = seconds
            if closing { finishClose() }
            else { await disconnect() }
            return
        }
        if closing { return }
        try ensureCurrent(current)
        if case .error(let error) = event { throw Self.classify(error) }
        if case .started = event {
            guard connecting else { return }
            connecting = false; connected = true
            timeoutTask?.cancel(); timeoutTask = nil
            let pending = handshake; handshake = nil
            continuation.yield(.connectionStateChanged(.connected(sessionID: nil)))
            pending?.resume()
            return
        }
        guard connected else { return }
        switch event {
        case .audio(let data):
            // These IDs identify local buffers, not provider voice turns. Release
            // each after actual playback; Live has no audio-done event.
            outputSequence &+= 1
            let id = "live-buffer-\(current)-\(outputSequence)"
            let audible = LiveAudioActivity.hasAudibleSamples(data)
            if audible, playback != nil { audibleBuffers.insert(id) }
            try await playback?.enqueuePCM16(data, itemID: nil, responseID: id)
            try ensureCurrent(current)
            if audible {
                continuation.yield(.assistantAudio(data: data, responseID: id))
            }
            if let playback {
                await playback.notifyWhenPlaybackDrained(responseID: id) { [weak self] drained in
                    Task { await self?.didDrain(drained, generation: current) }
                }
            } else { didDrain(id, generation: current) }
        case .transcript(let speaker, let text):
            continuation.yield(.transcriptDelta(speaker: speaker, text: text))
        case .backendStarted(let id, let delegationID):
            guard backendWork[id] == nil, !seenDelegations.contains(id) else { return }
            guard backendWork.count < 8, delegationResponses.count < 1024 else { throw LiveServiceError.delegationLimit }
            backendWork[id] = BackendWork(challenge: challenge, revision: challengeRevision)
            delegationResponses[delegationID] = id
        case .functionCall(let call, let delegationID):
            guard let id = delegationResponses[delegationID] else { throw LiveServiceError.invalidEvent }
            if seenDelegations.contains(id) { return }
            guard var work = backendWork[id] else { throw LiveServiceError.invalidEvent }
            guard !work.calls.contains(where: { $0.callID == call.callID }) else { return }
            guard work.calls.count < 8 else { throw LiveServiceError.delegationLimit }
            work.calls.append(call); backendWork[id] = work
        case .backendCompleted(let id):
            guard let work = backendWork.removeValue(forKey: id), !seenDelegations.contains(id) else { return }
            guard seenDelegations.count < 1024, delegations.count < 8 else { throw LiveServiceError.delegationLimit }
            seenDelegations.insert(id)
            guard !work.calls.isEmpty else { return }
            delegations[id] = Task { [weak self] in
                await self?.completeBackend(id: id, work: work, generation: current)
            }
        default: break
        }
    }

    private func completeBackend(id: String, work: BackendWork, generation current: UInt64) async {
        defer { delegations.removeValue(forKey: id) }
        do {
            for call in work.calls {
                try Task.checkCancellation(); try ensureCurrent(current)
                var output = "No grade: invalid or outdated clock answer. Ask gently for clarification."
                var accepted: (ClockAnswerReport, ClockAnswerToolResult, Int)?
                if call.name == "report_clock_answer",
                   let parsed = try? JSONDecoder().decode(LiveClockAnswerDelegation.self, from: Data(call.arguments.utf8)),
                   let report = parsed.report, let challenge = work.challenge,
                   solvedQuestionID != parsed.question_id,
                   parsed.question_id == challenge.questionID, work.revision == challengeRevision {
                    let result = await answerHandler.handle(report: report, challenge: challenge)
                    try Task.checkCancellation(); try ensureCurrent(current)
                    if work.revision == challengeRevision {
                        output = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
                        accepted = (report, result, parsed.question_id)
                    } else { output = "No grade: the displayed clock changed. Use the current clock." }
                }
                try await transport.send(text: LiveEventCodec.functionOutput(callID: call.callID, output: output))
                try ensureCurrent(current)
                if let (report, result, questionID) = accepted, work.revision == challengeRevision {
                    if result.accepted, result.correct == true {
                        solvedQuestionID = questionID
                        armAdvance(questionID: questionID, generation: current)
                    }
                    continuation.yield(.liveClockAnswerReported(report, result, questionID: questionID))
                }
            }
            // This continues ONLY delegated backend work, never a spoken turn.
            try ensureCurrent(current)
            try await transport.send(text: LiveEventCodec.encode(["type": "response.create"]))
        } catch { await fail(error, generation: current) }
    }

    private func didDrain(_ id: String, generation current: UInt64) {
        guard generation == current, connected else { return }
        if audibleBuffers.remove(id) != nil {
            advanceGate.observeAudibleOutput(at: ProcessInfo.processInfo.systemUptime)
        }
        continuation.yield(.assistantAudioFinished(responseID: id))
    }

    private func armAdvance(questionID: Int, generation current: UInt64) {
        advanceTask?.cancel()
        advanceGate.arm(questionID: questionID, at: ProcessInfo.processInfo.systemUptime)
        advanceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self, await self.checkAdvance(generation: current) else { return }
            }
        }
    }

    private func checkAdvance(generation current: UInt64) -> Bool {
        guard connected, generation == current, advanceGate.questionID != nil else { return false }
        guard audibleBuffers.isEmpty else { return true }
        if let questionID = advanceGate.takeReadyQuestion(at: ProcessInfo.processInfo.systemUptime),
           challenge?.questionID == questionID {
            continuation.yield(.liveAdvanceRequested(questionID: questionID))
            return false
        }
        return true
    }

    private func fail(_ error: any Error, generation current: UInt64) async {
        if generation == current, closing { finishClose(); return }
        guard generation == current, connecting || connected else { return }
        let mapped = (error as? RealtimeAPIError).map(Self.classify) ?? error
        let pending = handshake; handshake = nil
        if !(mapped is CancellationError) {
            let code = switch mapped {
            case LiveServiceError.accessDenied: "live_access_denied"
            case LiveServiceError.handshakeTimeout: "network_timeout"
            case let urlError as URLError:
                VoiceCoachFailure(error: urlError).code == .networkTimeout ? "network_timeout"
                    : VoiceCoachFailure(error: urlError).code == .networkOffline ? "network_offline" : "live_session_failed"
            case RealtimeWebSocketTransportError.disconnected: "connection_lost"
            case is RealtimeAudioEngineError: "audio_engine_start_failed"
            default: (mapped as? RealtimeAPIError)?.code ?? "live_session_failed"
            }
            continuation.yield(.serverError(.init(type: nil, code: code, message: "Native Live session failed.", parameter: nil, eventID: nil)))
        }
        await disconnect()
        pending?.resume(throwing: mapped)
    }

    private static func classify(_ error: RealtimeAPIError) -> any Error {
        if ["forbidden", "permission_denied", "access_denied"].contains(error.code ?? "") { return LiveServiceError.accessDenied }
        return error
    }
}
