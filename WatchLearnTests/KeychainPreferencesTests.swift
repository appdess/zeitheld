import Foundation
import XCTest
@testable import WatchLearn

@MainActor
final class KeychainPreferencesTests: XCTestCase {
    func testRealKeychainSurvivesStoreRecreationAndDeletesOnlyItsOwnItem() throws {
        let service = "com.dessdynamics.watchlearn.tests." + UUID().uuidString
        let first = KeychainSecureStore(service: service)
        defer {
            try? first.removeValue(for: "credential")
            try? first.removeValue(for: "other")
        }
        let fixture = Data("synthetic-keychain-value".utf8)
        try first.set(fixture, for: "credential")
        try first.set(Data("other-value".utf8), for: "other")
        let recreated = KeychainSecureStore(service: service)
        XCTAssertEqual(try recreated.data(for: "credential"), fixture)
        try recreated.removeValue(for: "credential")
        XCTAssertNil(try first.data(for: "credential"))
        XCTAssertEqual(try first.data(for: "other"), Data("other-value".utf8))
    }

    func testStoresLoadsAndDeletesAPIKeyThroughSecureStoreOnly() throws {
        let secureStore = InMemorySecureStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let preferences = ParentPreferences(secureStore: secureStore, defaults: defaults)

        XCTAssertFalse(preferences.hasStoredAPIKey)
        try preferences.storeAPIKey("sk-test-abcdefghijklmnopqrstuvwxyz")
        XCTAssertTrue(preferences.hasStoredAPIKey)
        XCTAssertEqual(try preferences.apiKeyForEphemeralTokenRequest(), "sk-test-abcdefghijklmnopqrstuvwxyz")
        XCTAssertNil(defaults.string(forKey: "openai-api-key"))

        try preferences.deleteAPIKey()
        XCTAssertFalse(preferences.hasStoredAPIKey)
        XCTAssertNil(try preferences.apiKeyForEphemeralTokenRequest())
    }

    func testRejectsInvalidKeyWithoutPersistingIt() throws {
        let secureStore = InMemorySecureStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        let preferences = ParentPreferences(secureStore: secureStore, defaults: defaults)

        XCTAssertThrowsError(try preferences.storeAPIKey("not-a-key"))
        XCTAssertFalse(preferences.hasStoredAPIKey)
    }

