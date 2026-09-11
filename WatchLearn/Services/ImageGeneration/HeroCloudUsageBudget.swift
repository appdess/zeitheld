import Foundation

enum HeroCloudOperation: String, Sendable {
    case image
    case transcription
}

enum HeroCloudUsageBudgetError: Error, Equatable, Sendable {
    case dailyLimit(operation: HeroCloudOperation)
    case cooldown(operation: HeroCloudOperation, seconds: Int)
}

protocol HeroCloudUsageBudgeting: Sendable {
    func authorize(_ operation: HeroCloudOperation, at date: Date) async throws
}

/// A deliberately conservative, install-local safety net for the private BYOK
/// build. A production service must additionally enforce authenticated server-
/// side quotas because local state can be reset or the device clock changed.
@MainActor
final class PersistentHeroCloudUsageBudget: HeroCloudUsageBudgeting {
    private enum Limit {
        static let imagesPerDay = 8
        static let transcriptionsPerDay = 24
        static let imageCooldown: TimeInterval = 15
        static let transcriptionCooldown: TimeInterval = 3
    }

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let keyPrefix: String

    init(
        defaults: UserDefaults = .standard,
        calendar: Calendar = .autoupdatingCurrent,
        keyPrefix: String = "hero.cloud-budget"
    ) {
        self.defaults = defaults
        self.calendar = calendar
        self.keyPrefix = keyPrefix
    }

    func authorize(_ operation: HeroCloudOperation, at date: Date = Date()) async throws {
        let day = calendar.startOfDay(for: date).timeIntervalSince1970
        let dayKey = "\(keyPrefix).\(operation.rawValue).day"
        let countKey = "\(keyPrefix).\(operation.rawValue).count"
        let lastKey = "\(keyPrefix).\(operation.rawValue).last"

        var count = defaults.integer(forKey: countKey)
        if defaults.double(forKey: dayKey) != day {
            count = 0
            defaults.set(day, forKey: dayKey)
            defaults.set(0, forKey: countKey)
            defaults.removeObject(forKey: lastKey)
        }

        let dailyLimit = operation == .image
            ? Limit.imagesPerDay
            : Limit.transcriptionsPerDay
        guard count < dailyLimit else {
            throw HeroCloudUsageBudgetError.dailyLimit(operation: operation)
        }

        let cooldown = operation == .image
            ? Limit.imageCooldown
            : Limit.transcriptionCooldown
        let last = defaults.double(forKey: lastKey)
        if last > 0 {
            let elapsed = date.timeIntervalSince1970 - last
            if elapsed >= 0, elapsed < cooldown {
                throw HeroCloudUsageBudgetError.cooldown(
                    operation: operation,
                    seconds: max(1, Int(ceil(cooldown - elapsed)))
                )
            }
            // A backwards clock jump must not silently bypass the cooldown.
            if elapsed < 0 {
                throw HeroCloudUsageBudgetError.cooldown(
                    operation: operation,
                    seconds: Int(cooldown)
                )
            }
        }

        defaults.set(count + 1, forKey: countKey)
        defaults.set(date.timeIntervalSince1970, forKey: lastKey)
    }
}

struct UnlimitedHeroCloudUsageBudget: HeroCloudUsageBudgeting {
    func authorize(_: HeroCloudOperation, at _: Date) async throws {}
}
