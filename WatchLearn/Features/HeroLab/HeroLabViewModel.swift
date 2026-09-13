import Foundation
import Observation

enum HeroLabPhase: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case generating
    case coloring
    case saving
}

enum HeroLabIssue: Equatable, Sendable {
    case parentSetupRequired
    case policy(HeroPromptPolicyError)
    case microphoneDenied
    case microphoneFailed
    case safetyRejected
    case onlineFailed(status: Int?, requestID: String?)
    case invalidResponse
    case invalidTranscript
    case localSaveFailed
    case localCleanupFailed
    case usageLimit(HeroCloudUsageBudgetError)
    case serviceLimit(HeroServiceLimit)

    func message(in language: LearningLanguage) -> String {
        switch (self, language) {
        case (.parentSetupRequired, .german):
            "Schalte das Online-Heldenlabor in den Einstellungen ein."
        case (.parentSetupRequired, .english):
            "Turn on the online Hero Lab in Settings."
        case let (.policy(error), .german):
            switch error {
            case .emptyDescription: "Wähle Bilder oder erzähle zuerst von deinem Helden."
            case .existingCharacter: "Erfinde bitte einen ganz neuen Helden ohne bekannte Figuren oder Marken."
            case .unsafeAction: "Wähle bitte eine freundliche Kraft ohne Waffen, Blut oder Grusel."
            case .personalInformation: "Lass Namen, Adresse, Telefon und andere private Dinge weg."
            case .promptManipulation: "Diese Anweisung kann nicht für ein Heldenbild verwendet werden."
            }
        case let (.policy(error), .english):
            error.localizedDescription
        case (.microphoneDenied, .german):
            "Das Mikrofon ist aus. Eine erwachsene Person kann es in den iOS-Einstellungen erlauben."
        case (.microphoneDenied, .english):
            "The microphone is off. A grown-up can allow it in iOS Settings."
        case (.microphoneFailed, .german):
            "Die Aufnahme hat nicht geklappt. Du kannst es noch einmal versuchen oder die Bild-Knöpfe nutzen."
        case (.microphoneFailed, .english):
            "Recording did not work. Try again or use the picture buttons."
        case (.safetyRejected, .german):
            "Der Kinder-Sicherheitsfilter hat diese Idee oder dieses Bild gestoppt. Probiere eine freundlichere Idee."
        case (.safetyRejected, .english):
            "The child-safety filter stopped that idea or picture. Try a friendlier idea."
        case (.serviceLimit(.cooldown), .german):
            "Kurze Heldenpause: Bitte warte bis zu 15 Sekunden und versuche es noch einmal. Deine Idee bleibt erhalten."
        case (.serviceLimit(.cooldown), .english):
            "A short hero break: please wait up to 15 seconds and try again. Your idea is still here."
        case (.serviceLimit(.busy), .german), (.onlineFailed(status: 429, requestID: _), .german):
            "Das Heldenlabor hat gerade viel zu tun. Warte kurz und versuche es noch einmal. Deine Idee bleibt erhalten."
        case (.serviceLimit(.busy), .english), (.onlineFailed(status: 429, requestID: _), .english):
            "The Hero Lab is busy right now. Wait a moment and try again. Your idea is still here."
        case (.serviceLimit(.daily), .german):
            "Das Online-Heldenlabor hat sein Tageslimit erreicht. Morgen geht es weiter. Deine Idee bleibt erhalten."
        case (.serviceLimit(.daily), .english):
            "The online Hero Lab has reached its daily limit. Try again tomorrow. Your idea is still here."
        case (.serviceLimit(.trial), .german):
            "Die kostenlosen Versuche im Heldenlabor sind aufgebraucht. Eine erwachsene Person kann in den Einstellungen einen eigenen API-Key hinzufügen."
        case (.serviceLimit(.trial), .english):
            "The free Hero Lab attempts are used up. A grown-up can add their own API key in Settings."
        case (.onlineFailed, .german):
            "Das Online-Heldenlabor ist gerade nicht erreichbar. Bitte versuche es später noch einmal."
        case (.onlineFailed, .english):
            "The online Hero Lab is not available right now. Please try again later."
        case (.invalidResponse, .german):
            "Das Heldenbild konnte nicht gelesen werden. Bitte versuche es erneut."
        case (.invalidResponse, .english):
            "The hero picture could not be read. Please try again."
        case (.invalidTranscript, .german):
            "Die Sprachidee konnte nicht gelesen werden. Bitte sprich noch einmal kurz und deutlich."
        case (.invalidTranscript, .english):
            "The voice idea could not be read. Please try again with one short, clear sentence."
        case (.localSaveFailed, .german):
            "Das Bild wurde erstellt, konnte aber nicht auf diesem Gerät gespeichert werden."
        case (.localSaveFailed, .english):
            "The picture was created but could not be saved on this device."
        case (.localCleanupFailed, .german):
            "Ein abgebrochenes Bild konnte nicht entfernt werden. Bitte lösche die lokalen Heldenbilder unter Einstellungen."
        case (.localCleanupFailed, .english):
            "An interrupted picture could not be removed. Please delete local hero images in Settings."
        case let (.usageLimit(error), .german):
            switch error {
            case let .cooldown(_, seconds):
                "Kurze Heldenpause: Bitte warte noch \(seconds) Sekunden."
            case .dailyLimit(.image), .dailyLimit(.coloring):
                "Für heute sind alle Heldenbilder erstellt. Morgen geht es weiter."
            case .dailyLimit(.transcription):
                "Für heute sind alle Sprachideen aufgenommen. Du kannst weiter die Bild-Knöpfe benutzen."
            }
        case let (.usageLimit(error), .english):
            switch error {
            case let .cooldown(_, seconds):
                "Hero break: please wait another \(seconds) seconds."
            case .dailyLimit(.image), .dailyLimit(.coloring):
                "Today's hero pictures are all used. Come back tomorrow."
            case .dailyLimit(.transcription):
                "Today's voice ideas are all used. You can keep using the picture buttons."
            }
        }
    }

}

