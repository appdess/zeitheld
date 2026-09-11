import Foundation
import Observation

enum CloudVoiceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case offline
    case parentKey
    case managedBroker
    case managedAccount

    var id: String { rawValue }
}

enum InterfaceLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case german = "de"
    case english = "en"

    var id: String { rawValue }
}

enum ParentSettingsError: LocalizedError, Equatable {
    case invalidAPIKey
    case invalidBrokerURL

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "The API key format is not valid."
        case .invalidBrokerURL:
            return "Enter a secure HTTPS token-broker URL."
        }
    }
}

@MainActor
@Observable
final class ParentPreferences {
    private enum Keys {
        static let apiKey = "openai-api-key"
        static let language = "parent.language"
        static let followsDeviceLanguage = "parent.follows-device-language"
        static let cloudMode = "parent.cloud-mode"
        static let consent = "parent.cloud-consent"
        static let heroConsent = "parent.hero-generation-consent"
        static let agreement = "parent.agreement-acceptance.v1"
        static let brokerURL = "parent.broker-url"
        static let safetyIdentifier = "parent.realtime-safety-identifier"
    }

    private let secureStore: any SecureStore
    let connectionHistory: LiveConnectionHistory
    private let defaults: UserDefaults
    private let connectionChecker: any LiveConnectionChecking
    private var connectionRevision = 0
    private(set) var connectionCheck: LiveConnectionCheckState = .idle
    private(set) var agreementAcceptance: ParentAgreementAcceptance?
    var hasCurrentAgreement: Bool { agreementAcceptance?.document.isValid == true }

