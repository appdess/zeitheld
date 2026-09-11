@preconcurrency import WebRTC
@preconcurrency import AVFoundation
import Foundation

/// Direct WebRTC media. Our server authorizes sessions, bounds delegated work,
/// and owns durable expiry; no microphone audio is relayed through Cloud Run.
@MainActor
final class ManagedLiveSession: NSObject, VoiceCoachingService, VoiceCoachAudioManaging {
    nonisolated let events: AsyncStream<RealtimeServiceEvent>
    private let continuation: AsyncStream<RealtimeServiceEvent>.Continuation
    private let baseURL: URL
    private let token: String
    private let factory: RTCPeerConnectionFactory
    private let authorization = RealtimeAudioCaptureAuthorizationState()
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var microphone: RTCAudioTrack?
    private var remoteTracks: [RTCAudioTrack] = []
    private var localSessionID: String?
    private var ready = false
    private var sentVoiceReady = false
    private var ownsAudioActivation = false
    private var closing = false
    private var disconnectTask: Task<Void, Never>?
    private var challenge: ClockChallengeContext?
    private var revision: UInt64 = 0
    private var transcript = ""
    private var lastTranscriptAt = Date.distantPast
    var diagnostics: ((String) -> Void)?
    private var pendingDelegations: [(String, UInt64)] = []
    private var connectionGeneration: UInt64 = 0
    private var handledDelegations: Set<String> = []
    private var delegationTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var audioActivityTask: Task<Void, Never>?
    private var inboundActivity = LiveInboundAudioActivity()
    private var advanceGate = LiveExerciseAdvanceGate()
    private var solvedQuestionID: Int?
    private var lastAudibleOutputAt: TimeInterval?
    private var presentingSpeech = false
    private var interruptionHandler: (@Sendable (Bool) -> Void)?
    private var interruptionObserver: NSObjectProtocol?

    init(baseURL: URL, token: String, factory: RTCPeerConnectionFactory = RTCPeerConnectionFactory()) {
        self.factory = factory
        self.baseURL = baseURL; self.token = token
        let stream = AsyncStream.makeStream(of: RealtimeServiceEvent.self, bufferingPolicy: .bufferingNewest(200))
        events = stream.stream; continuation = stream.continuation
        super.init()
    }