@MainActor
@Observable
final class HeroLabViewModel {
    private let imageGenerator: any HeroImageGenerating
    private let coloringGenerator: any HeroColoringPageGenerating
    private let transcriber: any HeroDescriptionTranscribing
    private let recorder: any HeroDescriptionRecording
    private let store: GeneratedHeroImageStore
    private let usageBudget: any HeroCloudUsageBudgeting

    var design = HeroDesign()
    var descriptionText = ""
    private(set) var phase: HeroLabPhase = .idle
    private(set) var latestImageData: Data?
    private(set) var coloringImageData: Data?
    private(set) var selectedBackgroundData: Data?
    private(set) var issue: HeroLabIssue?
    private(set) var voiceDescriptionAccepted = false
    private var activeCloudOperationID: UUID?
    private var cancelledCloudOperationID: UUID?
    private var activeSelectionOperationID: UUID?
    private var imageStateRevision: UInt64 = 0
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var generationTaskID: UUID?

    init(
        imageGenerator: any HeroImageGenerating = OpenAIHeroImageGenerationService(),
        coloringGenerator: any HeroColoringPageGenerating = HeroColoringPageService(),
        transcriber: any HeroDescriptionTranscribing = OpenAITranscriptionService(),
        recorder: any HeroDescriptionRecording = HeroDescriptionRecorder(),
        store: GeneratedHeroImageStore = GeneratedHeroImageStore(),
        usageBudget: any HeroCloudUsageBudgeting = PersistentHeroCloudUsageBudget()
    ) {
        self.imageGenerator = imageGenerator
        self.coloringGenerator = coloringGenerator
        self.transcriber = transcriber
        self.recorder = recorder
        self.store = store
        self.usageBudget = usageBudget
    }

    var isRecording: Bool { phase == .recording }
    var isMicrophoneActive: Bool { phase == .recording && recorder.isRecording }
    var microphoneLevel: Double { recorder.audioLevel }
    var recordingSecondsRemaining: Int { max(0, Int(ceil(15 - recorder.elapsedSeconds))) }
    var isBusy: Bool { phase != .idle && phase != .recording }

