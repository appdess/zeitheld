import SwiftUI
import Security

struct ParentSettingsView: View {
    @Bindable var preferences: ParentPreferences
    let generatedHeroImageStore: GeneratedHeroImageStore
    var learningViewModel: LearningViewModel? = nil
    let onDone: () -> Void

    @State private var showingResetJourney = false
    @State private var apiKeyDraft = ""
    @State private var connectionCheckRequest: UUID?
    @State private var showingPrivateKey = false
    @State private var showingDeleteHeroConfirmation = false
    @State private var errorMessage: String?
    @State private var activeSheet: ParentSheet?
    @State private var withdrawingAgreement = false
    @State private var withdrawalMessage: String?

    private enum ParentSheet: String, Identifiable {
        case agreement, accountDeletion
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let model = learningViewModel, let journeys = model.journeys {
                    Section(copy(de: "Lernreise", en: "Learning journey")) {
                        LabeledContent(copy(de: "Aktives Kind", en: "Selected child"), value: journeys.selected.name)
                        Button(copy(de: "Lernreise zurücksetzen", en: "Reset journey"), role: .destructive) {
                            showingResetJourney = true
                        }
                        .accessibilityIdentifier("reset-journey")
                        .confirmationDialog(copy(de: "Lernreise von \(journeys.selected.name) zurücksetzen?", en: "Reset \(journeys.selected.name)'s journey?"), isPresented: $showingResetJourney, titleVisibility: .visible) {
                            Button(copy(de: "Diese Lernreise löschen", en: "Erase this journey"), role: .destructive) { model.resetJourney() }
                        } message: {
                            Text(copy(de: "Sterne, Fortschritt und Antworten dieses Kindes werden gelöscht. Andere Kinder behalten ihre Lernreise.", en: "This child's stars, progress and answers will be erased. Other children's journeys are kept."))
                        }
                    }
                }
                ParentAccountSection(preferences: preferences,
                    onReviewAgreement: { activeSheet = .agreement },
                    onDeleteAccount: { activeSheet = .accountDeletion })
                onlineAccessSection
                privateKeySection
                Section(copy(de: "Sprache", en: "Language")) {
                    Toggle(copy(de: "Gerätesprache verwenden", en: "Use device language"), isOn: $preferences.followsDeviceLanguage)
                        .accessibilityIdentifier("device-language-toggle")
                    if !preferences.followsDeviceLanguage {
                    Picker(copy(de: "Sprache des Kindes", en: "Child's language"), selection: $preferences.language) {
                        Text("Deutsch").tag(InterfaceLanguage.german)
                        Text("English").tag(InterfaceLanguage.english)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("language-picker")
                    }
                }

                Section {
                    LabeledContent(copy(de: "Mit deinem Zeithelden sprechen", en: "Talk to your Time Hero"),
                        value: preferences.hasCloudVoiceConsent ? copy(de: "Erlaubt", en: "Allowed") : copy(de: "Aus", en: "Off"))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(copy(de: "Mit deinem Zeithelden sprechen", en: "Talk to your Time Hero"))
                    .accessibilityValue(preferences.hasCloudVoiceConsent ? copy(de: "Erlaubt", en: "Allowed") : copy(de: "Aus", en: "Off"))
                    .accessibilityIdentifier("voice-online-toggle")
                    LabeledContent(copy(de: "Helden gestalten", en: "Create heroes"),
                        value: preferences.hasHeroGenerationConsent ? copy(de: "Erlaubt", en: "Allowed") : copy(de: "Aus", en: "Off"))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(copy(de: "Helden gestalten", en: "Create heroes"))
                    .accessibilityValue(preferences.hasHeroGenerationConsent ? copy(de: "Erlaubt", en: "Allowed") : copy(de: "Aus", en: "Off"))
                    .accessibilityIdentifier("hero-online-toggle")
                    Button(copy(de: "Datenschutz und Berechtigungen", en: "Privacy and permissions")) { activeSheet = .agreement }
                        .accessibilityIdentifier("privacy-permissions-button")
                    if let receipt = preferences.agreementAcceptance {
                        Text(copy(de: "Bestätigte Version: ", en: "Confirmed version: ") + receipt.document.version)
                            .font(.footnote)
                        Text(receipt.serverAcceptedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? receipt.acceptedAt,
                             format: .dateTime.day().month().year().hour().minute()).font(.footnote)
                    }
                    if preferences.hasCurrentAgreement || ParentAccount.shared.signedIn {
                        Button(copy(de: "Online-Berechtigungen widerrufen", en: "Withdraw online permissions"), role: .destructive) {
                            withdrawAgreement()
                        }
                        .disabled(withdrawingAgreement)
                        .accessibilityIdentifier("withdraw-agreement")
                    }
                    if withdrawingAgreement { ProgressView() }
                    if let withdrawalMessage { Text(withdrawalMessage).font(.footnote).accessibilityIdentifier("withdrawal-status") }
                    if preferences.hasAnyOnlineFeatureEnabled {
                        let status = onlineSetupStatus
                        Label(
                            status.message,
                            systemImage: status.symbol
                        )
                        .foregroundStyle(status.color)
                    }
                } header: {
                    Text(copy(de: "Online-Berechtigungen", en: "Online permissions"))
                } footer: {
                    Text(copy(
                        de: "Online derzeit nur für Erwachsene mit erfundenen Testinhalten. Audio und Ideen werden von OpenAI verarbeitet. Offline-Uhrentraining bleibt ohne Einwilligung nutzbar.",
                        en: "Online features currently allow adults using fictional test content only. OpenAI processes audio and ideas. Offline clock practice remains available without consent."
                    ))
                }

                Section {
                    Label("GPT-Live 1", systemImage: "waveform")
                    Text(copy(de: "Einmal starten und auf Deutsch oder Englisch sprechen. Dein Zeitheld hört auch beim Sprechen zu. Du kannst ihn jederzeit unterbrechen.", en: "Start once and speak in German or English. Your Time Hero listens while speaking. You can interrupt at any time."))
                        .font(.footnote)
                    Button {
                        connectionCheckRequest = UUID()
                    } label: {
                        HStack {
                            Label(copy(de: "Verbindung prüfen", en: "Check connection"),
                                  systemImage: "network")
                            if preferences.connectionCheck == .checking { ProgressView() }
                        }
                    }
                    .disabled(!preferences.canCheckVoiceConnection || preferences.connectionCheck == .checking)
                    .accessibilityIdentifier("live-connection-check")

                    switch preferences.connectionCheck {
                    case .connected:
                        Label(copy(de: "Verbindung bereit. Audio beim Gesprächsstart prüfen.", en: "Connection ready. Check audio when starting the conversation."),
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("live-connection-success")
                    case let .failed(failure):
                        Text(failure.localizedMessage(language: preferences.language))
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("live-connection-error")
                    case .checking:
                        Text(copy(de: "Dein Zeitheld wird verbunden …", en: "Connecting to your Time Hero…"))
                    case .idle:
                        Text(copy(de: "Mit Apple anmelden oder einen eigenen API-Key hinzufügen. Danach die Sprachfunktion unter Datenschutz und Berechtigungen erlauben und die Verbindung prüfen.",
                                  en: "Sign in with Apple or add your own API key. Then allow voice under Privacy and permissions and check the connection."))
                    }
                } header: {
                    Text(copy(de: "Bereit zum Sprechen", en: "Ready to talk"))
                } footer: {
                    Text(copy(de: "Dieser Test prüft den Zugang, ohne das Mikrofon einzuschalten. Mit Elternkonto verbraucht er keine Testminuten. Danach: Fertig → Sprich mit deinem Zeithelden. Das Mikrofon beim ersten Start erlauben. Mit dem roten Stopp-Knopf beendest du das Gespräch.",
                              en: "This checks access without turning on the microphone. With a parent account it does not use trial minutes. Then: Done → Talk to your Time Hero. Allow microphone access the first time. The red stop button ends the conversation."))
                }

                if preferences.cloudVoiceMode == .managedBroker {
                    Section {
                        Text(copy(de: "Dein bisheriger Token-Server verwendet die ältere Sprachverbindung. Für diese private Live-Version bitte den eigenen API-Key verwenden.", en: "Your saved token server uses the older voice connection. Use your own API key for this private Live version."))
                        Button(copy(de: "Eigenen API-Key verwenden", en: "Use my API key")) {
                            preferences.selectCloudVoiceMode(.parentKey)
                        }
                    }
                }

                Section {
                    Button(
                        copy(de: "Lokale Heldenbilder löschen", en: "Delete local hero pictures"),
                        role: .destructive
                    ) {
                        showingDeleteHeroConfirmation = true
                    }
                } header: {
                    Text(copy(de: "Gerätedaten", en: "On-device data"))
                } footer: {
                    Text(copy(
                        de: "Erstellte Heldenbilder bleiben auf diesem Gerät, bis sie hier gelöscht werden.",
                        en: "Generated hero pictures stay on this device until they are deleted here."
                    ))
                }

                Section(copy(de: "Rechtliches & Datenschutz", en: "Legal & privacy")) {
                    NavigationLink(copy(de: "Nutzungsbedingungen der Beta", en: "Beta terms of use")) {
                        SupervisedUseTermsView(language: preferences.language)
                    }
                    NavigationLink(copy(de: "Datenschutz dieser App", en: "This app's privacy policy")) {
                        AppPrivacyNoticeView(language: preferences.language)
                    }
                    Link(
                        copy(de: "OpenAI Datenschutz", en: "OpenAI privacy policy"),
                        destination: URL(string: "https://openai.com/policies/privacy-policy/")!
                    )
                    Link(
                        copy(de: "Apple Datenschutz", en: "Apple privacy"),
                        destination: URL(string: "https://www.apple.com/legal/privacy/")!
                    )
                }

                if ProjectLinks.hasPublishedRepository {
                    Section {
                    Link(
                        destination: ProjectLinks.repository,
                        label: {
                            Label(
                                copy(de: "Quellcode auf GitHub", en: "Source code on GitHub"),
                                systemImage: "chevron.left.forwardslash.chevron.right"
                            )
                        }
                    )
                    Link(
                        destination: ProjectLinks.issueTracker,
                        label: {
                            Label(
                                copy(de: "Problem auf GitHub melden", en: "Report an issue on GitHub"),
                                systemImage: "exclamationmark.bubble"
                            )
                        }
                    )
                    .accessibilityIdentifier("report-issue-link")
                    Link(
                        destination: ProjectLinks.privateSecurityReport,
                        label: {
                            Label(
                                copy(de: "Sicherheitsproblem privat melden", en: "Report a security issue privately"),
                                systemImage: "lock.shield"
                            )
                        }
                    )
                } header: {
                    Text(copy(de: "Open Source & Hilfe", en: "Open source & help"))
                } footer: {
                    Text(copy(
                        de: "ZeitHeld ist ein Open-Source-Experiment. GitHub-Issues sind öffentlich. Dort niemals API-Keys, Namen, Sprachaufnahmen oder andere Daten eines Kindes einfügen. Sicherheitslücken bitte nur über die private Meldung senden.",
                        en: "Time Hero is an open-source experiment. GitHub issues are public. Never include API keys, names, voice recordings, or other child data. Please use the private report for security vulnerabilities."
                    ))
                }
                }

                Section {
                    LabeledContent(copy(de: "App-Version", en: "App version")) {
                        Text(versionDescription)
                            .monospacedDigit()
                    }
                }
            }
            .task(id: connectionCheckRequest) {
                guard connectionCheckRequest != nil else { return }
                await preferences.checkVoiceConnection()
            }
            .onDisappear {
                apiKeyDraft = ""
                preferences.invalidateConnectionCheck()
            }
            .navigationTitle(copy(de: "Einstellungen", en: "Settings"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(copy(de: "Fertig", en: "Done"), action: onDone)
                        .accessibilityIdentifier("settings-done-button")
                }
            }
            .confirmationDialog(
                copy(de: "Alle lokalen Heldenbilder löschen?", en: "Delete all local hero pictures?"),
                isPresented: $showingDeleteHeroConfirmation,
                titleVisibility: .visible
            ) {
                Button(
                    copy(de: "Bilder endgültig löschen", en: "Delete pictures"),
                    role: .destructive,
                    action: deleteLocalHeroImages
                )
                Button(copy(de: "Abbrechen", en: "Cancel"), role: .cancel) {}
            } message: {
                Text(copy(
                    de: "Die erstellten Bilder und der gewählte Uhren-Hintergrund werden von diesem Gerät entfernt.",
                    en: "Generated pictures and the selected clock background will be removed from this device."
                ))
            }
            .alert(copy(de: "Einstellung nicht gespeichert", en: "Setting not saved"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        // Keep presentation ownership outside Form's lazily recycled sections.
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .agreement: ParentAgreementView(preferences: preferences)
            case .accountDeletion: ParentAccountDeletionView(preferences: preferences)
            }
        }
    }

