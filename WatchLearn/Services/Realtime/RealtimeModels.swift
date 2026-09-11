import CryptoKit
import Foundation

enum RealtimeConstants {
    static let model = "gpt-realtime-2.1"
    static let sampleRate = 24_000
    static let channels = 1
    static let maxServerEventBytes = 1_048_576
    static let maxAudioDeltaBase64Bytes = 524_288
    static let maxDecodedAudioDeltaBytes = 393_216
    static let maxTranscriptDeltaBytes = 4_096
    static let maxCompletedTranscriptBytes = 32_768
    static let maxFunctionArgumentsBytes = 65_536
    static let maxFunctionCallsPerResponse = 16
    static let maxIdentifierBytes = 256
    static let maxInputAudioChunkBytes = 96_000
    static let maxChallengeImageBytes = 4_194_304
    static let maxTokenResponseBytes = 32_768
    static let maximumClientSecretLifetime: TimeInterval = 7_260
    static let minimumUsableClientSecretLifetime: TimeInterval = 5
    static let webSocketURL = URL(
        string: "wss://api.openai.com/v1/realtime?model=\(model)"
    )!
    static let clientSecretURL = URL(
        string: "https://api.openai.com/v1/realtime/client_secrets"
    )!
}

enum RealtimeCoachLanguage: String, Codable, CaseIterable, Sendable {
    case german = "de"
    case english = "en"
    case bilingual = "de-en"
}

enum RealtimeVoice: String, Codable, CaseIterable, Sendable {
    case marin
    case cedar
    case coral
    case sage
    case shimmer
    case verse
}

struct RealtimeSessionOptions: Equatable, Sendable {
    var language: RealtimeCoachLanguage
    var voice: RealtimeVoice
    var clientSecretTTLSeconds: Int

    init(
        language: RealtimeCoachLanguage = .german,
        voice: RealtimeVoice = .marin,
        clientSecretTTLSeconds: Int = 600
    ) {
        self.language = language
        self.voice = voice
        self.clientSecretTTLSeconds = min(max(clientSecretTTLSeconds, 60), 7200)
    }
}

/// A stable, non-identifying value for OpenAI abuse monitoring. The unhashed
/// identifier is never retained by this type.
struct RealtimeSafetyIdentifier: Hashable, Sendable {
    let headerValue: String

    init(stableID: String) {
        let digest = SHA256.hash(data: Data(stableID.utf8))
        let hexDigest = digest.map { String(format: "%02x", $0) }.joined()
        headerValue = "watchlearn_" + hexDigest.prefix(53)
    }
}

struct RealtimeClientSecret: Equatable, Sendable {
    let value: String
    let expiresAt: Date
}

struct ClockLearnerContext: Equatable, Sendable {
    let needsIntroduction: Bool
    let totalAttempts: Int
    let recentAttempts: Int
    let recentCorrect: Int
}

struct ClockChallengeContext: Equatable, Sendable {
    let questionID: Int?
    let hour: Int
    let minute: Int
    let difficulty: String
    let language: RealtimeCoachLanguage
    let clockImageBase64: String?
    let clockImageMediaType: String
    let learner: ClockLearnerContext?

    init(
        questionID: Int? = nil,
        hour: Int,
        minute: Int,
        difficulty: String,
        language: RealtimeCoachLanguage,
        clockImageBase64: String? = nil,
        clockImageMediaType: String = "image/png",
        learner: ClockLearnerContext? = nil
    ) {
        self.questionID = questionID
        self.hour = hour
        self.minute = minute
        self.difficulty = difficulty
        self.language = language
        self.clockImageBase64 = clockImageBase64
        self.clockImageMediaType = clockImageMediaType
        self.learner = learner
    }

