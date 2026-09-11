import Foundation
import Observation
import OSLog
import SwiftUI
import UIKit

private let voiceCoachLogger = Logger(
    subsystem: "com.dessdynamics.watchlearn",
    category: "VoiceCoach"
)

enum VoiceCoachPhase: Equatable, Sendable {
    case idle
    case requestingPermission
    case connecting
    case listening
    case childSpeaking
    case coachSpeaking
    case failed(String)

    var isVisible: Bool {
        self != .idle
    }
}

enum VoiceCoachStartupStage: String, Equatable, Sendable {
    case preparing = "VC-STAGE-PREPARE"
    case microphonePermission = "VC-STAGE-PERMISSION"
    case credentials = "VC-STAGE-CREDENTIALS"
    case connection = "VC-STAGE-CONNECTION"
    case challenge = "VC-STAGE-CONTEXT"
    case audioCapture = "VC-STAGE-AUDIO"
}

/// Transcripts are transient UI hints, not session history. Keep both each
/// incoming fragment and the displayed accumulation bounded so an unexpected
/// provider event cannot grow observable state indefinitely.
enum VoiceCoachTranscriptPolicy {
    static let maximumDeltaScalars = 512
    static let maximumTranscriptScalars = 2_048

    static func appending(_ delta: String, to transcript: String) -> String {
        let safeDelta = boundedPrefix(
            delta,
            maximumScalars: maximumDeltaScalars
        )
        guard !safeDelta.isEmpty else {
            return boundedPrefix(
                transcript,
                maximumScalars: maximumTranscriptScalars
            )
        }
        let safeTranscript = boundedPrefix(
            transcript,
            maximumScalars: maximumTranscriptScalars
        )
        return boundedPrefix(
            safeTranscript + safeDelta,
            maximumScalars: maximumTranscriptScalars
        )
    }

    static func replacing(with transcript: String) -> String {
        boundedPrefix(
            transcript,
            maximumScalars: maximumTranscriptScalars
        )
    }

    private static func boundedPrefix(
        _ value: String,
        maximumScalars: Int
    ) -> String {
        guard maximumScalars > 0 else { return "" }
        let sampledScalars = value.unicodeScalars.prefix(maximumScalars + 1)
        guard sampledScalars.count > maximumScalars else {
            return String(sampledScalars)
        }
        guard maximumScalars > 1 else { return "…" }
        return String(sampledScalars.prefix(maximumScalars - 1)) + "…"
    }
}

enum VoiceCoachFailureCode: String, Equatable, Sendable {
    case liveAccessDenied = "VC-LIVE-ACCESS"
    case liveBrokerUnsupported = "VC-LIVE-BROKER"
    case credentialMissing = "VC-TOKEN-MISSING"
    case credentialUnauthorized = "VC-TOKEN-401"
    case credentialForbidden = "VC-TOKEN-403"
    case credentialRateLimited = "VC-TOKEN-429"
    case credentialExpired = "VC-TOKEN-EXPIRED"
    case credentialConfiguration = "VC-TOKEN-CONFIG"
    case networkOffline = "VC-NETWORK-OFFLINE"
    case networkTimeout = "VC-NETWORK-TIMEOUT"
    case malformedServiceResponse = "VC-SERVICE-RESPONSE"
    case sessionSetup = "VC-SESSION-SETUP"
    case sessionAlreadyActive = "VC-SESSION-ACTIVE"
    case trialExhausted = "VC-TRIAL-COMPLETE"
    case agreementRequired = "VC-PRIVACY-REVIEW"
    case audioConfiguration = "VC-AUDIO-CONFIG"
    case audioActivation = "VC-AUDIO-ACTIVATE"
    case audioEngineStart = "VC-AUDIO-START"
    case audioInputRoute = "VC-AUDIO-ROUTE"
    case audioConverter = "VC-AUDIO-CONVERTER"
    case audioFormat = "VC-AUDIO-FORMAT"
    case unknown = "VC-START-UNKNOWN"
}

/// Converts all provider, transport, protocol, and audio errors into an
/// allow-listed support code and copy. Raw provider messages are deliberately
/// never retained or shown to the family.
struct VoiceCoachFailure: Equatable, Sendable {
    let code: VoiceCoachFailureCode

    init(error: Error) {
        code = Self.classify(error)
    }