    var language: InterfaceLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language); invalidateConnectionCheck() }
    }

    var followsDeviceLanguage: Bool {
        didSet {
            defaults.set(followsDeviceLanguage, forKey: Keys.followsDeviceLanguage)
            refreshDeviceLanguage()
        }
    }

    static func deviceLanguage(preferredLanguages: [String] = Locale.preferredLanguages) -> InterfaceLanguage {
        preferredLanguages.first?.lowercased().hasPrefix("de") == true ? .german : .english
    }

    func refreshDeviceLanguage() {
        if followsDeviceLanguage { language = Self.deviceLanguage() }
    }

    var cloudVoiceMode: CloudVoiceMode {
        didSet { defaults.set(cloudVoiceMode.rawValue, forKey: Keys.cloudMode); invalidateConnectionCheck() }
    }

    var hasCloudVoiceConsent: Bool {
        didSet { defaults.set(hasCloudVoiceConsent, forKey: Keys.consent); invalidateConnectionCheck() }
    }

    var hasHeroGenerationConsent: Bool {
        didSet { defaults.set(hasHeroGenerationConsent, forKey: Keys.heroConsent) }
    }

    var hasAnyOnlineFeatureEnabled: Bool {
        hasCloudVoiceConsent || hasHeroGenerationConsent
    }

    var brokerURLText: String {
        didSet { defaults.set(brokerURLText, forKey: Keys.brokerURL); invalidateConnectionCheck() }
    }

    private(set) var hasStoredAPIKey: Bool
    private(set) var lastErrorMessage: String?

    /// Random, install-scoped identifier used only to let OpenAI apply abuse
    /// controls consistently. It contains no child or parent information.
    let realtimeSafetyIdentifier: String

    init(
        secureStore: any SecureStore = KeychainSecureStore(),
        defaults: UserDefaults = .standard,
        connectionChecker: any LiveConnectionChecking = LiveConnectionChecker()
    ) {
        self.secureStore = secureStore
        self.defaults = defaults
        self.connectionHistory = LiveConnectionHistory(defaults: defaults)
        self.connectionChecker = connectionChecker
        // Existing explicit choices remain valid; new installations follow iOS.
        let followsDevice = defaults.object(forKey: Keys.followsDeviceLanguage) as? Bool
            ?? (defaults.string(forKey: Keys.language) == nil)
        self.followsDeviceLanguage = followsDevice
        self.language = followsDevice ? Self.deviceLanguage() : (InterfaceLanguage(
            rawValue: defaults.string(forKey: Keys.language) ?? "en"
        ) ?? .english)
        let storedBrokerURL = defaults.string(forKey: Keys.brokerURL) ?? ""
        let storedMode = CloudVoiceMode(
            rawValue: defaults.string(forKey: Keys.cloudMode) ?? "managedAccount"
        ) ?? .managedAccount
        self.cloudVoiceMode = storedMode == .managedBroker && storedBrokerURL.isEmpty
            ? .parentKey
            : storedMode
        let acceptance = defaults.data(forKey: Keys.agreement).flatMap {
            try? JSONDecoder().decode(ParentAgreementAcceptance.self, from: $0)
        }
        self.agreementAcceptance = acceptance?.document.isValid == true ? acceptance : nil
        self.hasCloudVoiceConsent = acceptance?.document.isValid == true && defaults.bool(forKey: Keys.consent)
        self.hasHeroGenerationConsent = acceptance?.document.isValid == true && defaults.bool(forKey: Keys.heroConsent)
        self.brokerURLText = storedBrokerURL
        self.hasStoredAPIKey = (try? secureStore.data(for: Keys.apiKey)) != nil
        if let storedIdentifier = defaults.string(forKey: Keys.safetyIdentifier),
           UUID(uuidString: storedIdentifier) != nil {
            self.realtimeSafetyIdentifier = storedIdentifier
        } else {
            let identifier = UUID().uuidString
            self.realtimeSafetyIdentifier = identifier
            defaults.set(identifier, forKey: Keys.safetyIdentifier)
        }
    }

    func storeAPIKey(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-") && (20...512).contains(trimmed.count),
              trimmed.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }),
              let data = trimmed.data(using: .utf8) else {
            throw ParentSettingsError.invalidAPIKey
        }
        try secureStore.set(data, for: Keys.apiKey)
        hasStoredAPIKey = true
        invalidateConnectionCheck()
        lastErrorMessage = nil
    }

    /// Keychain credential for authorized OpenAI requests. Never display,
    /// persist elsewhere, or log the returned value.
    func apiKeyForEphemeralTokenRequest() throws -> String? {
        guard let data = try secureStore.data(for: Keys.apiKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func apiKeyForVoiceConnection() throws -> String? {
        try apiKeyForEphemeralTokenRequest()
    }

    func deleteAPIKey() throws {
        try secureStore.removeValue(for: Keys.apiKey)
        hasStoredAPIKey = false
        if cloudVoiceMode == .parentKey {
            hasCloudVoiceConsent = false
            hasHeroGenerationConsent = false
        }
        invalidateConnectionCheck()
    }

    func validatedBrokerURL() throws -> URL {
        guard let url = URL(string: brokerURLText),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            throw ParentSettingsError.invalidBrokerURL
        }
        return url
    }

    var canCheckVoiceConnection: Bool {
        if cloudVoiceMode == .managedAccount { return hasCloudVoiceConsent && ParentAccount.shared.signedIn }
        return hasCloudVoiceConsent && (cloudVoiceMode == .parentKey
            ? hasStoredAPIKey
            : cloudVoiceMode == .managedBroker && (try? validatedBrokerURL()) != nil)
    }

    func invalidateConnectionCheck() {
        connectionRevision &+= 1
        connectionCheck = .idle
    }

    /// Checks the real session handshake without opening a microphone or
    /// creating a model response. Nothing from the provider is shown verbatim.
    func checkVoiceConnection() async {
        guard canCheckVoiceConnection, connectionCheck != .checking else { return }
        let revision = connectionRevision
        connectionCheck = .checking
        connectionHistory.record(.started, operation: .accessCheck, mode: cloudVoiceMode)
        do {
            let credential: VoiceCoachCredential
            if cloudVoiceMode == .managedAccount {
                credential = try await ParentAccount.shared.voiceCredential()
            } else if cloudVoiceMode == .managedBroker {
                credential = .legacyBroker(try validatedBrokerURL())
            } else {
                guard let key = try apiKeyForVoiceConnection() else {
                    throw RealtimeClientSecretProviderError.missingCredential
                }
                credential = .parentKey(key)
            }
            try await connectionChecker.check(
                credential: credential,
                language: language == .german ? .german : .english,
                safetyIdentifier: RealtimeSafetyIdentifier(stableID: realtimeSafetyIdentifier)
            )
            guard revision == connectionRevision else { return }
            connectionCheck = Task.isCancelled ? .idle : .connected
            connectionHistory.record(Task.isCancelled ? .cancelled : .connected, operation: .accessCheck, mode: cloudVoiceMode)
        } catch {
            guard revision == connectionRevision else { return }
            connectionCheck = Task.isCancelled ? .idle : .failed(VoiceCoachFailure(error: error))
            connectionHistory.record(Task.isCancelled ? .cancelled : .failed, operation: .accessCheck, mode: cloudVoiceMode, error: Task.isCancelled ? nil : error)
        }
    }

    func revokeCloudConsent() {
        hasCloudVoiceConsent = false
    }

    /// Switching who supplies online access stops current work. Permissions are
    /// explicitly reviewed again before requests can use the selected route.
    func selectCloudVoiceMode(_ mode: CloudVoiceMode) {
        guard cloudVoiceMode != mode else { return }
        hasCloudVoiceConsent = false
        hasHeroGenerationConsent = false
        cloudVoiceMode = mode
    }

    func revokeHeroGenerationConsent() {
        hasHeroGenerationConsent = false
    }

    func recordAgreement(_ document: ParentAgreement, accountID: String? = nil, receipt: ParentConsentReceipt? = nil) {
        guard document.isValid else { return }
        agreementAcceptance = ParentAgreementAcceptance(document: document, acceptedAt: Date(),
            accountID: accountID, serverAcceptedAt: receipt?.acceptedAt)
        defaults.set(try? JSONEncoder().encode(agreementAcceptance), forKey: Keys.agreement)
        let mayEnable = cloudVoiceMode == .parentKey || (accountID != nil && receipt?.isCurrent == true)
        hasCloudVoiceConsent = mayEnable && document.voice && (receipt?.voice ?? true)
        hasHeroGenerationConsent = mayEnable && document.hero && (receipt?.hero ?? true)
    }

    func clearAgreement() {
        hasCloudVoiceConsent = false
        hasHeroGenerationConsent = false
        agreementAcceptance = nil
        defaults.removeObject(forKey: Keys.agreement)
    }

    func resetForUITesting() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-testing"),
              !arguments.contains("--ui-testing-preserve-state") else { return }
        try? secureStore.removeValue(for: Keys.apiKey)
        hasStoredAPIKey = false
        followsDeviceLanguage = false
        language = arguments.contains("--english") ? .english : .german
        cloudVoiceMode = .parentKey
        clearAgreement()
        hasCloudVoiceConsent = false
        hasHeroGenerationConsent = false
        brokerURLText = ""
        #endif
    }
}