    func loadSavedImages() async {
        let revision = imageStateRevision
        do {
            let latest = try await store.loadLatest()?.imageData
            let selected = try await store.loadSelectedBackground()?.imageData
            guard revision == imageStateRevision,
                  activeCloudOperationID == nil,
                  activeSelectionOperationID == nil else { return }
            if latestImageData != latest { coloringImageData = nil }
            latestImageData = latest
            selectedBackgroundData = selected
        } catch let error as GeneratedHeroImageStoreError
            where error == .pendingCleanupFailed {
            issue = .localCleanupFailed
        } catch {
            issue = .localSaveFailed
        }
    }

    func clearIssue() {
        issue = nil
    }

    func requireParentSetup() {
        issue = .parentSetupRequired
    }

    func cancelVoiceDescription() {
        guard phase == .recording else { return }
        activeCloudOperationID = nil
        recorder.cancelRecording()
        phase = .idle
    }

    /// Leaving the Hero Lab stops any visible microphone activity, but an
    /// already-paid image request deliberately continues and persists locally.
    func viewDidDisappear() {
        cancelVoiceDescription()
    }

    func cancelCloudWork() {
        imageStateRevision &+= 1
        generationTask?.cancel()
        generationTask = nil
        generationTaskID = nil
        if let activeCloudOperationID {
            cancelledCloudOperationID = activeCloudOperationID
        }
        activeCloudOperationID = nil
        activeSelectionOperationID = nil
        recorder.cancelRecording()
        if phase != .idle {
            phase = .idle
        }
    }

    func stopVoiceDescription() {
        guard phase == .recording else { return }
        recorder.stopRecording()
    }

    @discardableResult
    func startGeneration(apiKey: String?) -> Task<Void, Never> {
        startGeneration(credential: apiKey.map(HeroCredential.parentKey))
    }

    func generate(apiKey: String?) async {
        await generate(credential: apiKey.map(HeroCredential.parentKey))
    }

    func toggleVoiceDescription(apiKey: String?, language: LearningLanguage) async {
        await toggleVoiceDescription(credential: apiKey.map(HeroCredential.parentKey), language: language)
    }

    /// The view model owns generation so changing tabs cannot destroy or
    /// cancel it. App-background, consent, and deletion paths call
    /// `cancelCloudWork()` explicitly and still stop this task.
    @discardableResult
    func startGeneration(credential: HeroCredential?) -> Task<Void, Never> {
        generationTask?.cancel()
        let taskID = UUID()
        generationTaskID = taskID
        let task = Task { @MainActor in
            await self.generate(credential: credential)
            if self.generationTaskID == taskID {
                self.generationTaskID = nil
                self.generationTask = nil
            }
        }
        generationTask = task
        return task
    }

    func toggleVoiceDescription(
        credential: HeroCredential?,
        language: LearningLanguage
    ) async {
        if phase == .recording {
            recorder.stopRecording()
            return
        }
        guard phase == .idle else { return }
        guard let credential, credential.isAvailable else {
            issue = .parentSetupRequired
            return
        }
        let operationID = UUID()
        cancelledCloudOperationID = nil
        activeCloudOperationID = operationID
        issue = nil
        voiceDescriptionAccepted = false
        phase = .recording
        do {
            let recordingURL = try await recorder.recordClip(maxDuration: 15)
            defer { try? HeroDescriptionRecorder.removeTemporaryRecording(at: recordingURL) }
            guard activeCloudOperationID == operationID else { return }
            phase = .transcribing
            do {
                try await usageBudget.authorize(.transcription, at: Date())
            } catch let error as HeroCloudUsageBudgetError {
                finish(operationID: operationID, issue: .usageLimit(error))
                return
            }
            let transcript = try await transcriber.transcribe(
                fileURL: recordingURL,
                language: language,
                credential: credential
            )
            try Task.checkCancellation()
            guard activeCloudOperationID == operationID else { return }
            descriptionText = transcript
            voiceDescriptionAccepted = true
            finish(operationID: operationID)
        } catch is CancellationError {
            finish(operationID: operationID)
        } catch let error as HeroDescriptionRecorderError {
            finish(
                operationID: operationID,
                issue: error == .permissionDenied ? .microphoneDenied : .microphoneFailed
            )
        } catch let error as HeroPromptPolicyError {
            finish(operationID: operationID, issue: .policy(error))
        } catch {
            if !Task.isCancelled {
                finish(operationID: operationID, issue: mapTranscriptionError(error))
            } else {
                finish(operationID: operationID)
            }
        }
    }