    func localizedMessage(
        language: InterfaceLanguage,
        startupStage: VoiceCoachStartupStage? = nil
    ) -> String {
        let message: String
        switch (code, language) {
        case (.agreementRequired, .german):
            message = "Eine erwachsene Person muss zuerst Datenschutz und Berechtigungen in den Einstellungen bestätigen."
        case (.agreementRequired, .english):
            message = "A parent needs to confirm privacy and permissions in Settings first."
        case (.liveAccessDenied, .german):
            message = "OpenAI hat den Zugang zu GPT-Live abgelehnt. Prüfe mit einer erwachsenen Person den API-Key, das Projekt und dessen GPT-Live-Freigabe."
        case (.liveAccessDenied, .english):
            message = "OpenAI denied GPT-Live access. A parent needs to check the API key, project, and GPT-Live access."
        case (.liveBrokerUnsupported, .german):
            message = "Dieser Token-Dienst unterstützt nur Realtime. Für GPT-Live wird aktuell ein eigener API-Key mit Live-Freigabe benötigt."
        case (.liveBrokerUnsupported, .english):
            message = "This token service supports Realtime only. GPT-Live currently needs your own API key with Live access."
        case (.credentialMissing, .german):
            message = "Der OpenAI API-Key oder Token-Dienst ist nicht eingerichtet. Prüfe die Zugangsdaten in den Einstellungen."
        case (.credentialMissing, .english):
            message = "The OpenAI API key or token service is not configured. Check the credentials in Settings."
        case (.credentialUnauthorized, .german):
            message = "Der Sprachzugang konnte nicht bestätigt werden. Eine erwachsene Person kann die Anmeldung oder den Zugang in den Einstellungen prüfen."
        case (.credentialUnauthorized, .english):
            message = "Voice access could not be verified. A parent can check the sign-in or access settings."
        case (.credentialForbidden, .german):
            message = "Der Token-Dienst hat keinen Zugriff auf Realtime. Prüfe Projekt und Berechtigungen."
        case (.credentialForbidden, .english):
            message = "The token service cannot access Realtime. Check the project and its permissions."
        case (.credentialRateLimited, .german):
            message = "Das API-Limit ist erreicht. Warte kurz und prüfe das verfügbare API-Budget."
        case (.credentialRateLimited, .english):
            message = "The API limit has been reached. Wait briefly and check the available API budget."
        case (.credentialExpired, .german):
            message = "Der temporäre Sprachzugang ist abgelaufen. Starte deinen Zeithelden erneut."
        case (.credentialExpired, .english):
            message = "The temporary voice credential expired. Start your Time Hero again."
        case (.credentialConfiguration, .german):
            message = "Die Zugangskonfiguration ist ungültig. Prüfe API-Key oder HTTPS-Token-Dienst."
        case (.credentialConfiguration, .english):
            message = "The credential configuration is invalid. Check the API key or HTTPS token service."
        case (.networkOffline, .german):
            message = "Es besteht keine Internetverbindung. Stelle die Verbindung her und starte deinen Zeithelden erneut."
        case (.networkOffline, .english):
            message = "There is no internet connection. Reconnect and start your Time Hero again."
        case (.networkTimeout, .german):
            message = "Der Verbindungsaufbau dauerte zu lange. Prüfe die Internetverbindung und versuche es erneut."
        case (.networkTimeout, .english):
            message = "The connection took too long. Check the internet connection and try again."
        case (.malformedServiceResponse, .german):
            message = "Der Sprachdienst hat eine unlesbare Antwort geliefert. Versuche es erneut und prüfe bei einem eigenen Token-Dienst dessen Antwortformat."
        case (.malformedServiceResponse, .english):
            message = "The voice service returned an unreadable response. Try again and, for a custom token service, check its response format."
        case (.sessionSetup, .german):
            message = "Die Sprachsitzung konnte nicht aufgebaut werden. Prüfe die Verbindung und versuche es erneut."
        case (.sessionSetup, .english):
            message = "The voice session could not be established. Check the connection and try again."
        case (.sessionAlreadyActive, .german):
            message = "Ein Gespräch läuft noch oder wird gerade beendet. Beende es auf dem anderen Gerät oder versuche es gleich noch einmal."
        case (.sessionAlreadyActive, .english):
            message = "A conversation is still active or finishing. End it on the other device or try again shortly."
        case (.trialExhausted, .german):
            message = "Deine fünf Probeminuten sind aufgebraucht. In den Einstellungen kann eine erwachsene Person einen eigenen API-Key hinzufügen. Offline kannst du weiterüben."
        case (.trialExhausted, .english):
            message = "Your five trial minutes are used up. A parent can add their own API key in Settings. You can keep practising offline."
        case (.audioConfiguration, .german):
            message = "iOS konnte den Audiomodus nicht konfigurieren. Beende das Gespräch und starte ihn erneut."
        case (.audioConfiguration, .english):
            message = "iOS could not configure the audio mode. End the conversation and start it again."
        case (.audioActivation, .german):
            message = "iOS konnte die Audiositzung nicht aktivieren. Beende das Gespräch und starte ihn erneut."
        case (.audioActivation, .english):
            message = "iOS could not activate the audio session. End the conversation and start it again."
        case (.audioEngineStart, .german):
            message = "Die Audioverarbeitung konnte nicht starten. Beende das Gespräch und starte ihn erneut."
        case (.audioEngineStart, .english):
            message = "Audio processing could not start. End the conversation and start it again."
        case (.audioInputRoute, .german):
            message = "iOS meldet keinen verfügbaren Mikrofoneingang. Prüfe die Mikrofonfreigabe und starte deinen Zeithelden erneut."
        case (.audioInputRoute, .english):
            message = "iOS reports no available microphone input. Check microphone access and start your Time Hero again."
        case (.audioConverter, .german):
            message = "Das Mikrofonformat kann nicht für den Zeithelden umgewandelt werden. Starte deinen Zeithelden erneut."
        case (.audioConverter, .english):
            message = "The microphone format cannot be converted for your Time Hero. Start your Time Hero again."
        case (.audioFormat, .german):
            message = "Das aktuelle Audioformat wird nicht unterstützt. Starte deinen Zeithelden erneut."
        case (.audioFormat, .english):
            message = "The current audio format is not supported. Start your Time Hero again."
        case (.unknown, .german):
            message = "Dein Zeitheld konnte nicht starten. Versuche es erneut; bleibt das Problem bestehen, notiere den Fehlercode."
        case (.unknown, .english):
            message = "Your Time Hero could not start. Try again; if the problem continues, note the error code."
        }
        let stageCode = startupStage.map { " [\($0.rawValue)]" } ?? ""
        return "\(message)\(stageCode) [\(code.rawValue)]"
    }

