import Foundation

/// A time on a twelve-hour teaching clock.
public struct ClockTime: Hashable, Codable, Sendable {
    public let hour: Int
    public let minute: Int

    /// Creates a clock time and safely wraps values around a twelve-hour clock.
    /// For example, `(hour: 12, minute: 60)` becomes `1:00`.
    public init(hour: Int, minute: Int) {
        let hourIndex = Self.positiveModulo(hour, 12)
        let totalMinutes = hourIndex * 60 + minute
        let wrappedMinutes = Self.positiveModulo(totalMinutes, 12 * 60)
        let normalizedHour = wrappedMinutes / 60

        self.hour = normalizedHour == 0 ? 12 : normalizedHour
        self.minute = wrappedMinutes % 60
    }

    public var nextHour: Int {
        hour == 12 ? 1 : hour + 1
    }

    public var hourHandDegrees: Double {
        Double(hour % 12) * 30 + Double(minute) * 0.5
    }

    public var minuteHandDegrees: Double {
        Double(minute) * 6
    }

    public func digitalText(language: LearningLanguage, includesSuffix: Bool = false) -> String {
        let time = String(format: "%d:%02d", hour, minute)
        if language == .german, includesSuffix {
            return "\(time) Uhr"
        }
        return time
    }

    /// Child-friendly natural speech used by both VoiceOver and the voice coach.
    public func spokenText(language: LearningLanguage) -> String {
        switch language {
        case .german:
            germanSpokenText
        case .english:
            englishSpokenText
        }
    }

    private var germanSpokenText: String {
        switch minute {
        case 0:
            return "\(Self.germanHour(hour, afterPreposition: false)) Uhr"
        case 15:
            return "Viertel nach \(Self.germanHour(hour, afterPreposition: true))"
        case 30:
            return "Halb \(Self.germanHour(nextHour, afterPreposition: true))"
        case 45:
            return "Viertel vor \(Self.germanHour(nextHour, afterPreposition: true))"
        case 1...29:
            return "\(Self.germanNumber(minute)) nach \(Self.germanHour(hour, afterPreposition: true))"
        default:
            return "\(Self.germanNumber(60 - minute)) vor \(Self.germanHour(nextHour, afterPreposition: true))"
        }
    }

    private var englishSpokenText: String {
        switch minute {
        case 0:
            return "\(Self.englishHour(hour)) o'clock"
        case 15:
            return "quarter past \(Self.englishHour(hour))"
        case 30:
            return "half past \(Self.englishHour(hour))"
        case 45:
            return "quarter to \(Self.englishHour(nextHour))"
        case 1...29:
            return "\(Self.englishNumber(minute)) past \(Self.englishHour(hour))"
        default:
            return "\(Self.englishNumber(60 - minute)) to \(Self.englishHour(nextHour))"
        }
    }

    private static func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        let remainder = value % modulus
        return remainder >= 0 ? remainder : remainder + modulus
    }

    private static func germanHour(_ hour: Int, afterPreposition: Bool) -> String {
        if hour == 1 {
            return afterPreposition ? "eins" : "ein"
        }
        return germanNumber(hour)
    }

    private static func englishHour(_ hour: Int) -> String {
        englishNumber(hour)
    }

    private static func germanNumber(_ number: Int) -> String {
        let words = [
            "null", "eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben",
            "acht", "neun", "zehn", "elf", "zwölf", "dreizehn", "vierzehn",
            "fünfzehn", "sechzehn", "siebzehn", "achtzehn", "neunzehn", "zwanzig",
            "einundzwanzig", "zweiundzwanzig", "dreiundzwanzig", "vierundzwanzig",
            "fünfundzwanzig", "sechsundzwanzig", "siebenundzwanzig", "achtundzwanzig",
            "neunundzwanzig", "dreißig"
        ]
        return words[number]
    }

    private static func englishNumber(_ number: Int) -> String {
        let words = [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
            "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
            "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "twenty-one",
            "twenty-two", "twenty-three", "twenty-four", "twenty-five", "twenty-six",
            "twenty-seven", "twenty-eight", "twenty-nine", "thirty"
        ]
        return words[number]
    }
}
