import SwiftUI

struct ParentAgreementView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var preferences: ParentPreferences
    @Bindable private var account = ParentAccount.shared
    @State private var document: ParentAgreement
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var completionMessage: String?

    init(preferences: ParentPreferences) {
        self.preferences = preferences
        // First consent is always opt-in. Existing choices are shown for editing.
        _document = State(initialValue: preferences.agreementAcceptance?.document
            ?? ParentAgreement(locale: preferences.language.rawValue))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(copy("Für Eltern und Sorgeberechtigte", "For parents and guardians")).font(.headline)
                    Text(copy("Offline üben geht ohne Konto. Für ein Elternkonto und optionale Online-Funktionen prüfst du hier die Hinweise und bestätigst deine Auswahl.", "Offline practice needs no account. Before creating a parent account or using optional online features, review these notices and confirm your choices."))
                    Text(copy("Diese private Beta ist online nur für Erwachsene mit erfundenen Testinhalten freigegeben. Noch keine Kinderstimmen übertragen.", "Online features in this private beta are for adults using fictional test content. Do not transmit children's voices yet."))
                        .foregroundStyle(.orange)
                    Text(copy("Version ", "Version ") + ParentAgreement.currentVersion).font(.caption)
                }
                Section(copy("Was verarbeitet wird", "What is processed")) {
                    ParentPrivacySummary(language: preferences.language, compact: true)
                    NavigationLink(copy("Ausführliche Datenschutzhinweise", "Full privacy notice")) {
                        AppPrivacyNoticeView(language: preferences.language)
                    }
                    NavigationLink(copy("Nutzungsbedingungen der Beta", "Beta terms of use")) {
                        SupervisedUseTermsView(language: preferences.language)
                    }
                }
                Section(copy("Deine Bestätigung", "Your confirmation")) {
                    Toggle(copy("Ich bin volljährig und für die Nutzung dieses Geräts und gegebenenfalls die Aufsicht des Kindes verantwortlich.", "I am an adult responsible for use of this device and, where applicable, supervision of the child."), isOn: $document.guardian)
                        .accessibilityIdentifier("agreement-guardian")
                    Toggle(copy("Ich habe die Datenschutzhinweise gelesen und zur Kenntnis genommen.", "I have read and acknowledged the privacy notice."), isOn: $document.privacyAcknowledged)
                        .accessibilityIdentifier("agreement-privacy")
                    Toggle(copy("Ich akzeptiere die Nutzungsbedingungen dieser privaten Beta.", "I accept the terms of this private beta."), isOn: $document.termsAccepted)
                        .accessibilityIdentifier("agreement-terms")
                }
                Section {
                    Toggle(copy("Mit meinem Zeithelden sprechen: Mikrofon-Audio und Gesprächsinhalte dürfen für diese Funktion von OpenAI verarbeitet werden.", "Talk to my Time Hero: OpenAI may process microphone audio and conversation content for this feature."), isOn: $document.voice)
                        .accessibilityIdentifier("agreement-voice")
                    Toggle(copy("Helden gestalten: OpenAI darf Beschreibungen, kurze Sprachaufnahmen und Bilder zur Transkription, Sicherheitsprüfung und Bilderstellung verarbeiten.", "Create heroes: OpenAI may process descriptions, short recordings and images for transcription, safety checks and image generation."), isOn: $document.hero)
                        .accessibilityIdentifier("agreement-hero")
                    if document.voice || document.hero {
                        Toggle(copy("Ich nutze die Online-Beta selbst mit erfundenen Inhalten und übertrage keine Daten eines Kindes.", "I will test online features myself with fictional content and will not transmit a child's data."), isOn: $document.adultTestOnly)
                            .accessibilityIdentifier("agreement-adult-test")
                    }
                } header: { Text(copy("Optional und einzeln wählbar", "Optional, separate permissions")) }
                footer: { Text(copy("Keine Auswahl ist vorausgewählt. Du kannst beide Funktionen ablehnen und offline weiterlernen. Die Einwilligung lässt sich in den Einstellungen widerrufen. Bereits erfolgte Verarbeitung wird dadurch nicht rückgängig gemacht.", "Neither permission is selected on first use. You can decline both and continue offline. Withdraw permission in Settings at any time. Withdrawal does not undo processing that has already happened.")) }
                Section {
                    if let errorMessage { Text(errorMessage).foregroundStyle(.orange).accessibilityIdentifier("agreement-error") }
                    if let completionMessage { Text(completionMessage).accessibilityIdentifier("agreement-complete") }
                    Button(account.signedIn ? copy("Auswahl bestätigen und speichern", "Confirm and save choices")
                           : copy("Bestätigen und zur Anmeldung", "Confirm and continue to sign-in")) {
                        Task { await save() }
                    }
                    .disabled(!document.isValid || saving)
                    .accessibilityIdentifier("agreement-confirm")
                    if saving { ProgressView() }
                } footer: {
                    Text(copy("Deine aktive Bestätigung wird mit Version, Auswahl und Zeitpunkt gespeichert. Nach Apple-Anmeldung wird sie mit deinem Elternkonto verknüpft. Wir verlangen kein Foto einer Unterschrift und keinen zusätzlichen Namen.", "Your explicit confirmation is recorded with the version, choices and time. After Apple sign-in it is linked to your parent account. We do not request a signature image or an additional name."))
                }
            }
            .navigationTitle(copy("Datenschutz & Auswahl", "Privacy & choices"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(copy("Zurück", "Back")) { dismiss() }.disabled(saving)
                        .accessibilityIdentifier("agreement-back")
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() async {
        guard document.isValid else { return }
        saving = true; errorMessage = nil
        defer { saving = false }
        document.locale = preferences.language.rawValue
        // Local capture is disabled while permission changes are being committed.
        preferences.hasCloudVoiceConsent = false
        preferences.hasHeroGenerationConsent = false
        do {
            if account.signedIn && preferences.cloudVoiceMode == .managedAccount {
                let response = try await account.saveAgreement(document)
                preferences.recordAgreement(document, accountID: account.accountID, receipt: response.consent)
                if response.cleanupPending {
                    completionMessage = copy("Gespeichert. Eine bereits gestartete Online-Anfrage wird noch beendet.", "Saved. An online request that was already running is still being closed.")
                    return
                }
            } else {
                preferences.recordAgreement(document)
            }
            dismiss()
        } catch {
            errorMessage = copy("Nicht bestätigt: Die Auswahl konnte nicht auf dem Server gespeichert werden. Online-Funktionen bleiben auf diesem Gerät aus. Bitte erneut versuchen.", "Not confirmed: your choices could not be saved on the server. Online features remain off on this device. Please try again.")
        }
    }

    private func copy(_ de: String, _ en: String) -> String { preferences.language == .german ? de : en }
}

struct ParentPrivacySummary: View {
    let language: InterfaceLanguage
    var compact = false
    var body: some View {
        if compact {
            Text(copy("Kinderprofile und Lernfortschritt bleiben auf dem Gerät. Apple und Google Firebase verwalten das Elternkonto; unser Google-Cloud-Backend speichert deine Bestätigung und pseudonyme Nutzungsdaten für die Limits.", "Child profiles and progress stay on the device. Apple and Google Firebase manage the parent account; our Google Cloud backend stores your confirmation and pseudonymous usage records for limits."))
            Text(copy("Mit deiner separaten Erlaubnis verarbeitet OpenAI Gesprächsaudio oder Heldenideen, kurze Aufnahmen und Bilder. Aufnahmen und Inhalte werden von unserem Backend nicht dauerhaft gespeichert. Anbieterregeln gelten zusätzlich; Verarbeitung außerhalb der EU ist möglich.", "With your separate permission, OpenAI processes conversation audio or hero ideas, short recordings and images. Our backend does not persist recordings or content. Provider data rules also apply; processing outside the EU is possible."))
            Text(copy("Keine Werbung. Du kannst die Auswahl jederzeit widerrufen. Einzelheiten zu Empfängern, Aufbewahrung, Kontolöschung und deinen Rechten stehen in den Datenschutzhinweisen.", "No advertising. You can withdraw your choices at any time. The privacy notice explains recipients, retention, account deletion and your rights."))
        } else {
        Text(copy("Lokal: Kinderprofile, Namen, Lernfortschritt, die letzten 500 Antworten und gespeicherte Heldenbilder bleiben in dieser App auf dem Gerät. Sie werden nicht als Profil an unsere Cloud übertragen.", "On device: child profiles, names, learning progress, the latest 500 answers and saved hero pictures stay in this app on the device. These profiles are not uploaded to our cloud."))
        Text(copy("Konto: Apple und Google Firebase ermöglichen die Anmeldung. Unser Google-Cloud-Backend speichert Kontokennung, deine Bestätigung sowie pseudonyme Nutzungs- und Sitzungsdaten für Zugang und Limits. Keine Werbeprofile.", "Account: Apple and Google Firebase provide sign-in. Our Google Cloud backend keeps the account identifier, your confirmation and pseudonymous usage/session metadata to manage access and limits. No advertising profiles."))
        Text(copy("Sprache: Bei einem gestarteten Gespräch geht Audio direkt an OpenAI. Sprache und begrenzte Lernstandsangaben helfen bei der Anleitung. Kurze Gesprächsauszüge zur Auswertung von Uhrzeit-Antworten gehen über unser Backend an OpenAI. Stopp beendet die lokale Aufnahme sofort.", "Voice: during a conversation, audio goes directly to OpenAI. Language and limited learning-progress information guide the lesson. Short conversation excerpts for interpreting clock answers pass through our backend to OpenAI. Stop ends local recording immediately."))
        Text(copy("Helden: Ideen, kurze Aufnahmen und Bilder gehen über unser Backend an OpenAI. Temporäre Aufnahmen werden nach der Anfrage gelöscht. Unser Backend speichert keine Gesprächsaufnahmen, Transkripte oder Bilder dauerhaft.", "Heroes: ideas, short recordings and images pass through our backend to OpenAI. Temporary recordings are removed after the request. Our backend does not persist conversation recordings, transcripts or images."))
        Text(copy("Aufbewahrung: Sitzungsmetadaten haben eine Löschfrist von 30 Tagen. Ein pseudonymer Nachweis verbrauchter Testzeit bleibt gegen Mehrfachnutzung erhalten. Bestätigungsdaten bleiben während des Kontobestands und bis zu 30 Tage nach Kontolöschung. Anbieter können Daten nach eigenen Bedingungen verarbeiten; eine Zero-Data-Retention-Freigabe für Kinder ist noch nicht bestätigt. Verarbeitung außerhalb der EU ist möglich.", "Retention: session metadata has a 30-day expiry. A pseudonymous record of trial use is retained to prevent repeat trials. Confirmation data is kept for the account lifetime and up to 30 days after account deletion. Providers may process data under their own terms; Zero Data Retention for children's use is not yet verified. Processing outside the EU is possible."))
        Text(copy("Deine Rechte: Auskunft, Berichtigung, Löschung und weitere gesetzliche Datenschutzrechte bleiben bestehen. Berechtigungen widerrufst du hier; Kontolöschung und lokale Datenlöschung sind getrennte Aktionen. Vor einer öffentlichen Freigabe werden verantwortlicher Betreiber, Kontakt, Rechtsgrundlagen und internationale Übermittlungen abschließend geprüft und veröffentlicht.", "Your rights: access, correction, deletion and other statutory privacy rights remain available. Withdraw permissions here; account deletion and local data deletion are separate actions. Before public release, the responsible operator, contact, legal bases and international transfers will be reviewed and published."))
        }
    }
    private func copy(_ de: String, _ en: String) -> String { language == .german ? de : en }
}