    private static func classify(_ error: Error) -> VoiceCoachFailureCode {
        if let account = error as? ManagedAccountError {
            switch account {
            case .signInRequired, .invalidSignIn: return .credentialUnauthorized
            case .unavailable: return .sessionSetup
            case .trialExhausted: return .trialExhausted
            case .sessionAlreadyActive: return .sessionAlreadyActive
            case .malformedResponse: return .malformedServiceResponse
            case .agreementRequired: return .agreementRequired
            }
        }
        if error is DecodingError { return .malformedServiceResponse }
        if let providerError = error as? RealtimeClientSecretProviderError {
            switch providerError {
            case .missingCredential:
                return .credentialMissing
            case .insecureBrokerURL:
                return .credentialConfiguration
            case .invalidHTTPResponse, .malformedResponse:
                return .malformedServiceResponse
            case let .httpStatus(status, _):
                switch status {
                case 401: return .credentialUnauthorized
                case 403: return .credentialForbidden
                case 429: return .credentialRateLimited
                default: return .sessionSetup
                }
            }
        }

        if let audioError = error as? RealtimeAudioEngineError {
            switch audioError {
            case .microphoneUnavailable:
                return .audioInputRoute
            case .invalidConverter:
                return .audioConverter
            case .invalidAudioFormat, .conversionFailed:
                return .audioFormat
            case .audioSessionConfigurationFailed:
                return .audioConfiguration
            case .audioSessionActivationFailed:
                return .audioActivation
            case .audioEngineStartFailed:
                return .audioEngineStart
            }
        }

        if let serviceError = error as? RealtimeServiceError {
            switch serviceError {
            case .expiredClientSecret:
                return .credentialExpired
            case .malformedServerEvent, .unsupportedWebSocketMessage:
                return .malformedServiceResponse
            case .audioUnavailable:
                return .audioInputRoute
            case .invalidAudioChunk:
                return .audioFormat
            case .alreadyConnected, .notConnected, .invalidChallenge:
                return .sessionSetup
            }
        }

        if error is RealtimeEventDecodingError {
            return .malformedServiceResponse
        }
        if error is RealtimeEventEncodingError
            || error is RealtimeWebSocketTransportError {
            return .sessionSetup
        }

        if let live = error as? LiveServiceError {
            switch live {
            case .accessDenied: return .liveAccessDenied
            case .unsupportedBroker: return .liveBrokerUnsupported
            case .invalidCredential: return .credentialUnauthorized
            case .handshakeTimeout: return .networkTimeout
            default: return .sessionSetup
            }
        }

        if let apiError = error as? RealtimeAPIError {
            switch apiError.code?.lowercased() {
            case "live_access_denied": return .liveAccessDenied
            case "invalid_api_key", "unauthorized":
                return .credentialUnauthorized
            case "permission_denied", "access_denied", "forbidden":
                return .credentialForbidden
            case "rate_limit_exceeded", "insufficient_quota":
                return .credentialRateLimited
            case "client_secret_expired", "session_expired":
                return .credentialExpired
            case "network_offline":
                return .networkOffline
            case "network_timeout":
                return .networkTimeout
            case "audio_configuration_failed":
                return .audioConfiguration
            case "audio_activation_failed":
                return .audioActivation
            case "audio_engine_start_failed", "audio_playback_failed":
                return .audioEngineStart
            case "audio_input_unavailable":
                return .audioInputRoute
            case "audio_converter_invalid":
                return .audioConverter
            case "audio_format_invalid":
                return .audioFormat
            default:
                return .sessionSetup
            }
        }

        if let settingsError = error as? ParentSettingsError {
            switch settingsError {
            case .invalidAPIKey:
                return .credentialUnauthorized
            case .invalidBrokerURL:
                return .credentialConfiguration
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: nsError.code) {
            case .timedOut:
                return .networkTimeout
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .internationalRoamingOff, .dataNotAllowed:
                return .networkOffline
            default:
                return .sessionSetup
            }
        }

        return .unknown
    }
}

