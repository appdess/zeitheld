import Foundation
import Observation

enum LiveConnectionStage: String, Codable, Sendable {
    case dataChannel, offer, localDescription, iceGathering, sessionRequest
    case sessionResponse, remoteDescription, sessionStarted, transport
}

struct LiveConnectionSetupError: Error {
    let stage: LiveConnectionStage
    let underlying: Error
}

/// Fixed metadata only. No error descriptions, tokens, URLs, session identifiers,
/// SDP, audio, questions or transcripts enter the persisted support history.
@MainActor @Observable
final class LiveConnectionHistory {
    enum Operation: String, Codable { case conversation, accessCheck, cleanup, answerCheck }
    enum Outcome: String, Codable { case started, connected, failed, retrying, cancelled, stopped }
    struct Entry: Codable, Identifiable {
        let id: UUID
        let date: Date
        let operation: Operation
        let outcome: Outcome
        let mode: CloudVoiceMode
        let attempt: Int
        let stage: VoiceCoachStartupStage?
        let detail: LiveConnectionStage?
        let code: VoiceCoachFailureCode?
        let build: Int

        var supportLine: String {
            [date.ISO8601Format(), operation.rawValue, outcome.rawValue, mode.rawValue,
             "attempt=\(attempt)", "build=\(build)", stage?.rawValue, detail?.rawValue, code?.rawValue]
                .compactMap { $0 }.joined(separator: " | ")
        }
    }
    static let storageKey = "live.connection-history.v1"
    static let maximumEntries = 40
    private let defaults: UserDefaults
    private(set) var entries: [Entry]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: Self.storageKey) ?? Data()
        let stored = data.count <= 64_000 ? (try? JSONDecoder().decode([Entry].self, from: data)) ?? [] : []
        entries = Array(stored.filter { $0.date > Date().addingTimeInterval(-7 * 86400) }
            .prefix(Self.maximumEntries))
        persist()
    }

    func record(_ outcome: Outcome, operation: Operation = .conversation, mode: CloudVoiceMode,
                attempt: Int = 1, stage: VoiceCoachStartupStage? = nil, error: Error? = nil) {
        let entry = Entry(id: UUID(), date: Date(), operation: operation, outcome: outcome, mode: mode,
                          attempt: min(3, max(1, attempt)), stage: stage,
                          detail: (error as? LiveConnectionSetupError)?.stage,
                          code: error.map { VoiceCoachFailure(error: $0).code },
                          build: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0)
        entries = Array(([entry] + entries).filter { $0.date > Date().addingTimeInterval(-7 * 86400) }
            .prefix(Self.maximumEntries))
        persist()
    }

    var report: String { (["Time Hero connection report"] + entries.map(\.supportLine)).joined(separator: "\n") }
    func clear() { entries = []; defaults.removeObject(forKey: Self.storageKey) }
    private func persist() { defaults.set(try? JSONEncoder().encode(entries), forKey: Self.storageKey) }
}

enum LiveConnectionRetryPolicy {
    static let maximumAttempts = 3
    static func permits(_ code: VoiceCoachFailureCode) -> Bool {
        switch code {
        case .networkOffline, .networkTimeout, .connectionLost, .serviceUnavailable, .cleanupPending: true
        default: false
        }
    }
    static func delay(beforeAttempt attempt: Int) -> Duration { .seconds(attempt >= 3 ? 3 : 1) }
}

/// ICE may recover during a brief Wi-Fi/cellular handover. Fail only after a
/// continuous gap, or immediately for terminal ICE/data-channel failure.
struct LiveTransportHealth {
    enum State: Sendable { case connected, disconnected, failed }
    enum Decision { case healthy, waiting, failed }
    static let graceSeconds: TimeInterval = 5
    private var disconnectedAt: TimeInterval?

    func remainingGrace(at now: TimeInterval) -> TimeInterval {
        max(0, Self.graceSeconds - (now - (disconnectedAt ?? now)))
    }

    mutating func observe(_ state: State, at now: TimeInterval) -> Decision {
        switch state {
        case .connected:
            disconnectedAt = nil
            return .healthy
        case .failed:
            return .failed
        case .disconnected:
            if let disconnectedAt, now - disconnectedAt >= Self.graceSeconds { return .failed }
            if disconnectedAt == nil { disconnectedAt = now }
            return .waiting
        }
    }
}
