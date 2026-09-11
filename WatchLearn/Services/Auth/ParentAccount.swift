import Foundation
import Observation
import AuthenticationServices
import CryptoKit
import Security
import FirebaseCore
import FirebaseAuth

struct AccountAllowance: Decodable, Sendable {
    let unlimited: Bool
    let remainingSeconds: Int?
    let active: Bool
    let available: Bool
    let consent: ParentConsentReceipt?
}

enum ManagedAccountError: LocalizedError {
    case signInRequired, unavailable, invalidSignIn, trialExhausted, sessionAlreadyActive, malformedResponse, agreementRequired
    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in with Apple in parent settings."
        case .unavailable: "The service is not available yet."
        case .invalidSignIn: "Apple sign-in could not be verified."
        case .trialExhausted: "Your 5-minute trial is complete. Bring your own API key in Settings or keep practising offline."
        case .sessionAlreadyActive: "A conversation is still closing. Please try again shortly."
        case .malformedResponse: "The service returned an incomplete session."
        case .agreementRequired: "Review privacy and permissions in parent settings."
        }
    }

    static func responseError(status: Int, data: Data) -> ManagedAccountError {
        let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if status == 401 { return .signInRequired }
        if status == 403, payload?["error"] as? String == "agreement_required" { return .agreementRequired }
        if status == 402 { return .trialExhausted }
        if status == 409, payload?["error"] as? String == "session_already_active" { return .sessionAlreadyActive }
        return .unavailable
    }
}

enum ManagedServiceConfiguration {
    // Public configuration, never an OpenAI credential.
    static var baseURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "ZeitHeldServiceURL") as? String,
              let url = URL(string: text), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

@MainActor @Observable
final class ParentAccount {
    static let shared = ParentAccount()
    private(set) var signedIn = false
    private(set) var allowance: AccountAllowance?
    private(set) var busy = false
    private(set) var message: String?
    private var nonce: String?
    private var deleting = false
    private var pendingAgreement: ParentAgreement?
    var accountID: String? { signedIn ? Auth.auth().currentUser?.uid : nil }
    var isConfigured: Bool { FirebaseApp.app() != nil && ManagedServiceConfiguration.baseURL != nil }

    init() {
        if FirebaseApp.app() == nil, Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
        }
        signedIn = FirebaseApp.app() != nil && Auth.auth().currentUser != nil
    }

    func prepare(_ request: ASAuthorizationAppleIDRequest, deleting: Bool = false, agreement: ParentAgreement? = nil) {
        self.deleting = deleting
        guard isConfigured else {
            nonce = nil; message = "Online-Zugang ist in dieser Installation nicht eingerichtet. / Online access is not configured in this build."
            return
        }
        guard deleting || agreement?.isValid == true else {
            nonce = nil; pendingAgreement = nil
            message = "Bitte zuerst Datenschutz und Berechtigungen prüfen. / Review privacy and permissions first."
            return
        }
        pendingAgreement = agreement
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            nonce = nil; message = "Anmeldung nicht verfügbar / Sign-in unavailable"; return
        }
        let raw = Data(bytes).base64EncodedString()
        nonce = raw
        request.requestedScopes = [.email]
        request.nonce = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func complete(_ result: Result<ASAuthorization, Error>) async {
        busy = true; message = nil
        defer { busy = false; nonce = nil; deleting = false; pendingAgreement = nil }
        do {
            guard let nonce,
                  let apple = try result.get().credential as? ASAuthorizationAppleIDCredential,
                  let data = apple.identityToken, let token = String(data: data, encoding: .utf8) else {
                throw ManagedAccountError.invalidSignIn
            }
            let credential = OAuthProvider.appleCredential(withIDToken: token, rawNonce: nonce, fullName: nil)
            if deleting {
                guard let user = Auth.auth().currentUser,
                      let codeData = apple.authorizationCode,
                      let code = String(data: codeData, encoding: .utf8) else { throw ManagedAccountError.signInRequired }
                try await user.reauthenticate(with: credential)
                try await Auth.auth().revokeToken(withAuthorizationCode: code)
                _ = try await request(path: "v1/account", method: "DELETE")
                try Auth.auth().signOut()
                signedIn = false; allowance = nil
            } else {
                guard let agreement = pendingAgreement, agreement.isValid else { throw ManagedAccountError.agreementRequired }
                _ = try await Auth.auth().signIn(with: credential)
                signedIn = true
                _ = try await saveAgreement(agreement)
                await refresh()
            }
        } catch {
            if (error as? ASAuthorizationError)?.code != .canceled {
                message = "Anmeldung fehlgeschlagen. Bitte erneut versuchen. / Sign-in failed. Please try again."
            }
        }
    }

    func refresh() async {
        guard signedIn else { return }
        do {
            allowance = try JSONDecoder().decode(AccountAllowance.self, from: await request(path: "v1/account"))
            message = nil
        } catch { message = "Verbindung nicht verfügbar. / Connection unavailable." }
    }

    func voiceCredential() async throws -> VoiceCoachCredential {
        guard signedIn, let base = ManagedServiceConfiguration.baseURL else { throw ManagedAccountError.signInRequired }
        let data = try await request(path: "v1/account")
        let value = try JSONDecoder().decode(AccountAllowance.self, from: data)
        allowance = value
        guard value.consent?.isCurrent == true, value.consent?.voice == true else { throw ManagedAccountError.agreementRequired }
        guard value.available else { throw ManagedAccountError.unavailable }
        guard value.unlimited || (value.remainingSeconds ?? 0) > 0 else { throw ManagedAccountError.trialExhausted }
        return .managedLive(base, try await idToken())
    }

    func signOut() {
        do { try Auth.auth().signOut(); signedIn = false; allowance = nil; message = nil }
        catch { message = "Abmelden fehlgeschlagen. / Sign-out failed." }
    }

    @discardableResult
    func saveAgreement(_ agreement: ParentAgreement) async throws -> ParentConsentResponse {
        guard agreement.isValid else { throw ManagedAccountError.agreementRequired }
        let result = try JSONDecoder().decode(ParentConsentResponse.self, from: await request(
            path: "v1/consent", method: "POST", body: JSONEncoder().encode(agreement)))
        await refresh()
        return result
    }

    func withdrawAgreement() async throws -> ParentConsentResponse {
        let result = try JSONDecoder().decode(ParentConsentResponse.self,
            from: await request(path: "v1/consent", method: "DELETE"))
        await refresh()
        return result
    }

    private func idToken() async throws -> String {
        guard let user = Auth.auth().currentUser else { throw ManagedAccountError.signInRequired }
        return try await user.getIDToken()
    }

    func request(path: String, method: String = "GET", body: Data? = nil,
                 maximumResponseBytes: Int = 256 * 1024, timeout: TimeInterval = 60) async throws -> Data {
        guard let base = ManagedServiceConfiguration.baseURL else { throw ManagedAccountError.unavailable }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method; request.timeoutInterval = timeout
        request.setValue("Bearer \(try await idToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            bytes.task.cancel(); throw ManagedAccountError.unavailable
        }
        guard response.statusCode == 200 else {
            bytes.task.cancel()
            if response.statusCode == 422 { throw HeroOpenAIServiceError.contentRejected }
            throw HeroOpenAIServiceError.httpStatus(response.statusCode, requestID: nil)
        }
        guard response.expectedContentLength <= maximumResponseBytes else {
            bytes.task.cancel(); throw HeroOpenAIServiceError.responseTooLarge
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                bytes.task.cancel(); throw HeroOpenAIServiceError.responseTooLarge
            }
            data.append(byte)
        }
        return data
    }
}