    func generate(credential: HeroCredential?) async {
        guard phase == .idle else { return }
        guard let credential, credential.isAvailable else {
            issue = .parentSetupRequired
            return
        }

        let sanitized: String
        do {
            sanitized = try HeroPromptPolicy.sanitize(descriptionText)
        } catch let error as HeroPromptPolicyError {
            issue = .policy(error)
            return
        } catch {
            issue = .localSaveFailed
            return
        }

        do {
            try await usageBudget.authorize(.image, at: Date())
        } catch let error as HeroCloudUsageBudgetError {
            issue = .usageLimit(error)
            return
        } catch {
            issue = .localSaveFailed
            return
        }

        let operationID = UUID()
        imageStateRevision &+= 1
        cancelledCloudOperationID = nil
        activeCloudOperationID = operationID
        descriptionText = sanitized
        issue = nil
        phase = .generating
        do {
            let generated = try await imageGenerator.generate(
                design: design,
                description: sanitized,
                credential: credential
            )
            try Task.checkCancellation()
            guard activeCloudOperationID == operationID else { return }
            phase = .saving
            let previous = try await store.loadLatest()
            try Task.checkCancellation()
            guard activeCloudOperationID == operationID else {
                throw CancellationError()
            }
            let saved = try await store.saveLatest(
                generated.imageData,
                operationID: operationID
            )
            do {
                await Task.yield()
                try Task.checkCancellation()
                guard activeCloudOperationID == operationID else {
                    throw CancellationError()
                }
            } catch {
                let cleanupSucceeded = await restoreLatestAfterInterruptedWrite(
                    previous?.imageData,
                    ifCurrentMatches: saved.imageData,
                    operationID: operationID
                )
                guard cleanupSucceeded else {
                    throw GeneratedHeroImageStoreError.pendingCleanupFailed
                }
                throw error
            }
            let committed: StoredHeroImage
            do {
                committed = try await store.commitLatest(operationID: operationID)
            } catch {
                let cleanupSucceeded = await restoreLatestAfterInterruptedWrite(
                    previous?.imageData,
                    ifCurrentMatches: saved.imageData,
                    operationID: operationID
                )
                guard cleanupSucceeded else {
                    throw GeneratedHeroImageStoreError.pendingCleanupFailed
                }
                throw error
            }
            guard !Task.isCancelled,
                  activeCloudOperationID == operationID else {
                finish(operationID: operationID)
                return
            }
            coloringImageData = nil
            latestImageData = committed.imageData
            imageStateRevision &+= 1
            finish(operationID: operationID)
        } catch is CancellationError {
            if cancelledCloudOperationID == operationID {
                cancelledCloudOperationID = nil
            }
            finish(operationID: operationID)
        } catch let error as GeneratedHeroImageStoreError
            where error == .operationSuperseded {
            // A newer operation owns the staging slot. This operation never
            // reached committed storage, so it must not publish UI state.
            finish(operationID: operationID)
        } catch let error as GeneratedHeroImageStoreError {
            if error == .pendingCleanupFailed,
               cancelledCloudOperationID == operationID {
                cancelledCloudOperationID = nil
                issue = .localCleanupFailed
            } else {
                finish(
                    operationID: operationID,
                    issue: error == .pendingCleanupFailed
                        ? .localCleanupFailed
                        : .localSaveFailed
                )
            }
        } catch let error as HeroOpenAIServiceError {
            finish(operationID: operationID, issue: mapOpenAIError(error))
        } catch {
            if !Task.isCancelled {
                let mappedIssue: HeroLabIssue = phase == .generating
                    ? mapOnlineError(error)
                    : .localSaveFailed
                finish(operationID: operationID, issue: mappedIssue)
            } else {
                finish(operationID: operationID)
            }
        }
    }