    func open(language: RealtimeCoachLanguage, safetyIdentifier: RealtimeSafetyIdentifier) async throws {
        guard peer == nil, !closing else { throw RealtimeServiceError.alreadyConnected }
        connectionGeneration &+= 1
        let generation = connectionGeneration
        continuation.yield(.connectionStateChanged(.connecting))
        let audio = RTCAudioSession.sharedInstance()
        // WebRTC reapplies this configuration when its audio unit starts.
        // Setting AVAudioSession alone is overwritten with receiver routing.
        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.categoryOptions.insert(.defaultToSpeaker)
        RTCAudioSessionConfiguration.setWebRTC(configuration)
        audio.useManualAudio = true
        audio.isAudioEnabled = false
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherOnce
        guard let peer = factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else { throw ManagedAccountError.unavailable }
        self.peer = peer
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let track = factory.audioTrack(with: source, trackId: "zeitheld-microphone")
        track.isEnabled = false; microphone = track
        peer.add(track, streamIds: ["zeitheld-audio"])
        let dataConfig = RTCDataChannelConfiguration()
        dataConfig.isOrdered = true
        var createdSessionID: String?
        var setupStage = "data-channel"
        do {
            guard let channel = peer.dataChannel(forLabel: "oai-events", configuration: dataConfig) else { throw ManagedAccountError.unavailable }
            self.channel = channel; channel.delegate = self
            setupStage = "offer"
            let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { waiter in
                peer.offer(for: RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil)) { value, error in
                    if let value { waiter.resume(returning: value) } else { waiter.resume(throwing: error ?? ManagedAccountError.unavailable) }
                }
            }
            try requireCurrentConnection(peer, generation: generation)
            setupStage = "local-description"
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                peer.setLocalDescription(offer) { error in
                    if let error { waiter.resume(throwing: error) } else { waiter.resume() }
                }
            }
            try requireCurrentConnection(peer, generation: generation)
            setupStage = "ice-gathering"
            let iceDeadline = Date().addingTimeInterval(8)
            while peer.iceGatheringState != .complete && Date() < iceDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
            try requireCurrentConnection(peer, generation: generation)
            guard peer.iceGatheringState == .complete,
                  let sdp = peer.localDescription?.sdp else { throw ManagedAccountError.unavailable }
            setupStage = "session-request"
            let data = try await request("v1/sessions", body: ["language": language == .english ? "en" : "de", "sdp": sdp])
            setupStage = "session-response"
            // Retain the cleanup handle even if another response field is malformed.
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = object["id"] as? String, UUID(uuidString: id) != nil {
                createdSessionID = id
                if generation == connectionGeneration, self.peer === peer, !closing {
                    localSessionID = id
                }
            }
            try requireCurrentConnection(peer, generation: generation)
            let session = try JSONDecoder().decode(SessionOffer.self, from: data)
            guard createdSessionID == session.id else { throw ManagedAccountError.unavailable }
            localSessionID = session.id
            try Task.checkCancellation()
            setupStage = "remote-description"
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: session.sdp)) { error in
                    if let error { waiter.resume(throwing: error) } else { waiter.resume() }
                }
            }
            try requireCurrentConnection(peer, generation: generation)
            setupStage = "session-started"
            let deadline = Date().addingTimeInterval(15)
            while !ready && Date() < deadline && generation == connectionGeneration && self.peer === peer && !closing {
                try await Task.sleep(for: .milliseconds(50))
            }
            try requireCurrentConnection(peer, generation: generation)
            guard ready else { throw LiveServiceError.handshakeTimeout }
            expiryTask = Task { [weak self] in
                let seconds = max(1, session.expiresAt / 1000 - Date().timeIntervalSince1970)
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                await self?.disconnect()
            }
        } catch {
            let failure = error as NSError
            diagnostics?("setup_failed stage=\(setupStage) domain=\(failure.domain) code=\(failure.code)")
            if case let DecodingError.keyNotFound(key, _) = error {
                diagnostics?("response_missing_field=\(key.stringValue)")
            }
            if generation == connectionGeneration, self.peer === peer {
                await disconnect()
            } else if let id = createdSessionID {
                // A late startup response owns only its original server session.
                // It must not overwrite or disconnect a newer connection.
                _ = try? await Task { try await self.request("v1/sessions/\(id)/close", body: [:]) }.value
            }
            throw error
        }
    }

    private func requireCurrentConnection(_ peer: RTCPeerConnection, generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == connectionGeneration, self.peer === peer, !closing else { throw CancellationError() }
    }

    func setChallenge(_ value: ClockChallengeContext) async throws {
        guard ready, let questionID = value.questionID else { throw RealtimeServiceError.notConnected }
        let firstInSession = challenge == nil
        revision &+= 1; challenge = value; transcript = ""; pendingDelegations.removeAll()
        advanceGate.cancel(); solvedQuestionID = nil
        delegationTask?.cancel(); delegationTask = nil
        let text = LiveClockCoachPrompt.challengeInstructions(value, firstInSession: firstInSession)
        for event in try LiveEventCodec.context(text, instructions: true) { try send(event) }
    }

    func startVoice(authorizedBy value: RealtimeAudioCaptureAuthorization) async throws {
        try authorization.validate(value)
        guard ready else { throw RealtimeServiceError.notConnected }
        let audio = RTCAudioSession.sharedInstance()
        do {
            audio.lockForConfiguration()
            defer { audio.unlockForConfiguration() }
            try audio.setCategory(AVAudioSession.Category.playAndRecord, with: [.defaultToSpeaker, .allowBluetooth])
            try audio.setMode(AVAudioSession.Mode.voiceChat)
            try audio.setActive(true)
            ownsAudioActivation = true
        }
        // Enabling tracks can synchronously wait for WebRTC's audio worker.
        // That worker also takes the configuration lock; release it first.
        try authorization.validate(value)
        audio.isAudioEnabled = true
        microphone?.isEnabled = true
        remoteTracks.forEach { $0.isEnabled = true }
        startObservingAudioActivity()
        if !sentVoiceReady {
            for event in try LiveEventCodec.context(LiveClockCoachPrompt.voiceReady(language: challenge?.language ?? .german), instructions: true) {
                try send(event)
            }
            sentVoiceReady = true
        }
    }

    func disconnect() async {
        if let disconnectTask { await disconnectTask.value; return }
        // An unstructured task does not inherit the caller's cancellation.
        // URLSession must still send close when Stop/background cancels startup.
        let task = Task { @MainActor in await self.performDisconnect() }
        disconnectTask = task
        await task.value
        disconnectTask = nil
    }

    private func performDisconnect() async {
        closing = true; ready = false; connectionGeneration &+= 1; revision &+= 1
        pendingDelegations.removeAll()
        stopAll(); expiryTask?.cancel(); delegationTask?.cancel()
        // Stop capture/playback immediately. Keep transport alive while the server
        // closes Live and collects authoritative final usage.
        if let id = localSessionID { _ = try? await request("v1/sessions/\(id)/close", body: [:]) }
        channel?.close(); channel = nil
        peer?.close(); peer = nil
        if ownsAudioActivation {
            let audio = RTCAudioSession.sharedInstance()
            audio.lockForConfiguration()
            defer { audio.unlockForConfiguration() }
            try? audio.setActive(false)
            ownsAudioActivation = false
        }
        localSessionID = nil; microphone = nil; remoteTracks.removeAll()
        challenge = nil; transcript = ""; handledDelegations.removeAll(); sentVoiceReady = false
        closing = false
        continuation.yield(.connectionStateChanged(.disconnected))
    }

    func authorizeCaptureStart() -> RealtimeAudioCaptureAuthorization { authorization.issue() }
    func startCapture(authorizedBy value: RealtimeAudioCaptureAuthorization, onPCM16Chunk: @escaping @Sendable (Data) -> Void, onCaptureFailure: @escaping @Sendable (RealtimeAudioEngineError) -> Void) async throws { try await startVoice(authorizedBy: value) }
    func stopCapture() { authorization.revoke(); microphone?.isEnabled = false }
    func stopPlayback() { remoteTracks.forEach { $0.isEnabled = false }; RTCAudioSession.sharedInstance().isAudioEnabled = false }
    func stopAll() {
        audioActivityTask?.cancel(); audioActivityTask = nil
        advanceGate.cancel(); inboundActivity = LiveInboundAudioActivity()
        lastAudibleOutputAt = nil; presentingSpeech = false
        stopCapture(); stopPlayback()
    }
    func enqueuePCM16(_ data: Data, itemID: String?, responseID: String) throws { /* WebRTC owns playback. */ }
    func notifyWhenPlaybackDrained(responseID: String, onDrained: @escaping @Sendable (String) -> Void) { }
    func setInterruptionHandler(_ handler: (@Sendable (Bool) -> Void)?) {
        interruptionHandler = handler
        if let observer = interruptionObserver { NotificationCenter.default.removeObserver(observer) }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stopAll(); self?.interruptionHandler?(true) }
        }
    }

    private func receive(_ data: Data) {
        guard data.count < 1000000,
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        switch type {
        case "session.started":
            ready = true; continuation.yield(.connectionStateChanged(.connected(sessionID: nil)))
        case "session.closed":
            Task { await disconnect() }
        case "error":
            continuation.yield(.serverError(.init(type: nil, code: "live_session_failed", message: "Live failed", parameter: nil, eventID: nil)))
            Task { await disconnect() }
        case "session.input_transcript.delta", "session.output_transcript.delta":
            guard let delta = event["delta"] as? String, delta.utf8.count <= 10000 else { return }
            let child = type == "session.input_transcript.delta"
            if child { transcript = String((transcript + delta).suffix(3000)); lastTranscriptAt = Date() }
            continuation.yield(.transcriptDelta(speaker: child ? .child : .coach, text: delta))
        case "session.delegation.created":
            guard let delegation = event["delegation"] as? [String: Any], delegation["target"] as? String == "client",
                  let id = delegation["id"] as? String, id.count < 256,
                  handledDelegations.count < 120, handledDelegations.insert(id).inserted else { return }
            pendingDelegations.append((id, revision))
            if delegationTask == nil {
                let taskRevision = revision
                delegationTask = Task { [weak self] in
                    guard let self else { return }
                    while !self.pendingDelegations.isEmpty, !Task.isCancelled {
                        let next = self.pendingDelegations.removeFirst()
                        await self.delegate(id: next.0, revision: next.1)
                    }
                    if self.revision == taskRevision { self.delegationTask = nil }
                }
            }
        default: break
        }
    }

    private func delegate(id: String, revision captured: UInt64) async {
        guard let sessionID = localSessionID, let challenge, let questionID = challenge.questionID else { return }
        do {
            guard solvedQuestionID != questionID else {
                for event in try LiveEventCodec.context("This clock is already solved. Pause for the next NEW_CLOCK_CHALLENGE; no further grade or tap is needed.", delegationID: id) { try send(event) }
                return
            }
            // Live delegates before its asynchronous transcript necessarily finishes.
            // Keep the duplex audio running while collecting a stable text snapshot
            // for grading; never commit, stop, or restart microphone audio here.
            let started = Date()
            while Date().timeIntervalSince(started) < 3 {
                try await Task.sleep(for: .milliseconds(50))
                guard revision == captured else { return }
                if !transcript.isEmpty && Date().timeIntervalSince(lastTranscriptAt) >= 0.6
                    && Date().timeIntervalSince(started) >= 1 { break }
            }
            guard revision == captured else { return }
            let text = transcript
            diagnostics?("delegation chars=\(text.count) question=\(questionID)")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                for event in try LiveEventCodec.context("No new attempted answer. Give one short clock hint if asked, then wait and listen.", delegationID: id) { try send(event) }
                return
            }
            transcript = "" // Consume fresh speech once; later hints cannot regrade an old answer.
            let data = try await request("v1/sessions/\(sessionID)/answer", body: ["transcript": text, "questionID": questionID, "delegationID": id])
            try Task.checkCancellation()
            guard captured == revision, ready else { return }
            let answer = try JSONDecoder().decode(ExtractedAnswer.self, from: data)
            diagnostics?("extracted attempt=\(answer.attempt) unknown=\(answer.unknown) question=\(questionID)")
            guard answer.questionID == questionID else { return }
            if !answer.attempt {
                for event in try LiveEventCodec.context("This was not a clock answer. Help briefly with the clock question, without grading or awarding a star.", delegationID: id) { try send(event) }
                return
            }
            let report = ClockAnswerReport(hour: answer.hour, minute: answer.minute, unknown: answer.unknown)
            let result = await DeterministicClockAnswerHandler().handle(report: report, challenge: challenge)
            guard captured == revision, ready else { return }
            let output: String
            if result.correct == true {
                output = "App grade for question \(questionID): correct. Give one short, warm sentence of praise, then pause. The app will show the next clock automatically after your feedback. Do not ask the child to tap Next. Wait for NEW_CLOCK_CHALLENGE before describing another clock. This grading task is complete."
            } else {
                output = "App grade for question \(questionID): not correct yet. No star was awarded. Give one gentle hint about the hands and invite another attempt. This grading task is complete. Delegate the next attempted answer again."
            }
            for event in try LiveEventCodec.context(output, delegationID: id) { try send(event) }
            if result.accepted, result.correct == true {
                solvedQuestionID = questionID
                advanceGate.arm(questionID: questionID, at: ProcessInfo.processInfo.systemUptime)
            }
            continuation.yield(.liveClockAnswerReported(report, result, questionID: questionID))
        } catch {
            guard !Task.isCancelled, captured == revision, ready else { return }
            for event in (try? LiveEventCodec.context("The answer checker is unavailable. Do not grade. Invite the child to use the answer buttons.", delegationID: id)) ?? [] { try? send(event) }
        }
    }

    private func startObservingAudioActivity() {
        guard audioActivityTask == nil, let peer else { return }
        let generation = connectionGeneration
        audioActivityTask = Task { [weak self, weak peer] in
            while !Task.isCancelled {
                guard let peer else { return }
                let sample: (Double, Double)? = await withCheckedContinuation { waiter in
                    peer.statistics { report in
                        let audio = report.statistics.values.first {
                            $0.type == "inbound-rtp" && ($0.values["kind"] as? String == "audio"
                                || $0.values["mediaType"] as? String == "audio")
                        }
                        guard let energy = audio?.values["totalAudioEnergy"] as? NSNumber,
                              let duration = audio?.values["totalSamplesDuration"] as? NSNumber else {
                            waiter.resume(returning: nil); return
                        }
                        waiter.resume(returning: (energy.doubleValue, duration.doubleValue))
                    }
                }
                guard !Task.isCancelled, let self, self.connectionGeneration == generation,
                      self.ready else { return }
                if let sample, let audible = self.inboundActivity.observe(energy: sample.0, duration: sample.1) {
                    let now = ProcessInfo.processInfo.systemUptime
                    if audible {
                        self.lastAudibleOutputAt = now
                        self.advanceGate.observeAudibleOutput(at: now)
                        if !self.presentingSpeech {
                            self.presentingSpeech = true
                            self.continuation.yield(.assistantAudio(data: Data(), responseID: "live-media"))
                        }
                    } else if let last = self.lastAudibleOutputAt, now - last >= 0.6, self.presentingSpeech {
                        self.presentingSpeech = false
                        self.continuation.yield(.assistantAudioFinished(responseID: "live-media"))
                    }
                    if let questionID = self.advanceGate.takeReadyQuestion(at: now),
                       self.challenge?.questionID == questionID {
                        self.continuation.yield(.liveAdvanceRequested(questionID: questionID))
                    }
                }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
    }
    private func send(_ text: String) throws {
        guard ready, let channel, channel.readyState == .open,
              channel.sendData(RTCDataBuffer(data: Data(text.utf8), isBinary: false)) else { throw RealtimeServiceError.notConnected }
    }
    private func request(_ path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw ManagedAccountError.malformedResponse }
        guard status == 200 else { throw ManagedAccountError.responseError(status: status, data: data) }
        return data
    }
    private struct SessionOffer: Decodable { let id: String; let sdp: String; let expiresAt: Double; let unlimited: Bool }
    private struct ExtractedAnswer: Decodable { let questionID: Int; let attempt: Bool; let hour: Int?; let minute: Int?; let unknown: Bool }
}

extension ManagedLiveSession: RTCDataChannelDelegate, RTCPeerConnectionDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        let identity = ObjectIdentifier(dataChannel)
        Task { @MainActor [weak self] in
            guard let self, let current = self.channel, ObjectIdentifier(current) == identity, !self.closing else { return }
            self.receive(data)
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        let tracks = stream.audioTracks
        let identity = ObjectIdentifier(peerConnection)
        Task { @MainActor [weak self] in
            guard let self, let current = self.peer, ObjectIdentifier(current) == identity, !self.closing else { return }
            self.remoteTracks.append(contentsOf: tracks)
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed {
            let identity = ObjectIdentifier(peerConnection)
            Task { @MainActor [weak self] in
                guard let self, let current = self.peer, ObjectIdentifier(current) == identity, !self.closing else { return }
                await self.disconnect()
            }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