    private var onlineAccessSection: some View {
        Section {
            Picker(copy(de: "Online-Zugang", en: "Online access"), selection: Binding(
                get: { preferences.cloudVoiceMode },
                set: { mode in
                    preferences.selectCloudVoiceMode(mode)
                    showingPrivateKey = mode == .parentKey
                }
            )) {
                Text(copy(de: "5 Gratisminuten", en: "5 free minutes")).tag(CloudVoiceMode.managedAccount)
                Text(copy(de: "Eigener API-Key", en: "Own API key")).tag(CloudVoiceMode.parentKey)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("online-access-picker")
            if preferences.cloudVoiceMode == .parentKey {
                Text(copy(de: "Du verwendest deinen eigenen OpenAI-Zugang. Die 5 Gratisminuten des Elternkontos werden dabei nicht verbraucht.", en: "You are using your own OpenAI access. This does not spend your parent account’s 5 free minutes."))
            } else {
                Text(copy(de: "Einmalig 5 Minuten kostenlos nach Apple-Anmeldung. Danach kannst du mit einem eigenen API-Key weitermachen. Keine automatische Zahlung.", en: "Get 5 free minutes once after Apple sign-in. Afterwards, you can continue with your own API key. No automatic charges."))
            }
        } header: {
            Text(copy(de: "Gratis testen oder eigenen Key nutzen", en: "Try free or bring your own key"))
        } footer: {
            Text(copy(de: "ZeitHeld ist ein Open-Source-Experiment. Offline üben bleibt kostenlos und ohne Anmeldung möglich.", en: "Time Hero is an open-source experiment. Offline practice stays free and needs no sign-in."))
        }
    }

    @ViewBuilder
    private var privateKeySection: some View {
        Section {
            Button {
                showingPrivateKey.toggle()
            } label: {
                HStack {
                    Text(copy(de: "Eigenen API-Key hinzufügen", en: "Add your own API key"))
                    Spacer()
                    Image(systemName: showingPrivateKey ? "chevron.up" : "chevron.down")
                }
            }
            .accessibilityIdentifier("private-key-disclosure")
        }
        if showingPrivateKey {
        Section {
            LabeledContent(copy(de: "API-Endpunkt", en: "API endpoint"), value: "api.openai.com/v1")
            SecureField(copy(de: "OpenAI API-Key", en: "OpenAI API key"), text: $apiKeyDraft)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .accessibilityIdentifier("api-key-field")

            Button(preferences.hasStoredAPIKey
                   ? copy(de: "Key ersetzen", en: "Replace key")
                   : copy(de: "Key speichern und verwenden", en: "Save and use key")) {
                storeAPIKey()
            }
            .disabled(apiKeyDraft.isEmpty)
            .accessibilityIdentifier("api-key-save")

            if preferences.hasStoredAPIKey {
                Label(
                    copy(de: "Im iOS-Schlüsselbund gespeichert", en: "Stored in iOS Keychain"),
                    systemImage: "lock.shield.fill"
                )
                .foregroundStyle(.green)

                Button(copy(de: "Key löschen", en: "Delete key"), role: .destructive) {
                    deleteAPIKey()
                }
                .accessibilityIdentifier("api-key-delete")
            }

            Link(
                copy(de: "OpenAI API-Key erstellen", en: "Create an OpenAI API key"),
                destination: URL(string: "https://platform.openai.com/api-keys")!
            )
            Link(
                copy(de: "API-Guthaben und Kosten verwalten", en: "Manage API credits and billing"),
                destination: URL(string: "https://platform.openai.com/settings/organization/billing/overview")!
            )
        } header: {
            Text(copy(de: "Dein OpenAI-Zugang", en: "Your OpenAI access"))
        } footer: {
            Text(copy(
                de: "Keine Apple-Anmeldung nötig. Dein Key bleibt im geschützten Schlüsselbund dieses Geräts und geht nur direkt an OpenAI. Einmal pro Gerät eingeben. OpenAI rechnet die Nutzung separat ab; sie ist nicht Teil der 5 Gratisminuten. Erlaube danach die gewünschten Funktionen unter Datenschutz und Berechtigungen.",
                en: "No Apple sign-in needed. Your key stays in this device’s protected Keychain and is sent directly to OpenAI only. Enter it once per device. OpenAI bills this usage separately; it is not part of the 5 free minutes. Then allow your chosen features under Privacy and permissions."
            ))
        }

        }
    }

    private func copy(de: String, en: String) -> String {
        preferences.language == .german ? de : en
    }

    private func withdrawAgreement() {
        preferences.clearAgreement() // Stops local capture immediately, including while offline.
        withdrawalMessage = nil
        guard ParentAccount.shared.signedIn else {
            withdrawalMessage = copy(de: "Online-Berechtigungen auf diesem Gerät widerrufen.", en: "Online permissions withdrawn on this device.")
            return
        }
        withdrawingAgreement = true
        Task {
            defer { withdrawingAgreement = false }
            do {
                let response = try await ParentAccount.shared.withdrawAgreement()
                withdrawalMessage = response.cleanupPending
                    ? copy(de: "Widerruf gespeichert. Eine bereits gestartete Anfrage wird noch beendet.", en: "Withdrawal saved. A request already in progress is still being closed.")
                    : copy(de: "Online-Berechtigungen für dieses Elternkonto widerrufen.", en: "Online permissions withdrawn for this parent account.")
            } catch {
                withdrawalMessage = copy(de: "Auf diesem Gerät aus. Der Server hat den Widerruf noch nicht bestätigt. Bitte mit Internetverbindung erneut widerrufen.", en: "Off on this device. The server has not confirmed withdrawal yet. Please retry when connected to the internet.")
            }
        }
    }

    private var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        return "\(version) (\(build))"
    }