enum LiveConnectionCheckState: Equatable {
    case idle, checking, connected
    case failed(VoiceCoachFailure)
}

protocol LiveConnectionChecking: Sendable {
    func check(credential: VoiceCoachCredential,
               language: RealtimeCoachLanguage,
               safetyIdentifier: RealtimeSafetyIdentifier) async throws
}

struct LiveConnectionChecker: LiveConnectionChecking {
    func check(credential: VoiceCoachCredential,
               language: RealtimeCoachLanguage,
               safetyIdentifier: RealtimeSafetyIdentifier) async throws {
        let service: any VoiceCoachingService
        switch credential {
        case .parentKey(let key): service = OpenAILiveService(apiKey: key)
        case .managedLive(let url, let token):
            var request = URLRequest(url: url.appendingPathComponent("v1/account"))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  (try? JSONDecoder().decode(AccountAllowance.self, from: data).available) == true else {
                throw ManagedAccountError.unavailable
            }
            return // Account/readiness check does not consume paid Live minutes.
        case .legacyBroker: throw LiveServiceError.unsupportedBroker
        }
        do {
            try await service.open(language: language,
                                      safetyIdentifier: safetyIdentifier)
            try Task.checkCancellation()
        } catch {
            await service.disconnect()
            throw error
        }
        await service.disconnect()
    }
}
