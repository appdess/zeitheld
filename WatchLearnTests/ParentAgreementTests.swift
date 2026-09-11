import XCTest
import CryptoKit
@testable import WatchLearn

@MainActor
final class ParentAgreementTests: XCTestCase {
    func testAppleNonceSurvivesFirebaseFormEncodingForEveryByteValue() throws {
        for byte in UInt8.min...UInt8.max {
            let nonce = AppleSignInNonce(randomBytes: Array(repeating: byte, count: 32))
            XCTAssertEqual(nonce.rawValue.count, 64)
            XCTAssertTrue(nonce.rawValue.allSatisfy { "0123456789abcdef".contains($0) })
            let received = try firebaseFormRoundTrip(nonce.rawValue)
            XCTAssertEqual(received, nonce.rawValue)
            let receivedHash = SHA256.hash(data: Data(received.utf8))
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(receivedHash, nonce.sha256)
        }
    }

    func testOldBase64NonceReproducesTheIntermittentMismatch() throws {
        let legacy = Data(repeating: 251, count: 32).base64EncodedString()
        XCTAssertTrue(legacy.contains("+"))
        XCTAssertNotEqual(try firebaseFormRoundTrip(legacy), legacy)
    }

    private func firebaseFormRoundTrip(_ nonce: String) throws -> String {
        // Same URLComponents.query serialization as the pinned Firebase SDK's
        // VerifyAssertionRequest, followed by standard form decoding.
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "nonce", value: nonce)]
        let body = try XCTUnwrap(components.query)
        let value = String(body.dropFirst("nonce=".count))
        return try XCTUnwrap(value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding)
    }

    func testSignInDiagnosticsNeverContainProviderDetails() {
        let error = NSError(domain: NSURLErrorDomain, code: -1009,
                            userInfo: [NSLocalizedDescriptionKey: "private-token-and-account-details"])
        let failure = ParentSignInFailure(error: error, stage: .firebase)
        XCTAssertEqual(failure.supportCode, "AUTH-FIREBASE-NETWORK--1009")
        XCTAssertFalse(failure.message.contains("private-token"))
    }

    func testCancelledAppleAuthorizationClearsBusyWithoutReportingFailure() async {
        let account = ParentAccount()
        await account.completeApple(.failure(NSError(domain: "com.apple.AuthenticationServices.AuthorizationError", code: 1001)))
        XCTAssertFalse(account.busy)
        XCTAssertNil(account.message)
    }

    private func document() -> ParentAgreement {
        ParentAgreement(locale: "de", guardian: true, privacyAcknowledged: true,
                        termsAccepted: true, voice: true, hero: false, adultTestOnly: true)
    }

    func testFirstUseHasNoPreselectedPermissionsAndRequiresExplicitConfirmation() {
        let initial = ParentAgreement(locale: "en")
        XCTAssertFalse(initial.isValid)
        XCTAssertFalse(initial.voice)
        XCTAssertFalse(initial.hero)
        XCTAssertFalse(initial.guardian)
        var value = document()
        XCTAssertTrue(value.isValid)
        value.adultTestOnly = false
        XCTAssertFalse(value.isValid)
        value.voice = false
        XCTAssertTrue(value.isValid, "Account-only/offline choice needs no optional AI consent")
        value.version = "old-notice"
        XCTAssertFalse(value.isValid)
    }

    func testLegacyFeatureSwitchesDoNotBecomeAcceptanceAndManagedSignupDoesNotEnableCloudBeforeReceipt() throws {
        let name = #function, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.removePersistentDomain(forName: name)
        defaults.set(true, forKey: "parent.cloud-consent")
        defaults.set(true, forKey: "parent.hero-generation-consent")
        let preferences = ParentPreferences(secureStore: AgreementTestSecureStore(), defaults: defaults)
        XCTAssertFalse(preferences.hasCloudVoiceConsent)
        XCTAssertFalse(preferences.hasHeroGenerationConsent)
        XCTAssertFalse(preferences.hasCurrentAgreement)
        preferences.recordAgreement(document())
        XCTAssertTrue(preferences.hasCurrentAgreement)
        XCTAssertFalse(preferences.hasCloudVoiceConsent)
        XCTAssertFalse(preferences.hasHeroGenerationConsent)
    }

    func testReceiptBindsChoicesAndWithdrawalPersistsAcrossRelaunch() throws {
        let name = #function, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.removePersistentDomain(forName: name)
        let preferences = ParentPreferences(secureStore: AgreementTestSecureStore(), defaults: defaults)
        let receipt = ParentConsentReceipt(version: ParentAgreement.currentVersion,
            requiredVersion: ParentAgreement.currentVersion, current: true, voice: true, hero: false,
            acceptedAt: 1000, updatedAt: 1000, status: "active")
        preferences.recordAgreement(document(), accountID: "synthetic-parent", receipt: receipt)
        XCTAssertTrue(preferences.hasCloudVoiceConsent)
        XCTAssertFalse(preferences.hasHeroGenerationConsent)
        let restored = ParentPreferences(secureStore: AgreementTestSecureStore(), defaults: defaults)
        XCTAssertEqual(restored.agreementAcceptance?.accountID, "synthetic-parent")
        XCTAssertEqual(restored.agreementAcceptance?.serverAcceptedAt, 1000)
        XCTAssertTrue(restored.hasCloudVoiceConsent)
        restored.clearAgreement()
        let withdrawn = ParentPreferences(secureStore: AgreementTestSecureStore(), defaults: defaults)
        XCTAssertFalse(withdrawn.hasCurrentAgreement)
        XCTAssertFalse(withdrawn.hasAnyOnlineFeatureEnabled)
    }

    func testSwitchingAccessMethodRequiresFreshLocalPermissionAndKeepsSavedChoices() throws {
        let name = #function, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.removePersistentDomain(forName: name)
        let preferences = ParentPreferences(secureStore: AgreementTestSecureStore(), defaults: defaults)
        preferences.selectCloudVoiceMode(.parentKey)
        preferences.recordAgreement(document())
        XCTAssertTrue(preferences.hasCloudVoiceConsent)
        preferences.selectCloudVoiceMode(.managedAccount)
        XCTAssertFalse(preferences.hasAnyOnlineFeatureEnabled)
        XCTAssertTrue(preferences.hasCurrentAgreement)
        preferences.selectCloudVoiceMode(.parentKey)
        XCTAssertFalse(preferences.hasAnyOnlineFeatureEnabled)
        // A fresh, explicit review can enable own-key use without Apple sign-in.
        preferences.recordAgreement(document())
        XCTAssertTrue(preferences.hasCloudVoiceConsent)
        XCTAssertNil(preferences.agreementAcceptance?.accountID)
    }
}

private struct AgreementTestSecureStore: SecureStore {
    func data(for key: String) throws -> Data? { nil }
    func set(_ data: Data, for key: String) throws {}
    func removeValue(for key: String) throws {}
}
