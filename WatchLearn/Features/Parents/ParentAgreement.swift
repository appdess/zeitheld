import Foundation

struct ParentAgreement: Codable, Equatable, Sendable {
    static let currentVersion = "2026-09-11.1"
    var version = currentVersion
    var locale: String
    var guardian = false
    var privacyAcknowledged = false
    var termsAccepted = false
    var voice = false
    var hero = false
    var adultTestOnly = false

    var isValid: Bool {
        version == Self.currentVersion && ["de", "en"].contains(locale)
            && guardian && privacyAcknowledged && termsAccepted
            && (!(voice || hero) || adultTestOnly)
    }
}

struct ParentAgreementAcceptance: Codable, Equatable, Sendable {
    let document: ParentAgreement
    let acceptedAt: Date
    var accountID: String?
    var serverAcceptedAt: Double?
}

struct ParentConsentReceipt: Decodable, Sendable {
    let version: String?
    let requiredVersion: String
    let current: Bool
    let voice: Bool
    let hero: Bool
    let acceptedAt: Double?
    let updatedAt: Double?
    let status: String

    var isCurrent: Bool { current && version == ParentAgreement.currentVersion }
}

struct ParentConsentResponse: Decodable {
    let consent: ParentConsentReceipt
    let cleanupPending: Bool
}