@MainActor
protocol VoiceCoachAudioManaging: RealtimeAudioCapturing, RealtimeAudioPlaying {
    func setInterruptionHandler(
        _ handler: (@Sendable (_ interrupted: Bool) -> Void)?
    )
    func stopAll()
}

extension RealtimeAudioEngine: VoiceCoachAudioManaging {}

struct VoiceCoachSessionResources {
    let service: any VoiceCoachingService
    let audioEngine: any VoiceCoachAudioManaging
}

enum VoiceCoachCredential: Sendable {
    case parentKey(String)
    case legacyBroker(URL)
    case managedLive(URL, String)
}

typealias VoiceCoachSessionFactory = @MainActor (
    _ credential: VoiceCoachCredential
) throws -> VoiceCoachSessionResources

@MainActor
@Observable
final class VoiceCoachCoordinator {
    private(set) var phase: VoiceCoachPhase = .idle
    private(set) var childTranscript = ""
    private(set) var coachTranscript = ""
    private(set) var isSessionActive = false
    private(set) var isStarting = false
    private(set) var isStopping = false

    var onClockAnswer: ((ClockAnswerReport) -> Void)?
    var onLiveClockAnswer: ((ClockAnswerReport, Int) -> Void)?
    var onSpokenCorrectAnswerFeedbackFinished: ((Int, String) -> Void)?
    var onSpokenAutoAdvanceCancelled: (() -> Void)?

    #if DEBUG
    func showCoachSpeakingStatusForUITesting() {
        phase = .coachSpeaking
        coachTranscript = "This deliberately long coach transcript must never be rendered in the compact status bar."
    }
    #endif

    private let microphonePermission: any MicrophonePermissionProviding
    private let sessionFactory: VoiceCoachSessionFactory
    private var service: (any VoiceCoachingService)?
    private var audioEngine: (any VoiceCoachAudioManaging)?
    private var sessionID: UUID?
    private var eventTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var startAttemptID: UUID?
    private var tearDownTask: Task<Void, Never>?
    private var tearDownTaskID: UUID?
    private var tearDownSessionID: UUID?
    private var sessionLanguage: RealtimeCoachLanguage = .german
    private var learnerContext: ClockLearnerContext?
    private var speakingResponseIDs: Set<String> = []

