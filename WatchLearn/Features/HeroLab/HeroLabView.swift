import SwiftUI
import UIKit

@MainActor
struct HeroLabView: View {
    let language: LearningLanguage
    let isOnlineEnabled: Bool
    let requestParentAccess: () -> Void
    let credentialProvider: @MainActor () throws -> HeroCredential?
    let onBackgroundSelected: @MainActor (Data) -> Void
    let onReturnToClock: @MainActor () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable private var viewModel: HeroLabViewModel
    @State private var voiceTask: Task<Void, Never>?
    @State private var selectionTask: Task<Void, Never>?
    @State private var showingChoices = false
    @FocusState private var isDescriptionFocused: Bool

    init(
        language: LearningLanguage,
        isOnlineEnabled: Bool,
        requestParentAccess: @escaping () -> Void,
        credentialProvider: @escaping @MainActor () throws -> HeroCredential?,
        onBackgroundSelected: @escaping @MainActor (Data) -> Void,
        onReturnToClock: @escaping @MainActor () -> Void = {},
        viewModel: HeroLabViewModel
    ) {
        self.language = language
        self.isOnlineEnabled = isOnlineEnabled
        self.requestParentAccess = requestParentAccess
        self.credentialProvider = credentialProvider
        self.onBackgroundSelected = onBackgroundSelected
        self.onReturnToClock = onReturnToClock
        self.viewModel = viewModel
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 20) {
                        descriptionCard
                        onlineStatusCard
                        Button {
                            withAnimation { showingChoices.toggle() }
                        } label: {
                            HStack {
                                Text(copy(de: "Eigenschaften auswählen (optional)", en: "Choose extra details (optional)"))
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: showingChoices ? "chevron.up" : "chevron.down")
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.headline)
                        .foregroundStyle(.indigo)
                        .accessibilityValue(showingChoices ? copy(de: "Geöffnet", en: "Expanded") : copy(de: "Geschlossen", en: "Collapsed"))
                        .accessibilityIdentifier("hero-optional-choices")
                        if showingChoices { choices }
                        if viewModel.latestImageData != nil {
                            heroPreview
                                .id("hero-preview-scroll-target")
                        }
                        createCard
                    }
                    .padding(20)
                    .padding(.bottom, 20)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(
                    LinearGradient(
                        colors: [.indigo.opacity(0.10), .orange.opacity(0.08), .white],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .onChange(of: viewModel.latestImageData) { oldImage, newImage in
                    guard let newImage, newImage != oldImage else { return }
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.84)) {
                            scrollProxy.scrollTo("hero-preview-scroll-target", anchor: .top)
                        }
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: copy(
                                de: "Dein neues Heldenbild ist fertig.",
                                en: "Your new hero picture is ready."
                            )
                        )
                    }
                }
            }
            .navigationTitle(copy(de: "Helden-Labor", en: "Hero Lab"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(copy(de: "Fertig", en: "Done")) { isDescriptionFocused = false }
                        .accessibilityIdentifier("hero-description-done")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        handleViewDisappearance()
                        onReturnToClock()
                    } label: {
                        Label(copy(de: "Zur Uhr", en: "Back to clock"), systemImage: "chevron.left")
                    }
                    .accessibilityIdentifier("hero-back-to-clock")
                }
            }
        }
        .task { await viewModel.loadSavedImages() }
        .onReceive(NotificationCenter.default.publisher(for: .generatedHeroImagesWillDelete)) { _ in
            cancelCloudWork()
        }
        .onReceive(NotificationCenter.default.publisher(for: .generatedHeroImagesDeleted)) { _ in
            Task { await viewModel.loadSavedImages() }
        }
        .onDisappear { handleViewDisappearance() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                cancelCloudWork()
            }
        }
        .onChange(of: isOnlineEnabled) { _, enabled in
            if !enabled {
                cancelCloudWork()
            }
        }
        .alert(
            copy(de: "Das hat noch nicht geklappt", en: "That did not work yet"),
            isPresented: Binding(
                get: { viewModel.issue != nil },
                set: { if !$0 { viewModel.clearIssue() } }
            )
        ) {
            if viewModel.issue == .parentSetupRequired {
                Button(copy(de: "Einstellungen öffnen", en: "Open settings")) {
                    viewModel.clearIssue()
                    requestParentAccess()
                }
            }
            Button("OK", role: .cancel) { viewModel.clearIssue() }
        } message: {
            Text(viewModel.issue?.message(in: language) ?? "")
        }
    }

    private var heroPreview: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let data = viewModel.latestImageData,
                   let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image("HeroEmber")
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(height: 320)
            .frame(maxWidth: .infinity)
            .clipped()

            VStack(alignment: .leading, spacing: 5) {
                Text(copy(de: "Erschaffe deinen Zeithelden!", en: "Create your Time Hero!"))
                    .font(.system(.title2, design: .rounded, weight: .heavy))
                Text(copy(
                    de: "Große Action. Freundlich. Ganz neu.",
                    en: "Big action. Friendly. Completely original."
                ))
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.52))
        }
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .stroke(.white.opacity(0.8), lineWidth: 2)
        }
        .shadow(color: .black.opacity(0.14), radius: 14, y: 7)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hero-lab-preview")
    }

    private var onlineStatusCard: some View {
        KidCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isOnlineEnabled ? "checkmark.shield.fill" : "lock.shield.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(isOnlineEnabled ? .green : .indigo)

                VStack(alignment: .leading, spacing: 6) {
                    Text(isOnlineEnabled
                         ? copy(de: "Online-Bilder sind eingeschaltet", en: "Online pictures are enabled")
                         : copy(de: "Online-Bilder sind ausgeschaltet", en: "Online pictures are off"))
                        .font(.system(.headline, design: .rounded, weight: .bold))

                    Text(copy(
                        de: "Schreiben und Auswählen geht offline. Zum Einsprechen und Erstellen meldet sich eine erwachsene Person in den Einstellungen an.",
                        en: "Writing and choosing details work offline. To speak your idea and create pictures, a parent signs in through Settings."
                    ))
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)

                    if !isOnlineEnabled {
                        Button(action: requestParentAccess) {
                            Label(
                                copy(de: "Einstellungen öffnen", en: "Open settings"),
                                systemImage: "gearshape.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityIdentifier("hero-lab-parent-setup")
                    }
                }
            }
        }
    }

    private var choices: some View {
        VStack(spacing: 16) {
            choiceGrid(
                title: copy(de: "Wie sieht dein Held aus?", en: "What does your hero look like?"),
                options: HeroSkinTone.allCases,
                selection: $viewModel.design.skinTone,
                label: { $0.title(in: language) },
                icon: { _ in "face.smiling.fill" }
            )
            choiceGrid(
                title: copy(de: "Wähle eine Kraft", en: "Choose a power"),
                options: HeroPower.allCases,
                selection: $viewModel.design.power,
                label: { $0.title(in: language) },
                icon: { $0.systemImage }
            )
            choiceGrid(
                title: copy(de: "Wähle die Ausrüstung", en: "Choose the gear"),
                options: HeroGear.allCases,
                selection: $viewModel.design.gear,
                label: { $0.title(in: language) },
                icon: { $0.systemImage }
            )
            choiceGrid(
                title: copy(de: "Wähle die Action-Welt", en: "Choose the action world"),
                options: HeroScene.allCases,
                selection: $viewModel.design.scene,
                label: { $0.title(in: language) },
                icon: { $0.systemImage }
            )
        }
    }

    private func choiceGrid<Option: Hashable & Identifiable>(
        title: String,
        options: [Option],
        selection: Binding<Option>,
        label: @escaping (Option) -> String,
        icon: @escaping (Option) -> String
    ) -> some View {
        KidCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(.title3, design: .rounded, weight: .heavy))

                LazyVGrid(
                    columns: dynamicTypeSize.isAccessibilitySize
                        ? [GridItem(.flexible())]
                        : [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 10
                ) {
                    ForEach(options) { option in
                        Button {
                            selection.wrappedValue = option
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: icon(option))
                                    .font(.system(size: 23, weight: .bold))
                                Text(label(option))
                                    .multilineTextAlignment(.center)
                            }
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .frame(maxWidth: .infinity, minHeight: 72)
                            .padding(.horizontal, 7)
                            .foregroundStyle(selection.wrappedValue == option ? .white : .indigo)
                            .background(
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(selection.wrappedValue == option ? Color.indigo : Color.indigo.opacity(0.10))
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(.indigo.opacity(0.28), lineWidth: 2)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection.wrappedValue == option ? .isSelected : [])
                    }
                }
            }
        }
    }

    private var descriptionCard: some View {
        KidCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(copy(de: "Beschreibe deinen Helden", en: "Describe your hero"))
                    .font(.system(.title3, design: .rounded, weight: .heavy))
                    .accessibilityIdentifier("hero-description-title")
                Text(copy(
                    de: "Erzähl oder schreib, wie dein Held aussehen soll und was er kann. Danach kannst du weitere Eigenschaften auswählen – oder gleich dein Bild erstellen.",
                    en: "Tell us or write what your hero looks like and what they can do. Then choose extra details if you like, or create your picture straight away."
                ))
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)

                voiceInputStatus

                ZStack(alignment: .topLeading) {
                    if viewModel.descriptionText.isEmpty {
                        Text(copy(de: "Deine Helden-Idee …", en: "Your hero idea …"))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 12)
                    }
                    TextEditor(text: $viewModel.descriptionText)
                        .focused($isDescriptionFocused)
                        .frame(minHeight: 92)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("hero-description-text")
                }

                Text("\(viewModel.descriptionText.count)/\(HeroPromptPolicy.maximumDescriptionLength)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(viewModel.descriptionText.count > HeroPromptPolicy.maximumDescriptionLength ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Button(action: toggleVoice) {
                    Label(
                        viewModel.isRecording
                            ? copy(de: "Stopp – Idee übernehmen", en: "Stop and use my idea")
                            : voiceButtonLabel,
                        systemImage: viewModel.isRecording ? "stop.circle.fill" : "mic.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(HeroButtonStyle(
                    color: viewModel.isRecording ? .red : .indigo
                ))
                .disabled(viewModel.isBusy || (viewModel.isRecording && !viewModel.isMicrophoneActive)
                          || (!isOnlineEnabled && !viewModel.isRecording))
                .accessibilityIdentifier("hero-description-microphone")
            }
        }
    }

    @ViewBuilder private var voiceInputStatus: some View {
        if viewModel.isMicrophoneActive {
            TimelineView(.animation(minimumInterval: 0.1)) { _ in
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Label(copy(de: "Ich höre dir zu!", en: "I'm listening!"), systemImage: "mic.fill")
                        Spacer()
                        Text("\(viewModel.recordingSecondsRemaining) s")
                            .monospacedDigit()
                    }
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    ProgressView(value: viewModel.microphoneLevel)
                        .tint(.red)
                        .accessibilityLabel(copy(de: "Mikrofonpegel", en: "Microphone level"))
                    Text(copy(de: "Beschreibe deinen Helden. Tippe auf Stopp, wenn du fertig bist.",
                              en: "Describe your hero. Tap Stop when you're ready."))
                        .font(.subheadline)
                }
                .padding(12)
                .foregroundStyle(.red)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
            .accessibilityIdentifier("hero-recording-status")
        } else if viewModel.isRecording {
            ProgressView(copy(de: "Mikrofon wird vorbereitet …", en: "Getting the microphone ready …"))
        } else if viewModel.phase == .transcribing {
            ProgressView(copy(de: "Aufgenommen! Ich schreibe deine Beschreibung auf …",
                              en: "Got it! Writing down your description …"))
                .accessibilityIdentifier("hero-transcribing-status")
        } else if viewModel.voiceDescriptionAccepted {
            Label(copy(de: "Beschreibung übernommen – du kannst sie noch ändern.",
                       en: "Description added — you can still change it."), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline)
                .accessibilityIdentifier("hero-description-accepted")
        }
    }

    private var createCard: some View {
        KidCard {
            VStack(spacing: 14) {
                Text(viewModel.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? viewModel.design.childSummary(in: language)
                     : copy(de: "Deine Idee wird zu deinem Heldenbild", en: "Your idea becomes your hero picture"))
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.indigo)

                if viewModel.phase == .generating || viewModel.phase == .saving {
                    ProgressView()
                        .controlSize(.large)
                    Text(copy(
                        de: "Dein Held springt gleich ins Bild …",
                        en: "Your hero is about to leap into the picture …"
                    ))
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("hero-generation-status")
                }

                Button(action: createHero) {
                    Label(
                        copy(de: "Neues Action-Bild erstellen", en: "Create a new action picture"),
                        systemImage: "sparkles.rectangle.stack.fill"
                    )
                }
                .buttonStyle(HeroButtonStyle(color: .orange))
                .disabled(viewModel.isBusy || viewModel.isRecording || !isOnlineEnabled)
                .accessibilityIdentifier("hero-generate-button")

                if viewModel.latestImageData != nil {
                    Button(action: selectBackground) {
                        Label(
                            copy(de: "Als Uhren-Hintergrund benutzen", en: "Use as my clock background"),
                            systemImage: "checkmark.circle.fill"
                        )
                    }
                    .buttonStyle(HeroButtonStyle(color: .green, isProminent: false))
                    .disabled(viewModel.isBusy || viewModel.isRecording)
                    .accessibilityIdentifier("hero-select-background")
                }

                Text(copy(
                    de: "Vor dem Anzeigen prüft die App deine Beschreibung und das fertige Bild. Das Bild bleibt danach lokal auf diesem Gerät.",
                    en: "Before showing it, the app checks your description and the finished picture. The picture is then kept locally on this device."
                ))
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
    }

    private var voiceButtonLabel: String {
        switch viewModel.phase {
        case .transcribing:
            copy(de: "Idee wird aufgeschrieben …", en: "Writing down the idea …")
        default:
            copy(de: "Beschreibe deinen Helden", en: "Describe your hero")
        }
    }

    private func toggleVoice() {
        isDescriptionFocused = false
        if viewModel.isRecording {
            viewModel.stopVoiceDescription()
            return
        }
        guard let apiKey = onlineCredential() else { return }
        voiceTask?.cancel()
        voiceTask = Task {
            await viewModel.toggleVoiceDescription(credential: apiKey, language: language)
        }
    }

    private func cancelVoiceWork() {
        voiceTask?.cancel()
        voiceTask = nil
        viewModel.cancelVoiceDescription()
    }

    private func handleViewDisappearance() {
        voiceTask?.cancel()
        voiceTask = nil
        viewModel.viewDidDisappear()
    }

    private func cancelCloudWork() {
        cancelVoiceWork()
        selectionTask?.cancel()
        selectionTask = nil
        viewModel.cancelCloudWork()
    }

    private func createHero() {
        guard let apiKey = onlineCredential() else { return }
        viewModel.startGeneration(credential: apiKey)
    }

    private func selectBackground() {
        selectionTask?.cancel()
        selectionTask = Task {
            if let data = await viewModel.selectLatestAsBackground() {
                guard !Task.isCancelled, isOnlineEnabled else { return }
                onBackgroundSelected(data)
            }
        }
    }

    private func onlineCredential() -> HeroCredential? {
        guard isOnlineEnabled else {
            viewModel.requireParentSetup()
            return nil
        }
        do {
            guard let key = try credentialProvider(), key.isAvailable else {
                viewModel.requireParentSetup()
                return nil
            }
            return key
        } catch {
            viewModel.requireParentSetup()
            return nil
        }
    }

    private func copy(de: String, en: String) -> String {
        language == .german ? de : en
    }
}
