import Foundation

/// Languages that are available throughout the learning experience.
public enum LearningLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case german = "de"
    case english = "en"

    public var id: String { rawValue }

    public var speechLocaleIdentifier: String {
        switch self {
        case .german: "de-DE"
        case .english: "en-US"
        }
    }

    /// A short label that remains understandable when the other language is active.
    public var pickerLabel: String {
        switch self {
        case .german: "Deutsch"
        case .english: "English"
        }
    }
}