    init(
        microphonePermission: any MicrophonePermissionProviding = SystemMicrophonePermissionService()
    ) {
        self.microphonePermission = microphonePermission
        self.sessionFactory = { credential in
            let key: String
            switch credential {
            case .parentKey(let value): key = value
            case .managedLive(let endpoint, let token):
                let session = ManagedLiveSession(baseURL: endpoint, token: token)
                return VoiceCoachSessionResources(service: session, audioEngine: session)
            case .legacyBroker: throw LiveServiceError.unsupportedBroker
            }
            let audioEngine = RealtimeAudioEngine()
            return VoiceCoachSessionResources(
                service: OpenAILiveService(
                    apiKey: key,
                    audioCapture: audioEngine,
                    audioPlayback: audioEngine
                ),
                audioEngine: audioEngine
            )
        }
    }

    init(
        microphonePermission: any MicrophonePermissionProviding,
        sessionFactory: @escaping VoiceCoachSessionFactory
    ) {
        self.microphonePermission = microphonePermission
        self.sessionFactory = sessionFactory
    }

    func start(question: TimeQuestion, preferences: ParentPreferences, learner: ClockLearnerContext? = nil) async {
        if isSessionActive {
            await updateChallenge(question)
            return
        }
        guard startTask == nil, !isStopping else { return }
        learnerContext = learner
        clearTranscripts()

        let attemptID = UUID()
        startAttemptID = attemptID
        isStarting = true
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStart(question: question, preferences: preferences)
        }
        startTask = operation
        await operation.value

