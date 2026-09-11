import Foundation

/// The curriculum advances from the largest clock units to individual minutes.
public enum TimeLearningLevel: Int, CaseIterable, Codable, Identifiable, Sendable {
    case fullHour
    case halfHour
    case quarterHour
    case fiveMinutes
    case anyMinute

    public var id: Int { rawValue }

    public var next: TimeLearningLevel? {
        TimeLearningLevel(rawValue: rawValue + 1)
    }

    /// Minute values used by questions at this level. Later levels retain earlier skills.
    public var allowedMinutes: [Int] {
        switch self {
        case .fullHour:
            [0]
        case .halfHour:
            [0, 30]
        case .quarterHour:
            [0, 15, 30, 45]
        case .fiveMinutes:
            Array(stride(from: 0, through: 55, by: 5))
        case .anyMinute:
            Array(0...59)
        }
    }

    public func supports(_ time: ClockTime) -> Bool {
        allowedMinutes.contains(time.minute)
    }

    public func title(language: LearningLanguage) -> String {
        switch (self, language) {
        case (.fullHour, .german): "Volle Stunden"
        case (.fullHour, .english): "Full hours"
        case (.halfHour, .german): "Halbe Stunden"
        case (.halfHour, .english): "Half hours"
        case (.quarterHour, .german): "Viertelstunden"
        case (.quarterHour, .english): "Quarter hours"
        case (.fiveMinutes, .german): "Fünf-Minuten-Schritte"
        case (.fiveMinutes, .english): "Five-minute steps"
        case (.anyMinute, .german): "Jede Minute"
        case (.anyMinute, .english): "Every minute"
        }
    }

    public func shortTitle(language: LearningLanguage) -> String {
        switch (self, language) {
        case (.fullHour, .german): "Volle Stunde"
        case (.fullHour, .english): "Full hour"
        case (.halfHour, .german): "Halbe Stunde"
        case (.halfHour, .english): "Half hour"
        case (.quarterHour, .german): "Viertelstunde"
        case (.quarterHour, .english): "Quarter hour"
        case (.fiveMinutes, .german): "5 Minuten"
        case (.fiveMinutes, .english): "5 minutes"
        case (.anyMinute, .german): "Alle Minuten"
        case (.anyMinute, .english): "All minutes"
        }
    }
}
