import SwiftUI

@MainActor
struct RootView: View {
    @Bindable var preferences: ParentPreferences
    @Bindable var learningViewModel: LearningViewModel
    @Bindable var voiceCoach: VoiceCoachCoordinator
    @Bindable var heroLabViewModel: HeroLabViewModel

    let generatedHeroImageStore: GeneratedHeroImageStore
    let usesHeroGenerationUITestFixture: Bool

    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var showingParentSettings = false
    @State private var pendingVoiceQuestion: TimeQuestion?
    @State private var selectedHeroBackgroundData: Data?
    @State private var voiceChildID: UUID?

    var body: some View {
        lifecycleAwareTabs
        .task {
            if preferences.cloudVoiceMode == .managedAccount,
               preferences.agreementAcceptance?.accountID != ParentAccount.shared.accountID {
                preferences.clearAgreement()
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-voice-status") {
                voiceCoach.showCoachSpeakingStatusForUITesting()
            }
            #endif
            voiceCoach.onClockAnswer = { report in
                guard voiceChildID == learningViewModel.journeys?.selectedID,
                      let hour = report.hour, let minute = report.minute, !report.unknown else {
                    return
                }
                learningViewModel.chooseSpoken(ClockTime(hour: hour, minute: minute))
            }
            voiceCoach.onLiveClockAnswer = { report, questionID in
                guard voiceChildID == learningViewModel.journeys?.selectedID,
                      learningViewModel.question.id == questionID,
                      let hour = report.hour, let minute = report.minute, !report.unknown else { return }
                learningViewModel.chooseSpoken(ClockTime(hour: hour, minute: minute))
            }
            voiceCoach.onSpokenCorrectAnswerFeedbackFinished = { questionID, _ in
                guard voiceChildID == learningViewModel.journeys?.selectedID,
                      learningViewModel.question.id == questionID else { return }
                learningViewModel.continueAfterSpokenFeedback(questionID: questionID)
            }
            voiceCoach.onLiveAdvanceRequested = { questionID in
                guard selectedTab == 0, !showingParentSettings,
                      voiceChildID == learningViewModel.journeys?.selectedID,
                      learningViewModel.question.id == questionID else { return }
                learningViewModel.continueAfterSpokenFeedback(questionID: questionID)
            }
            voiceCoach.onSpokenAutoAdvanceCancelled = {
                learningViewModel.cancelSpokenAutoAdvance()
            }
            if let saved = try? await generatedHeroImageStore.loadSelectedBackground() {
                selectedHeroBackgroundData = saved.imageData
            }
        }
    }