    /// The original hero remains the saved image and clock background. The
    /// coloring version is kept locally in memory until replaced or deleted.
    @discardableResult
    func startColoring(credential: HeroCredential?) -> Task<Void, Never> {
        guard phase == .idle else { return Task {} }
        let taskID = UUID()
        generationTaskID = taskID
        let task = Task { @MainActor in
            await self.generateColoring(credential: credential)
            if self.generationTaskID == taskID {
                self.generationTaskID = nil
                self.generationTask = nil
            }
        }
        generationTask = task
        return task
    }

    func generateColoring(credential: HeroCredential?) async {
        guard phase == .idle, let reference = latestImageData else { return }
        guard let credential, credential.isAvailable else {
            issue = .parentSetupRequired
            return
        }
        let operationID = UUID()
        activeCloudOperationID = operationID
        cancelledCloudOperationID = nil
        issue = nil
        phase = .coloring
        do {
            try await usageBudget.authorize(.coloring, at: Date())
            try Task.checkCancellation()
            guard activeCloudOperationID == operationID else { return }
            let image = try await coloringGenerator.generate(referenceImageData: reference, credential: credential)
            try Task.checkCancellation()
            guard activeCloudOperationID == operationID, latestImageData == reference else { return }
            guard GeneratedHeroImageValidator.isValid(image) else { throw HeroOpenAIServiceError.invalidImage }
            coloringImageData = image
            finish(operationID: operationID)
        } catch is CancellationError {
            finish(operationID: operationID)
        } catch let error as HeroCloudUsageBudgetError {
            finish(operationID: operationID, issue: .usageLimit(error))
        } catch {
            finish(operationID: operationID, issue: mapOnlineError(error))
        }
    }

    func selectLatestAsBackground() async -> Data? {
        guard latestImageData != nil else { return nil }
        let operationID = UUID()
        imageStateRevision &+= 1
        activeSelectionOperationID = operationID
        do {
            try Task.checkCancellation()
            let previous = try await store.loadSelectedBackground()
            try Task.checkCancellation()
            guard activeSelectionOperationID == operationID else {
                throw CancellationError()
            }
            let selected = try await store.selectLatestAsBackground(operationID: operationID)
            await Task.yield()
            guard !Task.isCancelled,
                  activeSelectionOperationID == operationID else {
                let cleanupSucceeded = await restoreSelectedBackgroundAfterInterruptedWrite(
                    previous?.imageData,
                    ifCurrentMatches: selected.imageData,
                    operationID: operationID
                )
                if !cleanupSucceeded {
                    issue = .localCleanupFailed
                }
                if activeSelectionOperationID == operationID {
                    activeSelectionOperationID = nil
                }
                return nil
            }
            let committed: StoredHeroImage
            do {
                committed = try await store.commitSelectedBackground(
                    operationID: operationID
                )
            } catch {
                let cleanupSucceeded = await restoreSelectedBackgroundAfterInterruptedWrite(
                    previous?.imageData,
                    ifCurrentMatches: selected.imageData,
                    operationID: operationID
                )
                guard cleanupSucceeded else {
                    throw GeneratedHeroImageStoreError.pendingCleanupFailed
                }
                throw error
            }
            guard !Task.isCancelled,
                  activeSelectionOperationID == operationID else {
                if activeSelectionOperationID == operationID {
                    activeSelectionOperationID = nil
                }
                return nil
            }
            selectedBackgroundData = committed.imageData
            imageStateRevision &+= 1
            activeSelectionOperationID = nil
            return committed.imageData
        } catch is CancellationError {
            if activeSelectionOperationID == operationID {
                activeSelectionOperationID = nil
            }
            return nil
        } catch let error as GeneratedHeroImageStoreError
            where error == .operationSuperseded {
            if activeSelectionOperationID == operationID {
                activeSelectionOperationID = nil
            }
            return nil
        } catch let error as GeneratedHeroImageStoreError {
            if activeSelectionOperationID == operationID {
                activeSelectionOperationID = nil
                issue = error == .pendingCleanupFailed
                    ? .localCleanupFailed
                    : .localSaveFailed
            }
            return nil
        } catch {
            if activeSelectionOperationID == operationID {
                activeSelectionOperationID = nil
                issue = .localSaveFailed
            }
            return nil
        }
    }

