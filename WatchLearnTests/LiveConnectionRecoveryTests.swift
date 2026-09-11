import Foundation
import XCTest
@testable import WatchLearn

@MainActor
final class LiveConnectionRecoveryTests: XCTestCase {
    private var domain = ""
    private var defaults: UserDefaults!
    private var preferences: ParentPreferences!

    override func setUp() async throws {
        domain = "LiveRecoveryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)!
        preferences = ParentPreferences(secureStore: RecoveryEmptyStore(), defaults: defaults)
        preferences.cloudVoiceMode = .managedBroker
        preferences.brokerURLText = "https://fixture.invalid/token"
        preferences.hasCloudVoiceConsent = true
    }

    override func tearDown() async throws { defaults.removePersistentDomain(forName: domain) }

    private func question(_ id: Int = 1) -> TimeQuestion {
        .init(id: id, time: .init(hour: 3, minute: 0), level: .fullHour,
              choices: [.init(hour: 3, minute: 0)], heroTheme: .skyGuardian)
    }

    private func coordinator(_ sessions: [RecoverySession], gate: RecoveryGate? = nil,
                             onCreate: @escaping (Int) -> Void = { _ in }) -> VoiceCoachCoordinator {
        var created = 0
        return VoiceCoachCoordinator(microphonePermission: RecoveryPermission(), sessionFactory: { _ in
            onCreate(created)
            let session = sessions[min(created, sessions.count - 1)]
            created += 1
            return .init(service: session, audioEngine: session)
        }, retrySleep: { _ in
            if let gate { await gate.wait() }
            try Task.checkCancellation()
        })
    }

    func testTransientStartupRetriesOnlyAfterCleanupAndStartsAudioOnce() async throws {
        let first = RecoverySession(openError: URLError(.timedOut))
        let second = RecoverySession()
        let coach = coordinator([first, second]) { index in
            if index == 1 { XCTAssertEqual(first.disconnects, 1); XCTAssertFalse(first.capturing) }
        }
        await coach.start(question: question(), preferences: preferences)
        XCTAssertTrue(coach.isSessionActive)
        XCTAssertEqual(coach.connectionAttempt, 2)
        XCTAssertEqual(first.audioStarts, 0)
        XCTAssertEqual(second.audioStarts, 1)
        XCTAssertEqual(preferences.connectionHistory.entries.map(\.outcome).reversed(), [.started, .failed, .retrying, .started, .connected])
        await coach.stop()
    }

    func testRetryBudgetEndsAfterThreeAttempts() async {
        let sessions = (0..<3).map { _ in RecoverySession(openError: URLError(.networkConnectionLost)) }
        let coach = coordinator(sessions)
        await coach.start(question: question(), preferences: preferences)
        XCTAssertEqual(sessions.map(\.opens), [1, 1, 1])
        XCTAssertEqual(sessions.map(\.disconnects), [1, 1, 1])
        XCTAssertFalse(coach.isStarting)
        XCTAssertFalse(coach.isSessionActive)
        guard case .failed(let message) = coach.phase else { return XCTFail("Expected bounded failure") }
        XCTAssertTrue(message.contains("VC-NETWORK-OFFLINE"))
    }

    func testAccessPrivacyQuotaAndProtocolFailuresDoNotRetry() async {
        let errors: [Error] = [ManagedAccountError.signInRequired, ManagedAccountError.agreementRequired,
                              ManagedAccountError.trialExhausted, ManagedAccountError.serviceLimit,
                              ManagedAccountError.sessionAlreadyActive, ManagedAccountError.malformedResponse,
                              LiveServiceError.accessDenied, RealtimeAudioEngineError.audioEngineStartFailed]
        for error in errors {
            let session = RecoverySession(openError: error)
            let coach = coordinator([session])
            await coach.start(question: question(), preferences: preferences)
            XCTAssertEqual(session.opens, 1)
            XCTAssertFalse(coach.isSessionActive)
            await coach.stop()
        }
    }

    func testStopDuringBackoffPreventsASecondSession() async throws {
        let gate = RecoveryGate()
        let first = RecoverySession(openError: URLError(.timedOut))
        let second = RecoverySession()
        let coach = coordinator([first, second], gate: gate)
        let task = Task { await coach.start(question: question(), preferences: preferences) }
        try await eventually { coach.connectionAttempt == 2 }
        await gate.waitUntilSuspended()
        coach.stopLocalAudioImmediately()
        await gate.release()
        await coach.stop()
        await task.value
        XCTAssertEqual(second.opens, 0)
        XCTAssertEqual(second.audioStarts, 0)
        XCTAssertEqual(coach.phase, .idle)
    }

