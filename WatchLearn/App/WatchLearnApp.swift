import SwiftUI

@main
@MainActor
struct WatchLearnApp: App {
    @State private var preferences: ParentPreferences
    @State private var learningViewModel: LearningViewModel
    @State private var voiceCoach = VoiceCoachCoordinator()
    @State private var heroLabViewModel: HeroLabViewModel

    private let generatedHeroImageStore: GeneratedHeroImageStore
    private let usesHeroGenerationUITestFixture: Bool

    init() {
        let preferences = ParentPreferences()

        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let isUITesting = arguments.contains("--ui-testing")
        let persistsProgressDuringUITest = arguments.contains("--ui-testing-persist-progress")
        let preservesUITestState = arguments.contains("--ui-testing-preserve-state")
        let usesHeroGenerationUITestFixture = isUITesting
            && arguments.contains(HeroGenerationUITestFixture.launchArgument)
        preferences.resetForUITesting()
        let progressStore = !isUITesting || persistsProgressDuringUITest
            ? LearningProgressStore()
            : nil
        if isUITesting, persistsProgressDuringUITest, !preservesUITestState {
            progressStore?.clear()
        }
        let lessonSeed = isUITesting
            ? LearningViewModel.deterministicSeed
            : UInt64.random(in: UInt64.min...UInt64.max)

        let generatedHeroImageStore: GeneratedHeroImageStore
        if usesHeroGenerationUITestFixture {
            if !preservesUITestState {
                HeroGenerationUITestFixture.resetStore()
            }
            generatedHeroImageStore = GeneratedHeroImageStore(
                directory: HeroGenerationUITestFixture.storeDirectory()
            )
        } else {
            generatedHeroImageStore = GeneratedHeroImageStore()
        }
        let imageGenerator: any HeroImageGenerating = usesHeroGenerationUITestFixture
            ? DelayedHeroImageUITestGenerator()
            : OpenAIHeroImageGenerationService()
        let usageBudget: any HeroCloudUsageBudgeting = usesHeroGenerationUITestFixture
            ? UnlimitedHeroCloudUsageBudget()
            : PersistentHeroCloudUsageBudget()
        let heroRecorder: any HeroDescriptionRecording = usesHeroGenerationUITestFixture
            ? HeroVoiceInputUITestRecorder() : HeroDescriptionRecorder()
        let heroTranscriber: any HeroDescriptionTranscribing = usesHeroGenerationUITestFixture
            ? HeroVoiceInputUITestTranscriber() : OpenAITranscriptionService()
        #else
        let progressStore: LearningProgressStore? = LearningProgressStore()
        let lessonSeed = UInt64.random(in: UInt64.min...UInt64.max)
        let generatedHeroImageStore = GeneratedHeroImageStore()
        let usesHeroGenerationUITestFixture = false
        let imageGenerator: any HeroImageGenerating = OpenAIHeroImageGenerationService()
        let usageBudget: any HeroCloudUsageBudgeting = PersistentHeroCloudUsageBudget()
        let heroRecorder: any HeroDescriptionRecording = HeroDescriptionRecorder()
        let heroTranscriber: any HeroDescriptionTranscribing = OpenAITranscriptionService()
        #endif

        #if DEBUG
        let journeyDefaults: UserDefaults? = isUITesting && !persistsProgressDuringUITest ? nil : .standard
        if isUITesting, persistsProgressDuringUITest, !preservesUITestState {
            journeyDefaults?.removeObject(forKey: ChildJourneyStore.storageKey)
        }
        #else
        let journeyDefaults: UserDefaults? = .standard
        #endif
        let journeys = ChildJourneyStore(defaults: journeyDefaults, initialProgress: progressStore?.load(),
            defaultName: preferences.language == .german ? "Mein ZeitHeld" : "My Time Hero")
        _preferences = State(initialValue: preferences)
        _learningViewModel = State(initialValue: LearningViewModel(
            language: preferences.language.learningLanguage,
            startingLevel: .fullHour,
            seed: lessonSeed,
            progressStore: progressStore,
            journeys: journeys
        ))
        _heroLabViewModel = State(initialValue: HeroLabViewModel(
            imageGenerator: imageGenerator,
            transcriber: heroTranscriber,
            recorder: heroRecorder,
            store: generatedHeroImageStore,
            usageBudget: usageBudget
        ))
        self.generatedHeroImageStore = generatedHeroImageStore
        self.usesHeroGenerationUITestFixture = usesHeroGenerationUITestFixture
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                preferences: preferences,
                learningViewModel: learningViewModel,
                voiceCoach: voiceCoach,
                heroLabViewModel: heroLabViewModel,
                generatedHeroImageStore: generatedHeroImageStore,
                usesHeroGenerationUITestFixture: usesHeroGenerationUITestFixture
            )
        }
    }
}

extension InterfaceLanguage {
    var learningLanguage: LearningLanguage {
        self == .german ? .german : .english
    }

    var realtimeLanguage: RealtimeCoachLanguage {
        self == .german ? .german : .english
    }
}

extension LearningLanguage {
    var interfaceLanguage: InterfaceLanguage {
        self == .german ? .german : .english
    }

    var realtimeLanguage: RealtimeCoachLanguage {
        self == .german ? .german : .english
    }
}
