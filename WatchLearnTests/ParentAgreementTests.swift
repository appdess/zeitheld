import XCTest
@testable import WatchLearn

@MainActor
final class ParentAgreementTests: XCTestCase {
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
}

private struct AgreementTestSecureStore: SecureStore {
    func data(for key: String) throws -> Data? { nil }
    func set(_ data: Data, for key: String) throws {}
    func removeValue(for key: String) throws {}
}