    // Smaller opaque view expressions keep Xcode 26.2 type checking bounded.
    private var lifecycleAwareTabs: some View {
        permissionAwareTabs
        .onChange(of: learningViewModel.question.id) { _, _ in
            guard voiceCoach.isSessionActive else { return }
            Task { await voiceCoach.updateChallenge(learningViewModel.question) }
        }
        .onChange(of: voiceCoach.phase) { _, phase in
            if phase == .listening, voiceChildID == learningViewModel.journeys?.selectedID {
                learningViewModel.journeys?.markVoiceLearningStarted()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { preferences.refreshDeviceLanguage() }
            if phase != .active {
                voiceCoach.stopLocalAudioImmediately()
                Task { await voiceCoach.stop() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .generatedHeroImagesWillDelete)) { _ in
            selectedHeroBackgroundData = nil
        }
    }

    private var permissionAwareTabs: some View {
        configuredTabs
        .onChange(of: learningViewModel.language) { _, language in
            let shouldRestartVoice = voiceCoach.isSessionActive || voiceCoach.isStarting
            if shouldRestartVoice {
                voiceCoach.stopLocalAudioImmediately()
                Task {
                    await voiceCoach.stop()
                    guard cloudVoiceIsReady, selectedTab == 0 else { return }
                    voiceChildID = learningViewModel.journeys?.selectedID
                    await voiceCoach.start(
                        question: learningViewModel.question,
                        preferences: preferences,
                        learner: learningViewModel.journeys?.selected.voiceLearningContext
                    )
                }
            }
        }
        .onChange(of: preferences.language) { _, language in
            learningViewModel.setLanguage(language.learningLanguage)
        }
        .onChange(of: preferences.hasCloudVoiceConsent) { _, enabled in
            if !enabled {
                voiceCoach.stopLocalAudioImmediately()
                Task { await voiceCoach.stop() }
            }
        }
        .onChange(of: preferences.hasHeroGenerationConsent) { _, enabled in
            if !enabled { heroLabViewModel.cancelCloudWork() }
        }
    }

    private var configuredTabs: some View {
        VStack(spacing: 0) {
            // Keep scrollable content above the fixed controls. The custom
            // navigation below is the only tab bar.
            tabs
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            VStack(spacing: 0) {
                if selectedTab == 0, learningViewModel.canContinue {
                    LearningNextQuestionControl(viewModel: learningViewModel)
                }
                #if DEBUG
                if usesHeroGenerationUITestFixture {
                    HeroUITestCompletionControls()
                }
                #endif
                if selectedTab == 0, voiceCoach.phase.isVisible {
                    VoiceCoachStatusBar(
                        coordinator: voiceCoach,
                        language: preferences.language
                    )
                }
                MainTabBar(
                    selection: tabSelection,
                    language: learningViewModel.language
                )
            }
        }
        .background(learningViewModel.question.heroTheme.palette.background.ignoresSafeArea())
        .tint(.indigo)
        // ZeitHeld uses a fixed, bright learning palette. Keeping the app in a
        // light appearance prevents system controls from silently switching to
        // dark surfaces while the teaching text remains dark blue.
        .preferredColorScheme(.light)
        .sheet(isPresented: $showingParentSettings, onDismiss: parentSettingsDismissed) {
            ParentSettingsView(
                preferences: preferences,
                generatedHeroImageStore: generatedHeroImageStore,
                learningViewModel: learningViewModel
            ) {
                showingParentSettings = false
            }
        }
    }

    @ViewBuilder
    private var tabs: some View {
        switch selectedTab {
        case 0:
            NavigationStack {
                LearningView(
                    viewModel: learningViewModel,
                    isVoiceAvailable: true,
                    isVoiceRequestEnabled: !voiceCoach.isStarting
                        && !voiceCoach.isStopping
                        && !voiceCoach.isSessionActive,
                    showsNextQuestionControl: false,
                    customHeroBackgroundData: selectedHeroBackgroundData,
                    onVoiceCoachRequested: requestVoiceCoach
                )
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            tabSelection.wrappedValue = 2
                        } label: {
                            Label(learningViewModel.journeys?.selected.name ?? copy(de: "Meine Lernreise", en: "My journey"), systemImage: "person.crop.circle")
                                .lineLimit(1)
                        }
                        .accessibilityIdentifier("current-child-button")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: openParentSettings) {
                            Image(systemName: "gearshape.fill")
                        }
                        .accessibilityLabel(copy(de: "Einstellungen", en: "Settings"))
                        .accessibilityIdentifier("parent-settings-button")
                    }
                }
            }
        case 1:
            HeroLabView(
                language: learningViewModel.language,
                isOnlineEnabled: heroFixtureIsEnabled || heroLabIsReady,
                requestParentAccess: openParentSettings,
                credentialProvider: heroCredential,
                onBackgroundSelected: { imageData in
                    selectedHeroBackgroundData = imageData
                    selectedTab = 0
                },
                onReturnToClock: { selectedTab = 0 },
                viewModel: heroLabViewModel
            )
        default:
            JourneyView(model: learningViewModel, onLearn: { selectedTab = 0 }, onSettings: openParentSettings)
        }
    }

    private var tabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { tab in
                if tab != 0 {
                    voiceCoach.stopLocalAudioImmediately()
                    Task { await voiceCoach.stop() }
                }
                selectedTab = tab
            }
        )
    }

    private func requestVoiceCoach(_ question: TimeQuestion) {
        guard cloudVoiceIsReady else {
            pendingVoiceQuestion = question
            openParentSettings()
            return
        }
        Task {
            voiceChildID = learningViewModel.journeys?.selectedID
            await voiceCoach.start(question: learningViewModel.question, preferences: preferences,
                                   learner: learningViewModel.journeys?.selected.voiceLearningContext)
        }
    }

    private var cloudVoiceIsReady: Bool {
        guard preferences.hasCurrentAgreement, preferences.hasCloudVoiceConsent else { return false }
        switch preferences.cloudVoiceMode {
        case .offline:
            return false
        case .parentKey:
            return preferences.hasStoredAPIKey
        case .managedBroker:
            return (try? preferences.validatedBrokerURL()) != nil
        case .managedAccount:
            return ParentAccount.shared.signedIn
        }
    }

    private var heroLabIsReady: Bool {
        preferences.hasCurrentAgreement && preferences.hasHeroGenerationConsent && (preferences.cloudVoiceMode == .managedAccount
            ? ParentAccount.shared.signedIn : preferences.hasStoredAPIKey)
    }

    private var heroFixtureIsEnabled: Bool {
        #if DEBUG
        usesHeroGenerationUITestFixture
        #else
        false
        #endif
    }

    private func heroCredential() throws -> HeroCredential? {
        #if DEBUG
        if usesHeroGenerationUITestFixture {
            return .parentKey(HeroGenerationUITestFixture.credential)
        }
        #endif
        if preferences.cloudVoiceMode == .managedAccount { return .managedAccount }
        return try preferences.apiKeyForEphemeralTokenRequest().map(HeroCredential.parentKey)
    }

    private func openParentSettings() {
        voiceCoach.stopLocalAudioImmediately()
        Task { await voiceCoach.stop() }
        showingParentSettings = true
    }

    private func parentSettingsDismissed() {
        if preferences.cloudVoiceMode == .offline || !preferences.hasCloudVoiceConsent {
            Task { await voiceCoach.stop() }
        }
        guard pendingVoiceQuestion != nil else { return }
        pendingVoiceQuestion = nil
        guard cloudVoiceIsReady else { return }
        Task {
            voiceChildID = learningViewModel.journeys?.selectedID
            await voiceCoach.start(question: learningViewModel.question, preferences: preferences,
                                   learner: learningViewModel.journeys?.selected.voiceLearningContext)
        }
    }

    private func copy(de: String, en: String) -> String {
        learningViewModel.language == .german ? de : en
    }
}

