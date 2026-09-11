@preconcurrency import AVFoundation
import Foundation

struct RealtimeAudioCaptureAuthorization: Equatable, Sendable {
    fileprivate let ownerID: UUID
    fileprivate let generation: UInt64
}

/// Main-actor-owned, monotonically advancing authorization state for one audio
/// capture object. A stop advances the generation before removing an existing
/// tap, so a start that was already queued on the main actor cannot reactivate
/// the microphone with an older authorization.
@MainActor
final class RealtimeAudioCaptureAuthorizationState {
    private let ownerID = UUID()
    private var generation: UInt64 = 0

    func issue() -> RealtimeAudioCaptureAuthorization {
        generation &+= 1
        return RealtimeAudioCaptureAuthorization(
            ownerID: ownerID,
            generation: generation
        )
    }

    func revoke() {
        generation &+= 1
    }

    func validate(_ authorization: RealtimeAudioCaptureAuthorization) throws {
        guard authorization.ownerID == ownerID,
              authorization.generation == generation else {
            throw CancellationError()
        }
    }
}

@MainActor
protocol RealtimeAudioCapturing: AnyObject, Sendable {
    func authorizeCaptureStart() -> RealtimeAudioCaptureAuthorization
    func startCapture(
        authorizedBy authorization: RealtimeAudioCaptureAuthorization,
        onPCM16Chunk: @escaping @Sendable (Data) -> Void,
        onCaptureFailure: @escaping @Sendable (RealtimeAudioEngineError) -> Void
    ) async throws
    func stopCapture()
}

@MainActor
protocol RealtimeAudioPlaying: AnyObject, Sendable {
    func enqueuePCM16(_ data: Data, itemID: String?, responseID: String) throws
    func notifyWhenPlaybackDrained(
        responseID: String,
        onDrained: @escaping @Sendable (String) -> Void
    )
    func stopPlayback()
}

enum RealtimeAudioEngineError: LocalizedError, Equatable, Sendable {
    case microphoneUnavailable
    case invalidAudioFormat
    case invalidConverter
    case conversionFailed
    case audioSessionConfigurationFailed
    case audioSessionActivationFailed
    case audioEngineStartFailed

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            "No microphone input is available."
        case .invalidAudioFormat:
            "The device audio format is not supported."
        case .invalidConverter:
            "The microphone format cannot be converted to 24 kHz PCM16."
        case .conversionFailed:
            "Microphone audio could not be converted to 24 kHz PCM16."
        case .audioSessionConfigurationFailed:
            "The device audio session could not be configured."
        case .audioSessionActivationFailed:
            "The device audio session could not be activated."
        case .audioEngineStartFailed:
            "The device audio engine could not be started."
        }
    }
}

/// Bounds decoded model audio before AVFoundation allocates or schedules a
/// buffer. Twenty seconds is intentionally generous for normal coaching while
/// preventing a fast or malformed stream from growing the playback queue
/// without limit.
struct RealtimePlaybackQueueBudget: Equatable, Sendable {
    static let maximumDeltaBytes = RealtimeConstants.sampleRate
        * MemoryLayout<Int16>.size
        * 4
    static let maximumQueuedFrames = RealtimeConstants.sampleRate * 20

    private(set) var queuedFrames = 0

    mutating func reservePCM16(byteCount: Int) throws -> Int {
        guard byteCount > 0,
              byteCount <= Self.maximumDeltaBytes,
              byteCount.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw RealtimeAudioEngineError.invalidAudioFormat
        }

        let frameCount = byteCount / MemoryLayout<Int16>.size
        guard frameCount <= Self.maximumQueuedFrames,
              queuedFrames <= Self.maximumQueuedFrames - frameCount else {
            throw RealtimeAudioEngineError.invalidAudioFormat
        }
        queuedFrames += frameCount
        return frameCount
    }

    mutating func release(frames: Int) {
        guard frames > 0 else { return }
        queuedFrames = max(0, queuedFrames - frames)
    }

    mutating func reset() {
        queuedFrames = 0
    }
}

