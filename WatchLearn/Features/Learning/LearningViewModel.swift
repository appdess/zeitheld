import Foundation
import Observation

@MainActor
@Observable
public final class LearningViewModel {
    public static let deterministicSeed: UInt64 = 0xC10C_A11E

    public private(set) var engine: TimeLearningEngine
    public private(set) var evaluation: AnswerEvaluation?
    public private(set) var selectedAnswer: ClockTime?
    private var spokenAutoAdvanceQuestionID: Int?
    private let progressStore: LearningProgressStore?
    public let journeys: ChildJourneyStore?

    public init(
        language: LearningLanguage = .german,
        startingLevel: TimeLearningLevel = .fullHour,
        seed: UInt64 = LearningViewModel.deterministicSeed,
        masteryThreshold: Int = 4,
        progressStore: LearningProgressStore? = nil,
        journeys: ChildJourneyStore? = nil
    ) {
        self.progressStore = progressStore
        self.journeys = journeys
        self.engine = TimeLearningEngine(
            language: language,
            startingLevel: startingLevel,
            restoredProgress: journeys?.selected.progress ?? progressStore?.load(),
            seed: seed,
            masteryThreshold: masteryThreshold
        )
        persistProgress()
    }

    public var language: LearningLanguage { engine.language }
    public var question: TimeQuestion { engine.currentQuestion }
    public var progress: LearningProgress { engine.progress }
    public var masteryThreshold: Int { engine.masteryThreshold }
    public var canContinue: Bool { evaluation?.isCorrect == true }

    public func choose(_ answer: ClockTime) {
        submit(answer, armsSpokenAutoAdvance: false)
    }

    public func chooseSpoken(_ answer: ClockTime) {
        submit(answer, armsSpokenAutoAdvance: true)
    }

    private func submit(
        _ answer: ClockTime,
        armsSpokenAutoAdvance: Bool
    ) {
        guard !engine.isAwaitingNextQuestion else { return }

        var updatedEngine = engine
        guard let result = updatedEngine.submit(answer: answer) else { return }
        engine = updatedEngine
        selectedAnswer = answer
        evaluation = result
        journeys?.save(progress: engine.progress, attempt: JourneyAttempt(
            id: UUID(), date: Date(), level: engine.currentQuestion.level,
            target: engine.currentQuestion.time, answer: answer, correct: result.isCorrect
        ), masteredLevel: result.unlockedLevel != nil || result.completedCurriculum ? engine.currentQuestion.level : nil)
        spokenAutoAdvanceQuestionID = armsSpokenAutoAdvance && result.isCorrect
            ? updatedEngine.currentQuestion.id
            : nil
        persistProgress()
    }

    public func continueAfterSpokenFeedback(questionID: Int) {
        guard spokenAutoAdvanceQuestionID == questionID,
              engine.currentQuestion.id == questionID,
              evaluation?.isCorrect == true else { return }
        continueLesson()
    }

    public func cancelSpokenAutoAdvance() {
        spokenAutoAdvanceQuestionID = nil
    }

    public func continueLesson() {
        var updatedEngine = engine
        guard updatedEngine.moveToNextQuestion() else { return }
        engine = updatedEngine
        selectedAnswer = nil
        evaluation = nil
        spokenAutoAdvanceQuestionID = nil
        persistProgress()
    }

    public func setLanguage(_ language: LearningLanguage) {
        guard language != engine.language else { return }
        var updatedEngine = engine
        updatedEngine.setLanguage(language)
        engine = updatedEngine
        evaluation = evaluation.map { Self.relocalized($0, language: language) }
    }

    public func start(level: TimeLearningLevel) {
        var updatedEngine = engine
        updatedEngine.start(level: level)
        engine = updatedEngine
        selectedAnswer = nil
        evaluation = nil
        spokenAutoAdvanceQuestionID = nil
        persistProgress()
    }

    private func persistProgress() {
        if let journeys { journeys.save(progress: engine.progress) }
        else { _ = progressStore?.save(engine.progress) }
    }

    public func selectChild(_ id: UUID) {
        guard let journeys, journeys.children.contains(where: { $0.id == id }) else { return }
        journeys.select(id)
        restoreSelectedChild()
    }

    public func addChild(name: String) {
        guard journeys?.add(name: name) != nil else { return }
        restoreSelectedChild()
    }

    public func resetJourney() {
        journeys?.resetSelected()
        restoreSelectedChild()
    }

    private func restoreSelectedChild() {
        engine = TimeLearningEngine(language: language,
            restoredProgress: journeys?.selected.progress,
            seed: UInt64.random(in: UInt64.min...UInt64.max), masteryThreshold: masteryThreshold)
        evaluation = nil; selectedAnswer = nil; spokenAutoAdvanceQuestionID = nil
        persistProgress()
    }

    private static func relocalized(
        _ evaluation: AnswerEvaluation,
        language: LearningLanguage
    ) -> AnswerEvaluation {
        let message: String
        if evaluation.completedCurriculum {
            message = LearningCopy.text(.curriculumComplete, language: language)
        } else if let unlockedLevel = evaluation.unlockedLevel {
            message = LearningCopy.levelUpFeedback(
                unlockedLevel: unlockedLevel,
                language: language
            )
        } else if let reward = evaluation.reward {
            message = LearningCopy.correctFeedback(stars: reward.stars, language: language)
        } else {
            message = LearningCopy.text(.tryAgain, language: language)
        }

        let hint = evaluation.hint.map {
            LearningHint(
                focus: $0.focus,
                message: LearningCopy.hint(
                    focus: $0.focus,
                    for: evaluation.correctAnswer,
                    language: language
                )
            )
        }

        return AnswerEvaluation(
            isCorrect: evaluation.isCorrect,
            correctAnswer: evaluation.correctAnswer,
            message: message,
            explanation: evaluation.isCorrect
                ? LearningCopy.explanation(for: evaluation.correctAnswer, language: language)
                : "",
            hint: hint,
            reward: evaluation.reward,
            unlockedLevel: evaluation.unlockedLevel,
            completedCurriculum: evaluation.completedCurriculum
        )
    }
}
