import SwiftUI
import AuthenticationServices

struct ParentAccountSection: View {
    @Bindable var account = ParentAccount.shared
    @Bindable var preferences: ParentPreferences
    @State private var showDeletion = false
    @State private var showAgreement = false
    var body: some View {
        Section {
            if account.signedIn {
                Label(copy("Mit Apple angemeldet", "Signed in with Apple"), systemImage: "person.crop.circle.badge.checkmark")
                if let allowance = account.allowance {
                    Text(allowance.unlimited ? copy("Unbegrenzter Testzugang", "Unlimited test access")
                         : copy("Testzeit übrig: ", "Trial remaining: ") + remaining(allowance.remainingSeconds ?? 0))
                        .accessibilityIdentifier("account-allowance")
                    if !allowance.available {
                        Text(copy("Dein Online-Zeitheld wird für die Veröffentlichung vorbereitet. Offline kannst du weiter üben.", "Your online Time Hero is being prepared for release. You can keep practicing offline."))
                            .font(.footnote)
                    }
                }
                if account.allowance?.consent?.isCurrent != true || !preferences.hasCurrentAgreement {
                    Button(copy("Datenschutz und Berechtigungen prüfen", "Review privacy and permissions")) { showAgreement = true }
                        .accessibilityIdentifier("account-review-agreement")
                }
                Button(copy("Guthaben aktualisieren", "Refresh allowance")) { Task { await account.refresh() } }
                Button(copy("Abmelden", "Sign out")) {
                    preferences.clearAgreement()
                    account.signOut()
                }
                Button(copy("Konto löschen …", "Delete account…"), role: .destructive) {
                    preferences.hasCloudVoiceConsent = false
                    preferences.hasHeroGenerationConsent = false
                    showDeletion = true
                }
            } else {
                Text(copy("10 Minuten kostenlos ausprobieren. Eine erwachsene Person meldet sich an. Kein API-Key nötig.", "Try 10 minutes free. A parent signs in. No API key needed."))
                if preferences.hasCurrentAgreement {
                SignInWithAppleButton(.signIn, onRequest: {
                    account.prepare($0, agreement: preferences.agreementAcceptance?.document)
                }, onCompletion: { result in
                    Task {
                        await account.complete(result)
                        if account.signedIn {
                            preferences.cloudVoiceMode = .managedAccount
                            if let document = preferences.agreementAcceptance?.document {
                                preferences.recordAgreement(document, accountID: account.accountID,
                                    receipt: account.allowance?.consent)
                            }
                        }
                    }
                })
                .frame(height: 48)
                .disabled(!account.isConfigured || account.busy)
                .accessibilityIdentifier("parent-apple-sign-in")
                }
                Button(copy("Datenschutz vor der Anmeldung prüfen", "Review privacy before sign-in")) { showAgreement = true }
                    .accessibilityIdentifier("parent-review-agreement")
                if !account.isConfigured {
                    Text(copy("Online-Zugang ist in dieser Installation nicht eingerichtet. Offline kannst du weiter üben.", "Online access is not configured in this build. You can keep practicing offline.")).font(.footnote)
                }
            }
            if account.busy { ProgressView() }
            if let message = account.message { Text(message).font(.footnote).foregroundStyle(.orange) }
        } header: { Text(copy("Elternkonto", "Parent account")) }
        footer: {
            Text(copy("Die 10 Testminuten gelten einmal pro Apple-Konto und auf allen Geräten gemeinsam. Keine automatische Zahlung. Lernfortschritt bleibt auf diesem Gerät.", "The 10 trial minutes apply once per Apple account and are shared across devices. No automatic charges. Learning progress stays on this device."))
        }
        .task { await account.refresh() }
        .sheet(isPresented: $showAgreement) { ParentAgreementView(preferences: preferences) }
        .sheet(isPresented: $showDeletion) {
            VStack(spacing: 20) {
                Text(copy("Konto löschen", "Delete account")).font(.title2.bold())
                Text(copy("Dein Elternkonto wird gelöscht. Ein nicht direkt zuordenbarer Testzeit-Nachweis bleibt gegen mehrfaches Einlösen erhalten. Lokalen Lernfortschritt und Bilder verwaltest du separat. Bestätige mit Apple.", "Your parent account will be deleted. A pseudonymous trial-use record remains to prevent repeat trials. Local learning progress and pictures are managed separately. Confirm with Apple."))
                SignInWithAppleButton(.continue, onRequest: { account.prepare($0, deleting: true) }, onCompletion: { result in
                    Task {
                        await account.complete(result)
                        if !account.signedIn { preferences.clearAgreement(); showDeletion = false }
                    }
                }).frame(height: 48)
                if let message = account.message { Text(message).foregroundStyle(.orange) }
                Button(copy("Abbrechen", "Cancel")) { showDeletion = false }
            }.padding()
        }
    }
    private func copy(_ de: String, _ en: String) -> String { preferences.language == .german ? de : en }
    private func remaining(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }
}
