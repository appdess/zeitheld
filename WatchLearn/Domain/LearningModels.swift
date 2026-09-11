import Foundation

public struct TimeQuestion: Identifiable, Equatable, Sendable {
    public let id: Int
    public let time: ClockTime
    public let level: TimeLearningLevel
    public let choices: [ClockTime]
    public let heroTheme: HeroTheme

    public init(
        id: Int,
        time: ClockTime,
        level: TimeLearningLevel,
        choices: [ClockTime],
        heroTheme: HeroTheme
    ) {
        self.id = id
        self.time = time
        self.level = level
        self.choices = choices
        self.heroTheme = heroTheme
    }

    public func isCorrect(_ answer: ClockTime) -> Bool {
        answer == time
    }
}

public enum LearningHintFocus: Int, CaseIterable, Codable, Sendable {
    case minuteHand
    case hourHand
    case spokenTime
}

public struct LearningHint: Equatable, Sendable {
    public let focus: LearningHintFocus
    public let message: String

    public init(focus: LearningHintFocus, message: String) {
        self.focus = focus
        self.message = message
    }
}

public enum LearningRewardKind: String, Codable, Sendable {
    case starBurst
    case levelBadge
    case clockChampionBadge
}

public struct LearningReward: Equatable, Sendable {
    public let stars: Int
    public let kind: LearningRewardKind

    public init(stars: Int, kind: LearningRewardKind) {
        self.stars = stars
        self.kind = kind
    }
}

public struct AnswerEvaluation: Equatable, Sendable {
    public let isCorrect: Bool
    public let correctAnswer: ClockTime
    public let message: String
    public let explanation: String
    public let hint: LearningHint?
    public let reward: LearningReward?
    public let unlockedLevel: TimeLearningLevel?
    public let completedCurriculum: Bool

    public init(
        isCorrect: Bool,
        correctAnswer: ClockTime,
        message: String,
        explanation: String,
        hint: LearningHint?,
        reward: LearningReward?,
        unlockedLevel: TimeLearningLevel?,
        completedCurriculum: Bool
    ) {
        self.isCorrect = isCorrect
        self.correctAnswer = correctAnswer
        self.message = message
        self.explanation = explanation
        self.hint = hint
        self.reward = reward
        self.unlockedLevel = unlockedLevel
        self.completedCurriculum = completedCurriculum
    }
}

public struct LearningProgress: Equatable, Codable, Sendable {
    private static let maximumSafeStatisticCount = Int.max / 4

    public internal(set) var level: TimeLearningLevel
    public internal(set) var masteryCount: Int
    public internal(set) var totalCorrect: Int
    public internal(set) var totalAttempts: Int
    public internal(set) var totalStars: Int
    public internal(set) var currentStreak: Int
    public internal(set) var longestStreak: Int
    public internal(set) var curriculumCompleted: Bool

    public init(level: TimeLearningLevel = .fullHour) {
        self.level = level
        self.masteryCount = 0
        self.totalCorrect = 0
        self.totalAttempts = 0
        self.totalStars = 0
        self.currentStreak = 0
        self.longestStreak = 0
        self.curriculumCompleted = false
    }

    private enum CodingKeys: String, CodingKey {
        case level
        case masteryCount
        case totalCorrect
        case totalAttempts
        case totalStars
        case currentStreak
        case longestStreak
        case curriculumCompleted
    }

    /// Decoding is deliberately tolerant of older snapshots with missing fields,
    /// while rejecting an unknown curriculum level. Numeric values are normalized
    /// so damaged local preferences cannot restore impossible negative statistics.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        level = try container.decodeIfPresent(TimeLearningLevel.self, forKey: .level) ?? .fullHour
        masteryCount = max(try container.decodeIfPresent(Int.self, forKey: .masteryCount) ?? 0, 0)

        let decodedCorrect = min(
            max(try container.decodeIfPresent(Int.self, forKey: .totalCorrect) ?? 0, 0),
            Self.maximumSafeStatisticCount
        )
        let decodedAttempts = min(
            max(try container.decodeIfPresent(Int.self, forKey: .totalAttempts) ?? 0, 0),
            Self.maximumSafeStatisticCount
        )
        totalCorrect = decodedCorrect
        totalAttempts = max(decodedAttempts, decodedCorrect)

        let maximumEarnedStars = decodedCorrect.multipliedReportingOverflow(by: 3)
        let starLimit = maximumEarnedStars.overflow ? Int.max : maximumEarnedStars.partialValue
        totalStars = min(
            max(try container.decodeIfPresent(Int.self, forKey: .totalStars) ?? 0, 0),
            starLimit
        )

        currentStreak = min(
            max(try container.decodeIfPresent(Int.self, forKey: .currentStreak) ?? 0, 0),
            decodedCorrect
        )
        longestStreak = min(
            max(
                try container.decodeIfPresent(Int.self, forKey: .longestStreak) ?? 0,
                currentStreak
            ),
            decodedCorrect
        )
        curriculumCompleted =
            (try container.decodeIfPresent(Bool.self, forKey: .curriculumCompleted) ?? false)
            && level == .anyMinute
    }

    internal func sanitized(masteryThreshold: Int) -> LearningProgress {
        let threshold = max(masteryThreshold, 1)
        var copy = self

        if copy.curriculumCompleted, copy.level == .anyMinute {
            copy.masteryCount = threshold
        } else {
            copy.curriculumCompleted = false
            copy.masteryCount = min(max(copy.masteryCount, 0), threshold - 1)
        }

        copy.totalCorrect = min(
            max(copy.totalCorrect, 0),
            Self.maximumSafeStatisticCount
        )
        copy.totalAttempts = min(
            max(copy.totalAttempts, copy.totalCorrect),
            Self.maximumSafeStatisticCount
        )
        let maximumEarnedStars = copy.totalCorrect.multipliedReportingOverflow(by: 3)
        let starLimit = maximumEarnedStars.overflow ? Int.max : maximumEarnedStars.partialValue
        copy.totalStars = min(max(copy.totalStars, 0), starLimit)
        copy.currentStreak = min(max(copy.currentStreak, 0), copy.totalCorrect)
        copy.longestStreak = min(
            max(copy.longestStreak, copy.currentStreak),
            copy.totalCorrect
        )
        return copy
    }

    public func masteryFraction(threshold: Int) -> Double {
        guard threshold > 0 else { return 1 }
        return min(Double(masteryCount) / Double(threshold), 1)
    }
}

/// Device-local persistence for aggregate lesson progress. The store intentionally
/// excludes the current question so each production launch can begin with a fresh
/// randomized exercise while retaining earned progress.
public final class LearningProgressStore {
    public static let defaultKey = "watchlearn.learning-progress.v1"

    private let defaults: UserDefaults
    private let key: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        defaults: UserDefaults = .standard,
        key: String = LearningProgressStore.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func load() -> LearningProgress? {
        guard let data = defaults.data(forKey: key) else {
            // Remove values of the wrong UserDefaults type as corrupt snapshots.
            if defaults.object(forKey: key) != nil {
                defaults.removeObject(forKey: key)
            }
            return nil
        }

        do {
            return try decoder.decode(LearningProgress.self, from: data)
        } catch {
            defaults.removeObject(forKey: key)
            return nil
        }
    }

    @discardableResult
    public func save(_ progress: LearningProgress) -> Bool {
        do {
            defaults.set(try encoder.encode(progress), forKey: key)
            return true
        } catch {
            return false
        }
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