    func testRejectsEmbeddedWhitespaceAndNonASCIIKeys() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        let preferences = ParentPreferences(secureStore: InMemorySecureStore(), defaults: defaults)
        for key in ["sk-test-abcdefghijklmnop qrst", "sk-test-abcdefghijklmnop\nqrst", "sk-test-abcdefghijklmnopéqrst"] {
            XCTAssertThrowsError(try preferences.storeAPIKey(key))
        }
        XCTAssertFalse(preferences.hasStoredAPIKey)
    }

    func testConnectionCheckRequiresConsentAndStoredKey() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let preferences = ParentPreferences(secureStore: InMemorySecureStore(), defaults: defaults,
                                            connectionChecker: FixtureConnectionChecker())
        await preferences.checkVoiceConnection()
        XCTAssertEqual(preferences.connectionCheck, .idle)
        preferences.cloudVoiceMode = .parentKey
        try preferences.storeAPIKey("sk-fixture-never-real-abcdef")
        XCTAssertFalse(preferences.canCheckVoiceConnection)
        preferences.hasCloudVoiceConsent = true
        await preferences.checkVoiceConnection()
        XCTAssertEqual(preferences.connectionCheck, .connected)
        preferences.language = .english
        XCTAssertEqual(preferences.connectionCheck, .idle)
        await preferences.checkVoiceConnection()
        XCTAssertEqual(preferences.connectionCheck, .connected)
        try preferences.deleteAPIKey()
        XCTAssertEqual(preferences.connectionCheck, .idle)
        XCTAssertFalse(preferences.canCheckVoiceConnection)
    }

    func testFailedCheckUsesRedactedLocalizedError() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let preferences = ParentPreferences(secureStore: InMemorySecureStore(), defaults: defaults,
                                            connectionChecker: FixtureConnectionChecker(shouldFail: true))
        preferences.cloudVoiceMode = .parentKey
        try preferences.storeAPIKey("sk-fixture-never-real-abcdef")
        preferences.hasCloudVoiceConsent = true
        await preferences.checkVoiceConnection()
        guard case let .failed(failure) = preferences.connectionCheck else { return XCTFail("Expected failure") }
        XCTAssertEqual(failure.code, .credentialUnauthorized)
        XCTAssertFalse(failure.localizedMessage(language: .german).contains("fixture"))
    }

    func testCancelledConnectionCheckDoesNotClaimSuccess() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let preferences = ParentPreferences(secureStore: InMemorySecureStore(), defaults: defaults,
                                            connectionChecker: FixtureConnectionChecker(delay: true))
        preferences.cloudVoiceMode = .parentKey
        try preferences.storeAPIKey("sk-fixture-never-real-abcdef")
        preferences.hasCloudVoiceConsent = true
        let task = Task { await preferences.checkVoiceConnection() }
        let deadline = Date().addingTimeInterval(2)
        while preferences.connectionCheck != .checking && Date() < deadline { await Task.yield() }
        XCTAssertEqual(preferences.connectionCheck, .checking)
        preferences.revokeCloudConsent()
        task.cancel()
        await task.value
        XCTAssertEqual(preferences.connectionCheck, .idle)
    }

    func testBrokerRequiresHTTPS() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        let preferences = ParentPreferences(secureStore: InMemorySecureStore(), defaults: defaults)

        preferences.brokerURLText = "http://localhost:8080/token"
        XCTAssertThrowsError(try preferences.validatedBrokerURL())
        preferences.brokerURLText = "https://voice.example.com/token"
        XCTAssertEqual(try preferences.validatedBrokerURL().host, "voice.example.com")
    }

    func testSafetyIdentifierIsRandomNonPIIAndStableForTheInstall() throws {
        let suiteName = #function
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let first = ParentPreferences(
            secureStore: InMemorySecureStore(),
            defaults: defaults
        )
        let identifier = first.realtimeSafetyIdentifier
        XCTAssertNotNil(UUID(uuidString: identifier))

        let second = ParentPreferences(
            secureStore: InMemorySecureStore(),
            defaults: defaults
        )
        XCTAssertEqual(second.realtimeSafetyIdentifier, identifier)
    }

    func testVoiceAndHeroCloudConsentsAreIndependent() throws {
        let suiteName = #function
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let preferences = ParentPreferences(
            secureStore: InMemorySecureStore(),
            defaults: defaults
        )

        preferences.hasCloudVoiceConsent = true
        preferences.hasHeroGenerationConsent = true
        preferences.revokeCloudConsent()

        XCTAssertFalse(preferences.hasCloudVoiceConsent)
        XCTAssertTrue(preferences.hasHeroGenerationConsent)
        preferences.revokeHeroGenerationConsent()
        XCTAssertFalse(preferences.hasHeroGenerationConsent)
    }
}

private final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    func data(for key: String) -> Data? {
        lock.withLock { values[key] }
    }

    func set(_ data: Data, for key: String) {
        lock.withLock { values[key] = data }
    }

    func removeValue(for key: String) {
        _ = lock.withLock { values.removeValue(forKey: key) }
    }
}

private struct FixtureConnectionChecker: LiveConnectionChecking {
    var shouldFail = false
    var delay = false
    func check(credential: VoiceCoachCredential,
               language: RealtimeCoachLanguage,
               safetyIdentifier: RealtimeSafetyIdentifier) async throws {
        if delay { try await Task.sleep(for: .seconds(30)) }
        if shouldFail { throw RealtimeClientSecretProviderError.httpStatus(401, requestID: "sk-fixture-private") }
    }
}