    private var onlineSetupStatus: (message: String, symbol: String, color: Color) {
        if preferences.cloudVoiceMode == .managedAccount {
            return (ParentAccount.shared.signedIn ? copy(de: "Elternkonto verbunden", en: "Parent account connected") : copy(de: "Bitte mit Apple anmelden", en: "Please sign in with Apple"), "person.crop.circle", .indigo)
        }
        let directVoiceNeedsKey = preferences.hasCloudVoiceConsent
            && preferences.cloudVoiceMode != .managedBroker
        let enabledFeatureNeedsKey = preferences.hasHeroGenerationConsent || directVoiceNeedsKey

        if enabledFeatureNeedsKey && !preferences.hasStoredAPIKey {
            return (
                copy(de: "Bitte unten einen OpenAI API-Key speichern", en: "Store an OpenAI API key below"),
                "exclamationmark.triangle.fill",
                .orange
            )
        }

        if preferences.hasCloudVoiceConsent,
           preferences.cloudVoiceMode == .managedBroker,
           (try? preferences.validatedBrokerURL()) == nil {
            return (
                copy(de: "Bitte den eigenen Token-Server eintragen", en: "Enter your token-server URL"),
                "exclamationmark.triangle.fill",
                .orange
            )
        }

        return (
            copy(
                de: "Einstellungen gespeichert; Verbindung wird beim Start geprüft",
                en: "Settings saved; connection is checked when a feature starts"
            ),
            "checkmark.shield.fill",
            .green
        )
    }

