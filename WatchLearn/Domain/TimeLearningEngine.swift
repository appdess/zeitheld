import Foundation

/// A pure, seeded lesson engine. No network, audio, or wall-clock state enters the
/// grading path, which makes outcomes reproducible and safe to use offline.
public struct TimeLearningEngine: Sendable {
    public private(set) var language: LearningLanguage
    public private(set) var progress: LearningProgress
    public private(set) var currentQuestion: TimeQuestion
    public private(set) var attemptsForCurrentQuestion: Int
    public private(set) var isAwaitingNextQuestion: Bool
    public let masteryThreshold: Int

    private var generator: SeededGenerator
    private var nextQuestionID: Int

    public init(
        language: LearningLanguage = .german,
        startingLevel: TimeLearningLevel = .fullHour,
        restoredProgress: LearningProgress? = nil,
        seed: UInt64 = 0xC10C_A11E,
        masteryThreshold: Int = 4
    ) {
        let safeThreshold = max(masteryThreshold, 1)
        var seededGenerator = SeededGenerator(seed: seed)
        let initialProgress = (restoredProgress ?? LearningProgress(level: startingLevel))
            .sanitized(masteryThreshold: safeThreshold)

        self.language = language
        self.progress = initialProgress
        self.currentQuestion = Self.generateQuestion(
            id: 0,
            level: initialProgress.level,
            generator: &seededGenerator
        )
        self.attemptsForCurrentQuestion = 0
        self.isAwaitingNextQuestion = false
        self.masteryThreshold = safeThreshold
        self.generator = seededGenerator
        self.nextQuestionID = 1
    }

    /// Grades a choice once. After a correct answer, call `moveToNextQuestion()`.
    /// Returning `nil` prevents accidental double rewards while success UI is visible.
    @discardableResult
    public mutating func submit(answer: ClockTime) -> AnswerEvaluation? {
        guard !isAwaitingNextQuestion else { return nil }

        progress.totalAttempts += 1

        guard currentQuestion.isCorrect(answer) else {
            attemptsForCurrentQuestion += 1
            progress.currentStreak = 0
            let focus = Self.hintFocus(forAttempt: attemptsForCurrentQuestion)
            return AnswerEvaluation(
                isCorrect: false,
                correctAnswer: currentQuestion.time,
                message: LearningCopy.text(.tryAgain, language: language),
                explanation: "",
                hint: LearningHint(
                    focus: focus,
                    message: LearningCopy.hint(
                        focus: focus,
                        for: currentQuestion.time,
                        language: language
                    )
                ),
                reward: nil,
                unlockedLevel: nil,
                completedCurriculum: false
            )
        }

        let stars = Self.stars(afterIncorrectAttempts: attemptsForCurrentQuestion)
        progress.totalCorrect += 1
        progress.totalStars += stars
        progress.currentStreak += 1
        progress.longestStreak = max(progress.longestStreak, progress.currentStreak)
        progress.masteryCount += 1

        var unlockedLevel: TimeLearningLevel?
        var completedNow = false
        var rewardKind: LearningRewardKind = .starBurst

        if progress.masteryCount >= masteryThreshold {
            if let nextLevel = progress.level.next {
                progress.level = nextLevel
                progress.masteryCount = 0
                unlockedLevel = nextLevel
                rewardKind = .levelBadge
            } else if !progress.curriculumCompleted {
                progress.masteryCount = masteryThreshold
                progress.curriculumCompleted = true
                completedNow = true
                rewardKind = .clockChampionBadge
            }
        }

        isAwaitingNextQuestion = true

        let message: String
        if completedNow {
            message = LearningCopy.text(.curriculumComplete, language: language)
        } else if let unlockedLevel {
            message = LearningCopy.levelUpFeedback(
                unlockedLevel: unlockedLevel,
                language: language
            )
        } else {
            message = LearningCopy.correctFeedback(stars: stars, language: language)
        }

        return AnswerEvaluation(
            isCorrect: true,
            correctAnswer: currentQuestion.time,
            message: message,
            explanation: LearningCopy.explanation(for: currentQuestion.time, language: language),
            hint: nil,
            reward: LearningReward(stars: stars, kind: rewardKind),
            unlockedLevel: unlockedLevel,
            completedCurriculum: completedNow
        )
    }