    init(
        questionID: Int? = nil,
        hour: Int,
        minute: Int,
        difficulty: String,
        language: RealtimeCoachLanguage,
        clockImageData: Data,
        clockImageMediaType: String = "image/png",
        learner: ClockLearnerContext? = nil
    ) {
        self.init(
            questionID: questionID,
            hour: hour,
            minute: minute,
            difficulty: difficulty,
            language: language,
            clockImageBase64: clockImageData.base64EncodedString(),
            clockImageMediaType: clockImageMediaType,
            learner: learner
        )
    }

    var twelveHour: Int {
        let normalized = hour % 12
        return normalized == 0 ? 12 : normalized
    }
}

struct ClockAnswerReport: Codable, Equatable, Sendable {
    let hour: Int?
    let minute: Int?
    let unknown: Bool
}

struct ClockAnswerToolResult: Codable, Equatable, Sendable {
    let accepted: Bool
    let correct: Bool?
    let expectedHour: Int?
    let expectedMinute: Int?

    static let ungraded = ClockAnswerToolResult(
        accepted: true,
        correct: nil,
        expectedHour: nil,
        expectedMinute: nil
    )
}

protocol ClockAnswerToolHandling: Sendable {
    func handle(
        report: ClockAnswerReport,
        challenge: ClockChallengeContext?
    ) async -> ClockAnswerToolResult
}

struct DeterministicClockAnswerHandler: ClockAnswerToolHandling {
    func handle(
        report: ClockAnswerReport,
        challenge: ClockChallengeContext?
    ) async -> ClockAnswerToolResult {
        guard let challenge else { return .ungraded }

        let reportedHour = report.hour.map { value in
            let normalized = value % 12
            return normalized == 0 ? 12 : normalized
        }
        let isCorrect = !report.unknown
            && reportedHour == challenge.twelveHour
            && report.minute == challenge.minute

        return ClockAnswerToolResult(
            accepted: true,
            correct: isCorrect,
            expectedHour: challenge.twelveHour,
            expectedMinute: challenge.minute
        )
    }
}

enum RealtimeConnectionState: Equatable, Sendable {
    case disconnected
    case requestingToken
    case connecting
    case connected(sessionID: String?)
}

enum RealtimeTranscriptSpeaker: Equatable, Sendable {
    case child
    case coach
}

struct RealtimeAPIError: Error, Equatable, Sendable {
    let type: String?
    let code: String?
    let message: String
    let parameter: String?
    let eventID: String?
}

enum RealtimeServiceEvent: Equatable, Sendable {
    case connectionStateChanged(RealtimeConnectionState)
    case speechStarted
    case speechStopped
    case transcriptDelta(speaker: RealtimeTranscriptSpeaker, text: String)
    case transcriptCompleted(speaker: RealtimeTranscriptSpeaker, text: String)
    case assistantAudio(data: Data, responseID: String)
    case assistantAudioFinished(responseID: String)
    case spokenCorrectAnswerFeedbackFinished(responseID: String, questionID: Int?)
    case clockAnswerReported(ClockAnswerReport, ClockAnswerToolResult)
    case liveClockAnswerReported(ClockAnswerReport, ClockAnswerToolResult, questionID: Int)
    case liveAdvanceRequested(questionID: Int)
    case serverError(RealtimeAPIError)
}

enum RealtimeServiceError: LocalizedError, Equatable, Sendable {
    case alreadyConnected
    case notConnected
    case audioUnavailable
    case expiredClientSecret
    case malformedServerEvent
    case invalidAudioChunk
    case invalidChallenge
    case unsupportedWebSocketMessage

    var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            "A Realtime session is already active."
        case .notConnected:
            "The Realtime session is not connected."
        case .audioUnavailable:
            "Realtime microphone capture is not configured."
        case .expiredClientSecret:
            "The Realtime client secret expired before it could be used."
        case .malformedServerEvent:
            "The Realtime service returned an event that could not be read."
        case .invalidAudioChunk:
            "The audio chunk is not valid 24 kHz mono PCM16 data."
        case .invalidChallenge:
            "The clock challenge contains an invalid time or image type."
        case .unsupportedWebSocketMessage:
            "The Realtime service returned an unsupported WebSocket message."
        }
    }
}