    func testRecoveryWaitsForClosingAndUsesTheLatestClock() async throws {
        let closeGate = RecoveryGate()
        let first = RecoverySession(closeGate: closeGate)
        let second = RecoverySession()
        let coach = coordinator([first, second])
        await coach.start(question: question(), preferences: preferences)
        first.emitLoss()
        await closeGate.waitUntilSuspended()
        XCTAssertEqual(second.opens, 0)
        XCTAssertFalse(first.capturing)
        await coach.updateChallenge(question(9))
        await closeGate.release()
        try await eventually { second.audioStarts == 1 }
        XCTAssertEqual(second.questions, [9])
        XCTAssertTrue(coach.isSessionActive)
        await coach.stop()
    }

    func testRepeatedDropsShareTheOriginalBudgetAndIgnoreLateEvents() async throws {
        let sessions = (0..<3).map { _ in RecoverySession() }
        let coach = coordinator(sessions)
        await coach.start(question: question(), preferences: preferences)
        for index in 0..<2 {
            sessions[index].emitLoss()
            try await eventually { sessions[index + 1].audioStarts == 1 && !coach.isStarting }
            sessions[index].emit(.assistantAudio(data: Data(), responseID: "stale"))
        }
        sessions[2].emitLoss()
        try await eventually { if case .failed = coach.phase { return true }; return false }
        XCTAssertEqual(sessions.map(\.opens), [1, 1, 1])
        XCTAssertEqual(coach.connectionAttempt, 3)
        XCTAssertFalse(coach.isSessionActive)
        await coach.stop()
    }

    func testNormalProviderEndDoesNotCreateAnotherPaidSession() async throws {
        let first = RecoverySession(), second = RecoverySession()
        let coach = coordinator([first, second])
        await coach.start(question: question(), preferences: preferences)
        first.emit(.connectionStateChanged(.disconnected))
        try await eventually { first.disconnects == 1 }
        XCTAssertFalse(first.capturing)
        XCTAssertFalse(coach.isSessionActive)
        XCTAssertEqual(second.opens, 0)
        XCTAssertEqual(coach.phase, .idle)
    }

    func testICEGraceAllowsBriefHandoverButBoundsContinuousLoss() {
        var health = LiveTransportHealth()
        XCTAssertEqual(health.observe(.disconnected, at: 10), .waiting)
        XCTAssertEqual(health.observe(.disconnected, at: 14), .waiting)
        XCTAssertEqual(health.observe(.connected, at: 14.5), .healthy)
        XCTAssertEqual(health.observe(.disconnected, at: 20), .waiting)
        XCTAssertEqual(health.observe(.disconnected, at: 25), .failed)
        XCTAssertEqual(health.observe(.failed, at: 26), .failed)
    }

    func testHistorySurvivesRelaunchIsBoundedAndContainsOnlySafeMetadata() throws {
        let history = preferences.connectionHistory
        let error = RealtimeAPIError(type: "private", code: "invalid_api_key",
                                    message: "sk-private-key child transcript", parameter: "private", eventID: "private-session")
        for _ in 0..<50 {
            history.record(.failed, mode: .parentKey, stage: .connection,
                           error: LiveConnectionSetupError(stage: .sessionRequest, underlying: error))
        }
        let reloaded = LiveConnectionHistory(defaults: defaults)
        XCTAssertEqual(reloaded.entries.count, 40)
        XCTAssertEqual(reloaded.entries.first?.detail, .sessionRequest)
        XCTAssertEqual(reloaded.entries.first?.code, .credentialUnauthorized)
        let persisted = String(decoding: try XCTUnwrap(defaults.data(forKey: LiveConnectionHistory.storageKey)), as: UTF8.self)
        for unsafe in ["sk-private", "child transcript", "private-session", "https://", "v=0"] {
            XCTAssertFalse(persisted.contains(unsafe))
            XCTAssertFalse(reloaded.report.contains(unsafe))
        }
        reloaded.clear()
        XCTAssertTrue(LiveConnectionHistory(defaults: defaults).entries.isEmpty)
    }