/// Tracks the local playback boundary for each provider response without
/// blocking the Realtime receive loop. Tokens from an older playback
/// generation are stale after interruption/reset and can never complete a new
/// response's drain callback.
struct RealtimePlaybackDrainState: Sendable {
    struct BufferToken: Equatable, Sendable {
        let responseID: String
        let generation: UInt64
    }

    enum Completion: Equatable, Sendable {
        case stale
        case pending
        case drained(responseID: String)
    }

    private struct ResponseState: Sendable {
        var pendingBufferCount: Int
        var isAwaitingDrain: Bool
    }

    private var responses: [String: ResponseState] = [:]

    mutating func scheduleBuffer(
        responseID: String,
        generation: UInt64
    ) -> BufferToken {
        var response = responses[responseID] ?? ResponseState(
            pendingBufferCount: 0,
            isAwaitingDrain: false
        )
        response.pendingBufferCount += 1
        responses[responseID] = response
        return BufferToken(responseID: responseID, generation: generation)
    }

    mutating func markResponseAudioFinished(
        responseID: String,
        generation _: UInt64
    ) -> Bool {
        guard var response = responses[responseID],
              response.pendingBufferCount > 0 else {
            responses.removeValue(forKey: responseID)
            return true
        }
        response.isAwaitingDrain = true
        responses[responseID] = response
        return false
    }

    mutating func completeBuffer(
        _ token: BufferToken,
        currentGeneration: UInt64
    ) -> Completion {
        guard token.generation == currentGeneration,
              var response = responses[token.responseID],
              response.pendingBufferCount > 0 else {
            return .stale
        }
        response.pendingBufferCount -= 1
        guard response.pendingBufferCount == 0 else {
            responses[token.responseID] = response
            return .pending
        }

        responses.removeValue(forKey: token.responseID)
        return response.isAwaitingDrain
            ? .drained(responseID: token.responseID)
            : .pending
    }

    mutating func reset() {
        responses.removeAll()
    }
}

/// A small duplex PCM engine for the WebSocket transport. Capture is converted
/// to 24 kHz mono PCM16 and model PCM16 deltas are scheduled for playback.
@MainActor
final class RealtimeAudioEngine: NSObject, RealtimeAudioCapturing, RealtimeAudioPlaying {
    typealias InterruptionHandler = @Sendable (_ interrupted: Bool) -> Void

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let audioSession = AVAudioSession.sharedInstance()
    private let pcmFormat: AVAudioFormat
    private let captureAuthorizationState = RealtimeAudioCaptureAuthorizationState()
    private var captureInstalled = false
    private var acceptsRealtimeAudio = true
    private var audioSessionIsConfigured = false
    private var playbackBudget = RealtimePlaybackQueueBudget()
    private var playbackGeneration: UInt64 = 0
    private var playbackDrainState = RealtimePlaybackDrainState()
    private var playbackDrainHandlers: [String: @Sendable (String) -> Void] = [:]
    private var interruptionHandler: InterruptionHandler?
    private var voiceProcessingIsConfigured = false

    /// Exposes the I/O mode as a privacy-safe diagnostic. This contains no
    /// captured audio and lets deterministic tests verify that speaker output
    /// is removed from the microphone uplink.
    var isVoiceProcessingEnabled: Bool {
        voiceProcessingIsConfigured && engine.inputNode.isVoiceProcessingEnabled
            && engine.outputNode.isVoiceProcessingEnabled
    }