        if startAttemptID == attemptID {
            startAttemptID = nil
            startTask = nil
            isStarting = false
        }
    }

    private func performStart(question: TimeQuestion, preferences: ParentPreferences) async {
        var installedSessionID: UUID?
        var startupStage = VoiceCoachStartupStage.preparing
        do {
            await waitForPendingTearDown()
            try Task.checkCancellation()
            startupStage = .microphonePermission
            phase = .requestingPermission
            let permissionGranted: Bool
            switch microphonePermission.currentPermission() {
            case .granted:
                permissionGranted = true
            case .denied:
                permissionGranted = false
            case .undetermined:
                permissionGranted = await microphonePermission.requestPermission()
            }
            guard permissionGranted else {
                voiceCoachLogger.error(
                    "startup_failed stage=VC-STAGE-PERMISSION code=VC-MIC-PERMISSION"
                )
                phase = .failed(localized(
                    language: preferences.language,
                    de: "Das Mikrofon ist ausgeschaltet. Eine erwachsene Person kann es in den iOS-Einstellungen erlauben.",
                    en: "The microphone is off. A parent can allow it in iOS Settings."
                ) + " [VC-STAGE-PERMISSION] [VC-MIC-PERMISSION]")
                return
            }
            try Task.checkCancellation()

            startupStage = .credentials
            let credential = try await makeCredential(preferences: preferences)
            let resources = try sessionFactory(credential)
            let audioEngine = resources.audioEngine
            let service = resources.service
            let captureAuthorization = audioEngine.authorizeCaptureStart()
            let newSessionID = UUID()
            installedSessionID = newSessionID
            audioEngine.setInterruptionHandler { [weak self] interrupted in
                guard interrupted else { return }
                Task { @MainActor [weak self] in
                    await self?.handleAudioInterruption(sessionID: newSessionID)
                }
            }
            self.audioEngine = audioEngine
            self.service = service
            sessionID = newSessionID
            observe(service, sessionID: newSessionID)

            phase = .connecting
            sessionLanguage = preferences.language.realtimeLanguage
            let safetyIdentifier = RealtimeSafetyIdentifier(
                stableID: preferences.realtimeSafetyIdentifier
            )
            startupStage = .connection
            try await service.open(language: sessionLanguage, safetyIdentifier: safetyIdentifier)
            guard sessionID == newSessionID else { throw CancellationError() }
            try Task.checkCancellation()
            isSessionActive = true
            startupStage = .challenge
            try await service.setChallenge(context(for: question))
            guard sessionID == newSessionID else { throw CancellationError() }
            try Task.checkCancellation()
            startupStage = .audioCapture
            try await service.startVoice(authorizedBy: captureAuthorization)
            guard sessionID == newSessionID else { throw CancellationError() }
            try Task.checkCancellation()
            phase = .listening
        } catch is CancellationError {
            clearTranscripts()
            if let installedSessionID {
                await tearDown(sessionID: installedSessionID)
            }
        } catch {
            clearTranscripts()
            phase = .failed(safeMessage(
                for: error,
                language: preferences.language,
                startupStage: startupStage
            ))
            if let installedSessionID {
                await tearDown(sessionID: installedSessionID)
            }
        }
    }

    func updateChallenge(_ question: TimeQuestion) async {
        guard let service, isSessionActive else { return }
        clearTranscripts()
        do {
            try await service.setChallenge(context(for: question))
            phase = .listening
        } catch {
            clearTranscripts()
            voiceCoachLogger.error(
                "session_failed stage=VC-STAGE-CONTEXT code=VC-SESSION-CONTEXT"
            )
            phase = .failed(realtimeLocalized(
                de: "Dein Zeitheld konnte die nächste Uhr nicht laden.",
                en: "Your Time Hero could not load the next clock."
            ) + " [VC-SESSION-CONTEXT]")
            if let sessionID {
                await tearDown(sessionID: sessionID)
            }
        }
    }

    func stop() async {
        guard !isStopping else { return }
        isStopping = true
        stopLocalAudioImmediately()
        let pendingStart = startTask
        startTask = nil
        startAttemptID = nil
        isStarting = false
        pendingStart?.cancel()
        if let sessionID {
            scheduleTearDown(sessionID: sessionID)
        }
        await waitForPendingTearDown()
        await pendingStart?.value
        if let sessionID {
            await tearDown(sessionID: sessionID)
        }
        phase = .idle
        clearTranscripts()
        isStopping = false
    }

    /// Stops microphone capture and speaker playback synchronously on the main
    /// actor. Transport cleanup still runs asynchronously through `stop()`.
    func stopLocalAudioImmediately() {
        startTask?.cancel()
        eventTask?.cancel()
        eventTask = nil
        audioEngine?.stopAll()
        isSessionActive = false
        isStarting = false
        clearTranscripts()
    }

    func dismissError() {
        guard case .failed = phase else { return }
        clearTranscripts()
        phase = .idle
    }

    private func makeCredential(
        preferences: ParentPreferences
    ) async throws -> VoiceCoachCredential {
        switch preferences.cloudVoiceMode {
        case .offline:
            throw RealtimeClientSecretProviderError.missingCredential
        case .parentKey:
            guard let key = try preferences.apiKeyForVoiceConnection() else {
                throw RealtimeClientSecretProviderError.missingCredential
            }
            return .parentKey(key)
        case .managedBroker:
            return .legacyBroker(try preferences.validatedBrokerURL())
        case .managedAccount:
            return try await ParentAccount.shared.voiceCredential()
        }
    }

    private func context(for question: TimeQuestion) -> ClockChallengeContext {
        let imageData = clockSnapshot(question: question)
        if let imageData {
            return ClockChallengeContext(
                questionID: question.id,
                hour: question.time.hour,
                minute: question.time.minute,
                difficulty: String(question.level.rawValue),
                language: questionLanguage(question),
                clockImageData: imageData,
                learner: learnerContext
            )
        }
        return ClockChallengeContext(
            questionID: question.id,
            hour: question.time.hour,
            minute: question.time.minute,
            difficulty: String(question.level.rawValue),
            language: questionLanguage(question),
            learner: learnerContext
        )
    }

    private func questionLanguage(_ question: TimeQuestion) -> RealtimeCoachLanguage {
        _ = question
        return sessionLanguage
    }

    private func clockSnapshot(question: TimeQuestion) -> Data? {
        let renderer = ImageRenderer(content:
            ZStack {
                Color.white
                AnalogClockView(
                    time: question.time,
                    theme: question.heroTheme,
                    language: .english,
                    showsMinuteTicks: true
                )
                .padding(28)
            }
            .frame(width: 384, height: 384)
        )
        renderer.scale = 1
        return renderer.uiImage?.pngData()
    }

    private func observe(_ service: any VoiceCoachingService, sessionID: UUID) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in service.events {
                guard !Task.isCancelled else { break }
                self?.handle(event, sessionID: sessionID)
            }
        }
    }

    private func handle(_ event: RealtimeServiceEvent, sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        switch event {
        case .speechStarted:
            onSpokenAutoAdvanceCancelled?()
            childTranscript = ""
            speakingResponseIDs.removeAll()
            phase = .childSpeaking
        case .speechStopped:
            phase = .listening
        case let .transcriptDelta(speaker, text):
            if speaker == .child {
                childTranscript = VoiceCoachTranscriptPolicy.appending(
                    text,
                    to: childTranscript
                )
            } else {
                coachTranscript = VoiceCoachTranscriptPolicy.appending(
                    text,
                    to: coachTranscript
                )
                // Captions can arrive after playback. Only audible audio
                // drives the speaking indicator.
            }
        case let .transcriptCompleted(speaker, text):
            let safeTranscript = VoiceCoachTranscriptPolicy.replacing(with: text)
            if speaker == .child { childTranscript = safeTranscript }
            else { coachTranscript = safeTranscript }
        case let .assistantAudio(_, responseID):
            speakingResponseIDs.insert(responseID)
            phase = .coachSpeaking
        case let .assistantAudioFinished(responseID):
            guard speakingResponseIDs.remove(responseID) != nil else { return }
            if speakingResponseIDs.isEmpty, phase == .coachSpeaking {
                phase = .listening
            }
        case let .spokenCorrectAnswerFeedbackFinished(responseID, questionID):
            guard let questionID else { return }
            onSpokenCorrectAnswerFeedbackFinished?(questionID, responseID)
        case let .liveClockAnswerReported(report, _, questionID):
            onLiveClockAnswer?(report, questionID)
        case let .clockAnswerReported(report, _):
            onClockAnswer?(report)
        case let .serverError(error):
            stopLocalAudioImmediately()
            let failure = VoiceCoachFailure(error: error)
            voiceCoachLogger.error(
                "session_failed code=\(failure.code.rawValue, privacy: .public)"
            )
            phase = .failed(failure.localizedMessage(
                language: interfaceLanguageForSession
            ))
            scheduleTearDown(sessionID: sessionID)
        case let .connectionStateChanged(state):
            if state == .disconnected {
                isSessionActive = false
                clearTranscripts()
                if case .failed = phase {} else { phase = .idle }
            }
        }
    }

    private func scheduleTearDown(sessionID: UUID) {
        if tearDownSessionID == sessionID, tearDownTask != nil { return }
        let taskID = UUID()
        tearDownTaskID = taskID
        tearDownSessionID = sessionID
        tearDownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.tearDown(sessionID: sessionID)
            guard self.tearDownTaskID == taskID else { return }
            self.tearDownTask = nil
            self.tearDownTaskID = nil
            self.tearDownSessionID = nil
        }
    }

    private func waitForPendingTearDown() async {
        let pending = tearDownTask
        await pending?.value
    }

    private func tearDown(sessionID expectedSessionID: UUID) async {
        guard sessionID == expectedSessionID else { return }
        let eventTask = self.eventTask
        let service = self.service
        let audioEngine = self.audioEngine

        eventTask?.cancel()
        self.eventTask = nil
        self.service = nil
        self.audioEngine = nil
        sessionID = nil
        isSessionActive = false

        if let service { await service.disconnect() }
        audioEngine?.stopAll()
    }

    private func handleAudioInterruption(sessionID: UUID) async {
        guard self.sessionID == sessionID, isSessionActive || isStarting else { return }
        stopLocalAudioImmediately()
        voiceCoachLogger.error(
            "session_failed code=VC-AUDIO-INTERRUPTED"
        )
        phase = .failed(realtimeLocalized(
            de: "Dein Zeitheld wurde unterbrochen. Bitte starte ihn noch einmal.",
            en: "Your Time Hero was interrupted. Please start it again."
        ) + " [VC-AUDIO-INTERRUPTED]")
        await tearDown(sessionID: sessionID)
    }

    private func safeMessage(
        for error: Error,
        language: InterfaceLanguage,
        startupStage: VoiceCoachStartupStage? = nil
    ) -> String {
        let failure = VoiceCoachFailure(error: error)
        if let startupStage {
            voiceCoachLogger.error(
                "startup_failed stage=\(startupStage.rawValue, privacy: .public) code=\(failure.code.rawValue, privacy: .public)"
            )
        }
        return failure.localizedMessage(
            language: language,
            startupStage: startupStage
        )
    }

    private func clearTranscripts() {
        onSpokenAutoAdvanceCancelled?()
        childTranscript = ""
        coachTranscript = ""
        speakingResponseIDs.removeAll()
    }

    private var interfaceLanguageForSession: InterfaceLanguage {
        sessionLanguage == .english ? .english : .german
    }

    private func localized(language: InterfaceLanguage, de: String, en: String) -> String {
        language == .german ? de : en
    }

    private func realtimeLocalized(de: String, en: String) -> String {
        sessionLanguage == .german ? de : en
    }
}