    func testPendingCloseSurvivesRelaunchAndCannotCrossAccountOrBackend() async throws {
        let base = URL(string: "https://fixture.invalid")!
        let first = PendingLiveSessionStore(defaults: defaults)
        let id = UUID().uuidString
        first.register(id, baseURL: base, ownerID: "synthetic-owner")
        XCTAssertTrue(first.pending(baseURL: base, ownerID: "synthetic-owner").isEmpty)
        let relaunched = PendingLiveSessionStore(defaults: defaults)
        XCTAssertEqual(relaunched.pending(baseURL: base, ownerID: "synthetic-owner"), [id])
        XCTAssertTrue(relaunched.pending(baseURL: base, ownerID: "different-owner").isEmpty)
        XCTAssertTrue(relaunched.pending(baseURL: URL(string: "https://other.invalid")!, ownerID: "synthetic-owner").isEmpty)
        do {
            try await relaunched.reconcile(baseURL: base, ownerID: "synthetic-owner") { _ in throw URLError(.timedOut) }
            XCTFail("Expected failed cleanup")
        } catch {}
        XCTAssertEqual(relaunched.pending(baseURL: base, ownerID: "synthetic-owner"), [id])
        try await relaunched.reconcile(baseURL: base, ownerID: "synthetic-owner") { closing in XCTAssertEqual(closing, id) }
        XCTAssertTrue(PendingLiveSessionStore(defaults: defaults).pending(baseURL: base, ownerID: "synthetic-owner").isEmpty)
    }

    func testManagedHTTPFailuresKeepTheirActionableClassification() {
        let cases: [(Int, String, VoiceCoachFailureCode)] = [
            (401, "sign_in_required", .credentialUnauthorized), (402, "trial_exhausted", .trialExhausted),
            (403, "agreement_required", .agreementRequired), (409, "session_already_active", .sessionAlreadyActive),
            (429, "rate_limit", .credentialRateLimited), (503, "service_daily_limit", .serviceLimit),
            (503, "provider_unavailable", .serviceUnavailable), (503, "close_in_progress", .cleanupPending)
        ]
        for (status, code, expected) in cases {
            let data = Data("{\"error\":\"\(code)\"}".utf8)
            XCTAssertEqual(VoiceCoachFailure(error: ManagedAccountError.responseError(status: status, data: data)).code, expected)
        }
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for recovery")
        throw URLError(.timedOut)
    }
}

private struct RecoveryPermission: MicrophonePermissionProviding {
    func currentPermission() -> MicrophonePermission { .granted }
    func requestPermission() async -> Bool { true }
}
private struct RecoveryEmptyStore: SecureStore {
    func data(for key: String) throws -> Data? { nil }
    func set(_ data: Data, for key: String) throws {}
    func removeValue(for key: String) throws {}
}

private actor RecoveryGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilSuspended() async {
        for _ in 0..<200 {
            if waiter != nil { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

@MainActor
private final class RecoverySession: VoiceCoachingService, VoiceCoachAudioManaging {
    nonisolated let events: AsyncStream<RealtimeServiceEvent>
    private let continuation: AsyncStream<RealtimeServiceEvent>.Continuation
    private let openError: Error?
    private let closeGate: RecoveryGate?
    private let authorization = RealtimeAudioCaptureAuthorizationState()
    var opens = 0, disconnects = 0, audioStarts = 0
    var capturing = false
    var questions: [Int] = []

    init(openError: Error? = nil, closeGate: RecoveryGate? = nil) {
        self.openError = openError; self.closeGate = closeGate
        let stream = AsyncStream.makeStream(of: RealtimeServiceEvent.self)
        events = stream.stream; continuation = stream.continuation
    }
    func open(language: RealtimeCoachLanguage, safetyIdentifier: RealtimeSafetyIdentifier) async throws {
        opens += 1
        if let openError { throw openError }
    }
    func setChallenge(_ value: ClockChallengeContext) async throws { if let id = value.questionID { questions.append(id) } }
    func startVoice(authorizedBy value: RealtimeAudioCaptureAuthorization) async throws {
        try authorization.validate(value); audioStarts += 1; capturing = true
    }
    func disconnect() async { disconnects += 1; stopAll(); if let closeGate { await closeGate.wait() } }
    func emit(_ event: RealtimeServiceEvent) { continuation.yield(event) }
    func emitLoss() { emit(.serverError(.init(type: nil, code: "connection_lost", message: "fixture", parameter: nil, eventID: nil))) }
    func authorizeCaptureStart() -> RealtimeAudioCaptureAuthorization { authorization.issue() }
    func startCapture(authorizedBy value: RealtimeAudioCaptureAuthorization, onPCM16Chunk: @escaping @Sendable (Data) -> Void, onCaptureFailure: @escaping @Sendable (RealtimeAudioEngineError) -> Void) async throws { try await startVoice(authorizedBy: value) }
    func stopCapture() { authorization.revoke(); capturing = false }
    func stopPlayback() {}
    func stopAll() { stopCapture() }
    func setInterruptionHandler(_ handler: (@Sendable (Bool) -> Void)?) {}
    func enqueuePCM16(_ data: Data, itemID: String?, responseID: String) throws {}
    func notifyWhenPlaybackDrained(responseID: String, onDrained: @escaping @Sendable (String) -> Void) {}
}