private struct MainTabBar: View {
    @Binding var selection: Int
    let language: LearningLanguage

    var body: some View {
        HStack(spacing: 8) {
            tabButton(
                index: 0,
                title: copy(de: "Uhr lernen", en: "Learn"),
                systemImage: "clock.fill",
                accessibilityIdentifier: "learn-tab"
            )
            tabButton(
                index: 1,
                title: copy(de: "Helden-Labor", en: "Hero Lab"),
                systemImage: "sparkles.rectangle.stack.fill",
                accessibilityIdentifier: "hero-lab-tab"
            )
            tabButton(index: 2, title: copy(de: "Lernreise", en: "Journey"),
                      systemImage: "map.fill", accessibilityIdentifier: "journey-tab")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.white.opacity(0.28)
            }
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Divider()
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: -3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("main-tab-bar")
    }

    private func tabButton(
        index: Int,
        title: String,
        systemImage: String,
        accessibilityIdentifier: String
    ) -> some View {
        Button {
            selection = index
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .bold))
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(
                selection == index
                    ? Color.indigo
                    : Color(red: 0.20, green: 0.25, blue: 0.29)
            )
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                selection == index ? Color.indigo.opacity(0.13) : Color.clear,
                in: RoundedRectangle(cornerRadius: 18)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityAddTraits(selection == index ? .isSelected : [])
    }

    private func copy(de: String, en: String) -> String {
        language == .german ? de : en
    }
}