    private func storeAPIKey() {
        do {
            try preferences.storeAPIKey(apiKeyDraft)
            // This explicit action selects the own-key route;
            // cloud-feature consent remains a separate opt-in.
            preferences.selectCloudVoiceMode(.parentKey)
            apiKeyDraft = ""
        } catch {
            errorMessage = keychainMessage(for: error)
        }
    }

    private func deleteAPIKey() {
        do {
            try preferences.deleteAPIKey()
        } catch {
            errorMessage = keychainMessage(for: error)
        }
    }

    private func keychainMessage(for error: Error) -> String {
        if case ParentSettingsError.invalidAPIKey = error {
            return copy(de: "Bitte den vollständigen OpenAI API-Key einfügen. Er beginnt mit sk-.", en: "Paste the complete OpenAI API key. It starts with sk-.")
        }
        if case SecureStoreError.unexpectedStatus(let status) = error, status == errSecMissingEntitlement {
            return copy(de: "Dieser Installation fehlt die Schlüsselbund-Berechtigung. Bitte die neueste signierte App installieren. [KEYCHAIN-SIGNING]", en: "This installation is missing its Keychain permission. Install the latest signed app. [KEYCHAIN-SIGNING]")
        }
        return copy(de: "Der iOS-Schlüsselbund ist gerade nicht verfügbar. Bitte erneut versuchen. [KEYCHAIN-STORE]", en: "The iOS Keychain is currently unavailable. Please try again. [KEYCHAIN-STORE]")
    }