    /// Cancellation removes only the operation's protected staging file; the
    /// committed image never needs rewriting. The store retains exact operation
    /// ownership after a transient removal failure, so cleanup gets bounded
    /// retries without risking a newer operation's candidate.
    private func restoreLatestAfterInterruptedWrite(
        _ previousImageData: Data?,
        ifCurrentMatches expectedImageData: Data,
        operationID: UUID
    ) async -> Bool {
        for _ in 0..<2 {
            do {
                try await store.restoreLatest(
                    previousImageData,
                    ifCurrentMatches: expectedImageData,
                    operationID: operationID
                )
                return true
            } catch let error as GeneratedHeroImageStoreError
                where error == .operationSuperseded {
                return true
            } catch {
                // Ownership remains in the store for the next bounded attempt.
            }
        }
        for _ in 0..<2 {
            do {
                try await store.discardLatest(
                    ifCurrentMatches: expectedImageData,
                    operationID: operationID
                )
                return true
            } catch let error as GeneratedHeroImageStoreError
                where error == .operationSuperseded {
                return true
            } catch {
                // A transient removal error gets one final immediate retry.
            }
        }
        return false
    }

    private func restoreSelectedBackgroundAfterInterruptedWrite(
        _ previousImageData: Data?,
        ifCurrentMatches expectedImageData: Data,
        operationID: UUID
    ) async -> Bool {
        for _ in 0..<2 {
            do {
                try await store.restoreSelectedBackground(
                    previousImageData,
                    ifCurrentMatches: expectedImageData,
                    operationID: operationID
                )
                return true
            } catch let error as GeneratedHeroImageStoreError
                where error == .operationSuperseded {
                return true
            } catch {
                // Ownership remains in the store for the next bounded attempt.
            }
        }
        for _ in 0..<2 {
            do {
                try await store.discardSelectedBackground(
                    ifCurrentMatches: expectedImageData,
                    operationID: operationID
                )
                return true
            } catch let error as GeneratedHeroImageStoreError
                where error == .operationSuperseded {
                return true
            } catch {
                // A transient removal error gets one final immediate retry.
            }
        }
        return false
    }

    private func finish(operationID: UUID, issue: HeroLabIssue? = nil) {
        guard activeCloudOperationID == operationID else { return }
        activeCloudOperationID = nil
        phase = .idle
        if let issue {
            self.issue = issue
        }
    }

    private func mapOnlineError(_ error: any Error) -> HeroLabIssue {
        guard let error = error as? HeroOpenAIServiceError else {
            return .onlineFailed(status: nil, requestID: nil)
        }
        return mapOpenAIError(error)
    }

    private func mapTranscriptionError(_ error: any Error) -> HeroLabIssue {
        guard let error = error as? HeroOpenAIServiceError else {
            return .onlineFailed(status: nil, requestID: nil)
        }
        switch error {
        case .malformedResponse, .invalidImage, .responseTooLarge:
            return .invalidTranscript
        case .missingCredential:
            return .parentSetupRequired
        case let .httpStatus(status, requestID):
            return .onlineFailed(status: status, requestID: requestID)
        case .invalidHTTPResponse:
            return .onlineFailed(status: nil, requestID: nil)
        case .contentRejected:
            return .safetyRejected
        case let .serviceLimit(limit):
            return .serviceLimit(limit)
        }
    }

    private func mapOpenAIError(_ error: HeroOpenAIServiceError) -> HeroLabIssue {
        switch error {
        case .missingCredential:
            .parentSetupRequired
        case let .httpStatus(status, requestID):
            .onlineFailed(status: status, requestID: requestID)
        case .contentRejected:
            .safetyRejected
        case .invalidHTTPResponse:
            .onlineFailed(status: nil, requestID: nil)
        case .malformedResponse, .invalidImage:
            .invalidResponse
        case .responseTooLarge:
            .invalidResponse
        case let .serviceLimit(limit):
            .serviceLimit(limit)
        }
    }
}