    /// Advances only after success so a child cannot accidentally skip a question.
    @discardableResult
    public mutating func moveToNextQuestion() -> Bool {
        guard isAwaitingNextQuestion else { return false }

        currentQuestion = Self.generateQuestion(
            id: nextQuestionID,
            level: progress.level,
            generator: &generator
        )
        nextQuestionID += 1
        attemptsForCurrentQuestion = 0
        isAwaitingNextQuestion = false
        return true
    }

    public mutating func setLanguage(_ language: LearningLanguage) {
        self.language = language
    }

    /// Parent-facing level selection starts a clean mastery run without erasing
    /// already collected stars and aggregate practice statistics.
    public mutating func start(level: TimeLearningLevel) {
        progress.level = level
        progress.masteryCount = 0
        progress.currentStreak = 0
        progress.curriculumCompleted = false
        attemptsForCurrentQuestion = 0
        isAwaitingNextQuestion = false
        currentQuestion = Self.generateQuestion(
            id: nextQuestionID,
            level: level,
            generator: &generator
        )
        nextQuestionID += 1
    }

    private static func hintFocus(forAttempt attempt: Int) -> LearningHintFocus {
        switch attempt {
        case 1: .hourHand
        case 2: .minuteHand
        default: .spokenTime
        }
    }

    private static func stars(afterIncorrectAttempts attempts: Int) -> Int {
        switch attempts {
        case 0: 3
        case 1: 2
        default: 1
        }
    }

    private static func generateQuestion(
        id: Int,
        level: TimeLearningLevel,
        generator: inout SeededGenerator
    ) -> TimeQuestion {
        // This stage must actually teach :30 before admitting quarter hours.
        // Using [0, 30] here could complete the whole stage with only full hours.
        let minutes = level == .halfHour ? [30] : level.allowedMinutes
        let hour = Int.random(in: 1...12, using: &generator)
        let minute = minutes[Int.random(in: minutes.indices, using: &generator)]
        let answer = ClockTime(hour: hour, minute: minute)
        let choices = makeChoices(answer: answer, level: level, generator: &generator)
        let themes = HeroTheme.allCases
        let hero = themes[Int.random(in: themes.indices, using: &generator)]

        return TimeQuestion(
            id: id,
            time: answer,
            level: level,
            choices: choices,
            heroTheme: hero
        )
    }

    private static func makeChoices(
        answer: ClockTime,
        level: TimeLearningLevel,
        generator: inout SeededGenerator
    ) -> [ClockTime] {
        let allowedMinutes = level.allowedMinutes
        let minuteIndex = allowedMinutes.firstIndex(of: answer.minute) ?? 0
        var distractors: [ClockTime] = []

        func appendUnique(_ candidate: ClockTime) {
            guard candidate != answer, !distractors.contains(candidate) else { return }
            distractors.append(candidate)
        }

        // Adjacent hours are the most useful distractors when learning the short hand.
        appendUnique(ClockTime(hour: answer.hour + 1, minute: answer.minute))
        appendUnique(ClockTime(hour: answer.hour - 1, minute: answer.minute))

        // Nearby allowed minutes exercise the long hand without introducing content
        // beyond the selected level.
        if allowedMinutes.count > 1 {
            let nextMinute = allowedMinutes[(minuteIndex + 1) % allowedMinutes.count]
            let previousMinute = allowedMinutes[
                (minuteIndex - 1 + allowedMinutes.count) % allowedMinutes.count
            ]
            appendUnique(ClockTime(hour: answer.hour, minute: nextMinute))
            appendUnique(ClockTime(hour: answer.hour, minute: previousMinute))
        }

        Self.shuffle(&distractors, using: &generator)
        var choices = [answer] + Array(distractors.prefix(2))
        Self.shuffle(&choices, using: &generator)
        return choices
    }

    private static func shuffle<T>(_ values: inout [T], using generator: inout SeededGenerator) {
        guard values.count > 1 else { return }
        for index in stride(from: values.count - 1, through: 1, by: -1) {
            let otherIndex = Int.random(in: 0...index, using: &generator)
            if index != otherIndex {
                values.swapAt(index, otherIndex)
            }
        }
    }
}

private struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