    private func deleteLocalHeroImages() {
        Task {
            do {
                NotificationCenter.default.post(
                    name: .generatedHeroImagesWillDelete,
                    object: nil
                )
                try await generatedHeroImageStore.deleteAll()
                NotificationCenter.default.post(
                    name: .generatedHeroImagesDeleted,
                    object: nil
                )
            } catch {
                errorMessage = copy(
                    de: "Die Bilder konnten nicht gelöscht werden.",
                    en: "The pictures could not be deleted."
                )
            }
        }
    }
}

struct AppPrivacyNoticeView: View {
    let language: InterfaceLanguage

    private var paragraphs: [String] {
        guard let url = Bundle.main.url(forResource: "PRIVACY", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ParentPrivacySummary(language: language)
                if language == .german {
                    Text("Die ausführlichen Datenschutzhinweise dieser Beta liegen derzeit auf Englisch vor.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    if paragraph.hasPrefix("#") {
                        Text(paragraph.drop(while: { $0 == "#" || $0 == " " }))
                            .font(.headline)
                    } else {
                        Text((try? AttributedString(markdown: paragraph.replacingOccurrences(of: "\n", with: " ")))
                             ?? AttributedString(paragraph))
                    }
                }
            }
            .textSelection(.enabled)
            .padding()
        }
        .navigationTitle(language == .german ? "Datenschutz" : "Privacy")
        .accessibilityIdentifier("app-privacy-notice")
    }
}

