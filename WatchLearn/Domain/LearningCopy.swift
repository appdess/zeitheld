import Foundation

public enum LearningStringKey: String, CaseIterable, Sendable {
    case appTitle
    case questionPrompt
    case chooseAnswer
    case listenToCoach
    case voiceOfflineTitle
    case voiceOfflineMessage
    case nextQuestion
    case tryAgain
    case correct
    case level
    case easyMode
    case mastery
    case stars
    case streak
    case hint
    case curriculumComplete
    case selectLevel
    case switchLanguage
    case liveClock
    case tapAnswer
}

/// Explicit in-app copy keeps the core experience bilingual even when the device
/// language differs from the language selected by a parent or child.
public enum LearningCopy: Sendable {
    public static func text(_ key: LearningStringKey, language: LearningLanguage) -> String {
        switch (key, language) {
        case (.appTitle, .german): "Uhrenhelden"
        case (.appTitle, .english): "Clock Heroes"
        case (.questionPrompt, .german): "Wie spät ist es?"
        case (.questionPrompt, .english): "What time is it?"
        case (.chooseAnswer, .german): "Wähle die passende Zeit."
        case (.chooseAnswer, .english): "Choose the matching time."
        case (.listenToCoach, .german): "Sprich mit deinem Zeithelden"
        case (.listenToCoach, .english): "Talk to your Time Hero"
        case (.voiceOfflineTitle, .german): "Tippen geht immer"
        case (.voiceOfflineTitle, .english): "Tapping always works"
        case (.voiceOfflineMessage, .german):
            "Dein Zeitheld ist gerade nicht erreichbar. Du kannst trotzdem jede Aufgabe lösen."
        case (.voiceOfflineMessage, .english):
            "Your Time Hero is unavailable right now. You can still solve every question."
        case (.nextQuestion, .german): "Nächste Aufgabe"
        case (.nextQuestion, .english): "Next question"
        case (.tryAgain, .german): "Fast! Versuch es noch einmal."
        case (.tryAgain, .english): "Almost! Try once more."
        case (.correct, .german): "Richtig!"
        case (.correct, .english): "Correct!"
        case (.level, .german): "Stufe"
        case (.level, .english): "Level"
        case (.easyMode, .german): "Leichter Start"
        case (.easyMode, .english): "Easy start"
        case (.mastery, .german): "Fortschritt"
        case (.mastery, .english): "Progress"
        case (.stars, .german): "Sterne"
        case (.stars, .english): "Stars"
        case (.streak, .german): "Serie"
        case (.streak, .english): "Streak"
        case (.hint, .german): "Tipp"
        case (.hint, .english): "Hint"
        case (.curriculumComplete, .german): "Du bist ein Uhrenprofi!"
        case (.curriculumComplete, .english): "You are a clock champion!"
        case (.selectLevel, .german): "Stufe wählen"
        case (.selectLevel, .english): "Choose level"
        case (.switchLanguage, .german): "Sprache wechseln"
        case (.switchLanguage, .english): "Switch language"
        case (.liveClock, .german): "Aktuelle Uhrzeit"
        case (.liveClock, .english): "Current time"
        case (.tapAnswer, .german): "Antwort antippen"
        case (.tapAnswer, .english): "Tap an answer"
        }
    }

    public static func correctFeedback(stars: Int, language: LearningLanguage) -> String {
        switch language {
        case .german:
            "Richtig! Du bekommst \(stars) \(stars == 1 ? "Stern" : "Sterne")."
        case .english:
            "Correct! You earned \(stars) \(stars == 1 ? "star" : "stars")."
        }
    }

    public static func levelUpFeedback(
        unlockedLevel: TimeLearningLevel,
        language: LearningLanguage
    ) -> String {
        switch language {
        case .german:
            "Neue Stufe: \(unlockedLevel.title(language: language))!"
        case .english:
            "New level: \(unlockedLevel.title(language: language))!"
        }
    }

    public static func explanation(for time: ClockTime, language: LearningLanguage) -> String {
        let minuteExplanation: String
        let hourExplanation: String

        switch language {
        case .german:
            minuteExplanation = germanMinuteExplanation(time.minute)
            if time.minute == 0 {
                hourExplanation = "Der kurze Zeiger zeigt genau auf die \(time.hour)."
            } else {
                hourExplanation = "Der kurze Zeiger ist schon auf dem Weg von der \(time.hour) zur \(time.nextHour)."
            }
            return "\(hourExplanation) \(minuteExplanation) Das ist \(time.spokenText(language: language))."
        case .english:
            minuteExplanation = englishMinuteExplanation(time.minute)
            if time.minute == 0 {
                hourExplanation = "The short hand points exactly to \(time.hour)."
            } else {
                hourExplanation = "The short hand is already moving from \(time.hour) toward \(time.nextHour)."
            }
            return "\(hourExplanation) \(minuteExplanation) That makes \(time.spokenText(language: language))."
        }
    }

    public static func hint(
        focus: LearningHintFocus,
        for time: ClockTime,
        language: LearningLanguage
    ) -> String {
        switch (focus, language) {
        case (.minuteHand, .german):
            "Schau zuerst auf den langen Zeiger. \(germanMinuteExplanation(time.minute))"
        case (.minuteHand, .english):
            "Look at the long hand first. \(englishMinuteExplanation(time.minute))"
        case (.hourHand, .german):
            time.minute == 0
                ? "Jetzt der kurze Zeiger: Er zeigt auf die \(time.hour)."
                : "Jetzt der kurze Zeiger: Er steht zwischen \(time.hour) und \(time.nextHour)."
        case (.hourHand, .english):
            time.minute == 0
                ? "Now check the short hand. It points to \(time.hour)."
                : "Now check the short hand. It sits between \(time.hour) and \(time.nextHour)."
        case (.spokenTime, .german):
            "Sprich mit: \(time.spokenText(language: language)). Finde diese Zeit unten."
        case (.spokenTime, .english):
            "Say it with me: \(time.spokenText(language: language)). Find that time below."
        }
    }

    private static func germanMinuteExplanation(_ minute: Int) -> String {
        switch minute {
        case 0: "Der lange Zeiger steht auf der 12. Das bedeutet null Minuten."
        case 15: "Der lange Zeiger steht auf der 3. Das bedeutet 15 Minuten."
        case 30: "Der lange Zeiger steht auf der 6. Das bedeutet 30 Minuten."
        case 45: "Der lange Zeiger steht auf der 9. Das bedeutet 45 Minuten."
        default:
            "Der lange Zeiger zeigt Minute \(minute)."
        }
    }

    private static func englishMinuteExplanation(_ minute: Int) -> String {
        switch minute {
        case 0: "The long hand points to 12. That means zero minutes."
        case 15: "The long hand points to 3. That means 15 minutes."
        case 30: "The long hand points to 6. That means 30 minutes."
        case 45: "The long hand points to 9. That means 45 minutes."
        default:
            "The long hand points to minute \(minute)."
        }
    }
}