    override init() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(RealtimeConstants.sampleRate),
            channels: AVAudioChannelCount(RealtimeConstants.channels),
            interleaved: false
        ) else {
            preconditionFailure("24 kHz mono PCM16 must be supported by AVAudioFormat")
        }
        pcmFormat = format
        super.init()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: pcmFormat)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: audioSession
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: audioSession
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setInterruptionHandler(_ handler: InterruptionHandler?) {
        interruptionHandler = handler
    }

    func authorizeCaptureStart() -> RealtimeAudioCaptureAuthorization {
        captureAuthorizationState.issue()
    }

    func startCapture(
        authorizedBy authorization: RealtimeAudioCaptureAuthorization,
        onPCM16Chunk: @escaping @Sendable (Data) -> Void,
        onCaptureFailure: @escaping @Sendable (RealtimeAudioEngineError) -> Void
    ) async throws {
        try Task.checkCancellation()
        try captureAuthorizationState.validate(authorization)
        guard !captureInstalled else { return }
        acceptsRealtimeAudio = true
        try configureAudioSession()

        guard audioSession.isInputAvailable else {
            throw RealtimeAudioEngineError.microphoneUnavailable
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RealtimeAudioEngineError.microphoneUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: pcmFormat) else {
            throw RealtimeAudioEngineError.invalidConverter
        }

        let failureGate = CaptureFailureGate()
        let captureTap = Self.makeCaptureTap(
            converter: converter,
            targetFormat: pcmFormat,
            failureGate: failureGate,
            onPCM16Chunk: onPCM16Chunk,
            onCaptureFailure: onCaptureFailure
        )
        input.installTap(
            onBus: 0,
            bufferSize: 960,
            format: inputFormat,
            block: captureTap
        )
        captureInstalled = true
        do {
            try Task.checkCancellation()
            try captureAuthorizationState.validate(authorization)
            try startEngineIfNeeded()
        } catch {
            stopCapture()
            throw error
        }
    }

    nonisolated static func makeCaptureTap(
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        failureGate: CaptureFailureGate,
        onPCM16Chunk: @escaping @Sendable (Data) -> Void,
        onCaptureFailure: @escaping @Sendable (RealtimeAudioEngineError) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let data = Self.convertToPCM16(
                buffer,
                converter: converter,
                targetFormat: targetFormat
            ) else {
                failureGate.reportOnce(.conversionFailed, to: onCaptureFailure)
                return
            }
            onPCM16Chunk(data)
        }
    }

    nonisolated static func makePlaybackCompletionHandler(
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { _ in
            Task { @MainActor in
                handler()
            }
        }
    }

    func stopCapture() {
        captureAuthorizationState.revoke()
        guard captureInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        captureInstalled = false
    }

    func enqueuePCM16(
        _ data: Data,
        itemID _: String?,
        responseID: String
    ) throws {
        guard acceptsRealtimeAudio else { return }
        let scheduledFrames: Int
        do {
            scheduledFrames = try playbackBudget.reservePCM16(byteCount: data.count)
        } catch {
            rejectRealtimePlayback()
            throw error
        }

        do {
            try configureAudioSession()
            try startEngineIfNeeded()

            let frameCount = AVAudioFrameCount(scheduledFrames)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: pcmFormat,
                frameCapacity: frameCount
            ), let destination = buffer.int16ChannelData?[0] else {
                throw RealtimeAudioEngineError.invalidAudioFormat
            }

            _ = data.copyBytes(
                to: UnsafeMutableBufferPointer(
                    start: destination,
                    count: scheduledFrames
                )
            )
            buffer.frameLength = frameCount
            let generation = playbackGeneration
            let drainToken = playbackDrainState.scheduleBuffer(
                responseID: responseID,
                generation: generation
            )
            let completionHandler = Self.makePlaybackCompletionHandler { [weak self] in
                guard let self else { return }
                switch self.playbackDrainState.completeBuffer(
                    drainToken,
                    currentGeneration: self.playbackGeneration
                ) {
                case .stale:
                    return
                case .pending:
                    self.playbackBudget.release(frames: scheduledFrames)
                case let .drained(responseID):
                    self.playbackBudget.release(frames: scheduledFrames)
                    let handler = self.playbackDrainHandlers.removeValue(
                        forKey: responseID
                    )
                    handler?(responseID)
                }
            }
            player.scheduleBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack,
                completionHandler: completionHandler
            )
            if !player.isPlaying {
                player.play()
            }
        } catch {
            rejectRealtimePlayback()
            throw error
        }
    }

    func notifyWhenPlaybackDrained(
        responseID: String,
        onDrained: @escaping @Sendable (String) -> Void
    ) {
        let isAlreadyDrained = playbackDrainState.markResponseAudioFinished(
            responseID: responseID,
            generation: playbackGeneration
        )
        if isAlreadyDrained {
            onDrained(responseID)
        } else {
            playbackDrainHandlers[responseID] = onDrained
        }
    }

    func stopPlayback() {
        playbackGeneration &+= 1
        playbackBudget.reset()
        playbackDrainState.reset()
        playbackDrainHandlers.removeAll()
        player.stop()
        player.reset()
    }

    func stopAll() {
        acceptsRealtimeAudio = false
        stopCapture()
        stopPlayback()
        engine.stop()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        audioSessionIsConfigured = false
    }

    private func configureAudioSession() throws {
        guard !audioSessionIsConfigured else { return }
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try audioSession.setPreferredSampleRate(Double(RealtimeConstants.sampleRate))
            try audioSession.setPreferredIOBufferDuration(0.02)
        } catch {
            throw RealtimeAudioEngineError.audioSessionConfigurationFailed
        }

        do {
            try audioSession.setActive(true)
        } catch {
            throw RealtimeAudioEngineError.audioSessionActivationFailed
        }
        // Resolve the microphone route only after the authorized duplex session
        // is active. Initializing VoiceProcessingIO in init can cache a zero-Hz
        // input route before playAndRecord has selected the microphone.
        do {
            if !voiceProcessingIsConfigured {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                voiceProcessingIsConfigured = true
            }
            guard isVoiceProcessingEnabled else {
                throw RealtimeAudioEngineError.audioSessionConfigurationFailed
            }
            audioSessionIsConfigured = true
        } catch {
            voiceProcessingIsConfigured = false
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            throw RealtimeAudioEngineError.audioSessionConfigurationFailed
        }
    }

    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw RealtimeAudioEngineError.audioEngineStartFailed
        }
    }

    private func configureSessionAndStartEngine() throws {
        try configureAudioSession()
        try startEngineIfNeeded()
    }

    private func rejectRealtimePlayback() {
        acceptsRealtimeAudio = false
        stopPlayback()
    }

    private nonisolated static func convertToPCM16(
        _ input: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> Data? {
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 16
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else { return nil }

        let inputState = ConverterInputState(input: input)
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { _, inputStatus in
            inputState.next(status: inputStatus)
        }
        guard conversionError == nil,
              status == .haveData || status == .inputRanDry else {
            return nil
        }
        guard output.frameLength > 0,
              let samples = output.int16ChannelData?[0] else {
            return nil
        }
        return Data(
            bytes: samples,
            count: Int(output.frameLength) * MemoryLayout<Int16>.size
        )
    }

    @objc
    private nonisolated func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: rawType) != nil else {
            return
        }
        let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        Task { @MainActor [weak self] in
            self?.applyInterruption(rawType: rawType, rawOptions: rawOptions)
        }
    }

    private func applyInterruption(rawType: UInt, rawOptions: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            audioSessionIsConfigured = false
            stopPlayback()
            engine.pause()
            interruptionHandler?(true)
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if options.contains(.shouldResume) {
                try? configureSessionAndStartEngine()
            }
            interruptionHandler?(false)
        @unknown default:
            break
        }
    }

    @objc
    private nonisolated func handleMediaServicesReset(_: Notification) {
        Task { @MainActor [weak self] in
            self?.applyMediaServicesReset()
        }
    }

    private func applyMediaServicesReset() {
        audioSessionIsConfigured = false
        stopPlayback()
        interruptionHandler?(true)
    }
}

final class CaptureFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didReport = false

    func reportOnce(
        _ error: RealtimeAudioEngineError,
        to handler: @Sendable (RealtimeAudioEngineError) -> Void
    ) {
        lock.lock()
        guard !didReport else {
            lock.unlock()
            return
        }
        didReport = true
        lock.unlock()
        handler(error)
    }
}

private final class ConverterInputState: @unchecked Sendable {
    private let input: AVAudioPCMBuffer
    private let lock = NSLock()
    private var supplied = false

    init(input: AVAudioPCMBuffer) {
        self.input = input
    }

    func next(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !supplied else {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return input
    }
}