struct SupervisedUseTermsView: View {
    let language: InterfaceLanguage

    var body: some View {
        List {
            Section {
                Text(copy(de: "Stand: 11. September 2026. Diese Hinweise betreffen den aktuellen privaten Beta-Zugang.", en: "Updated 11 September 2026. These terms concern the current private beta access."))
                    .font(.footnote)
            }
            termsRow(icon: "person.fill",
                de: "Der bereitgestellte Beta- und Cloud-Zugang ist nur für persönliche, nicht kommerzielle Tests bestimmt. Rechte am Quellcode unter der MIT-Lizenz und Rechte aus Lizenzen Dritter bleiben unberührt.",
                en: "The provided beta and cloud access is for personal, non-commercial testing only. Rights to the source code under the MIT license and third-party licenses remain unchanged.")
            termsRow(icon: "person.2.fill",
                de: "In dieser Beta sind Online-Funktionen nur für Tests durch Erwachsene mit erfundenen Inhalten freigegeben. Kinder können das Offline-Uhrentraining unter Aufsicht nutzen. Kinder-Audio darf erst nach geklärtem Datenschutz und Freigabe der erforderlichen Datenaufbewahrungseinstellungen verwendet werden.",
                en: "In this beta, online features are limited to adults testing fictional content. Children can use offline clock practice with supervision. Child audio must wait until the required privacy and data-retention settings are verified.")
            termsRow(icon: "sparkles",
                de: "Die KI kann Fehler machen oder unpassend antworten. Die Beta kann unterbrochen, geändert oder beendet werden. Es gibt keine Zusage für fehlerfreie Antworten, ständige Verfügbarkeit oder einen bestimmten Lernerfolg.",
                en: "AI can make mistakes or give unsuitable answers. The beta may be interrupted, changed or ended. Error-free answers, continuous availability and any particular learning outcome are not guaranteed.")
            termsRow(icon: "doc.text",
                de: "Die Beta wird im vorhandenen Zustand und nach Verfügbarkeit bereitgestellt. Soweit gesetzlich zulässig, wird keine zusätzliche freiwillige Garantie übernommen. Zwingende gesetzliche Rechte und Gewährleistungsansprüche bleiben bestehen.",
                en: "The beta is provided as is and as available. To the extent permitted by law, no additional voluntary warranty is provided. Mandatory statutory rights and warranty claims remain unaffected.")
            termsRow(icon: "shield.lefthalf.filled",
                de: "Diese Hinweise schließen keine zwingende Haftung aus, insbesondere nicht für Vorsatz, grobe Fahrlässigkeit oder Schäden an Leben, Körper oder Gesundheit. Datenschutzrechte werden nicht eingeschränkt.",
                en: "These terms do not exclude mandatory liability, including liability for intent, gross negligence or injury to life, body or health. They do not limit privacy rights.")
            termsRow(icon: "waveform.and.mic",
                de: "Beim Gespräch mit deinem Zeithelden werden Audio und Gesprächsinhalte von OpenAI verarbeitet. Heldenideen und Bilder werden für Transkription, Moderation oder Bilderstellung verarbeitet. Keine echten Namen, Adressen, Schulen oder anderen privaten Informationen eingeben. Die Datenschutzhinweise erklären die Verarbeitung genauer.",
                en: "During a conversation with your Time Hero, OpenAI processes audio and conversation content. Hero ideas and images are processed for transcription, moderation or image generation. Do not enter real names, addresses, schools or other private information. The privacy notice explains the processing in more detail.")
            termsRow(icon: "creditcard",
                de: "Das Elternkonto bietet einmalig fünf Testminuten, gemeinsam für alle Geräte und Kinderprofile. Es gibt keine automatische Zahlung. Weitere Nutzungslimits können gelten. Alternativ kannst du einen eigenen API-Key verwenden; dessen Nutzung wird separat vom Anbieter abgerechnet.",
                en: "A parent account receives one five-minute trial shared across devices and child profiles. There are no automatic charges. Additional usage limits may apply. Alternatively, bring your own API key; the provider bills its usage separately.")
            termsRow(icon: "stop.circle",
                de: "Mit Stopp endet das Gespräch. In den Einstellungen können die Reise des ausgewählten Kindes zurückgesetzt, lokale Heldenbilder entfernt und das Elternkonto gelöscht werden. Diese Beta-Hinweise ersetzen weder Apples Bedingungen noch separate Open-Source-Lizenzen.",
                en: "Stop ends the conversation. Settings can reset the selected child's journey, remove local hero pictures and delete the parent account. These beta terms do not replace Apple's terms or separate open-source licenses.")
        }
        .accessibilityIdentifier("beta-terms-content")
        .navigationTitle(copy(de: "Beta-Nutzung", en: "Beta use"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func termsRow(icon: String, de: String, en: String) -> some View {
        Label { Text(copy(de: de, en: en)) } icon: {
            Image(systemName: icon).foregroundStyle(.indigo)
        }
    }
    private func copy(de: String, en: String) -> String { language == .german ? de : en }
}
