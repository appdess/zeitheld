import Foundation

/// Fast path for a complete, unambiguous time expression. This deliberately has
/// no access to the target clock: an incorrect answer must stay incorrect.
/// Questions, mixed alternatives and unfamiliar phrasing use the normal fallback.
enum SpokenClockAnswerParser {
    /// This only decides whether to request extraction, never whether an answer
    /// is correct. The extractor still rejects questions and unclear alternatives.
    static func mayContainTimeExpression(_ text: String) -> Bool {
        let text = text.lowercased()
        return text.contains("uhr") || text.contains("halb ") || text.contains("half past ")
            || text.contains("o'clock") || text.contains("o’clock")
            || text.range(of: "[0-9]{1,2}:[0-9]{2}", options: .regularExpression) != nil
    }

    /// Automatic grading requires a time expression. A bare number may answer
    /// a teaching question about a clock numeral, so it still needs delegation.
    static func parseExplicitTime(_ text: String, language: RealtimeCoachLanguage) -> ClockAnswerReport? {
        guard let answer = parse(text, language: language) else { return nil }
        let words = text.lowercased()
        guard answer.minute != 0 || words.contains(":") || words.contains("uhr")
            || words.contains("o'clock") || words.contains("o’clock") else { return nil }
        return answer
    }

    static func parse(_ text: String, language: RealtimeCoachLanguage) -> ClockAnswerReport? {
        guard text.utf8.count <= 3000 else { return nil }
        let normalized = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "ü", with: "ue")
            .replacingOccurrences(of: "ö", with: "oe")
            .replacingOccurrences(of: "ä", with: "ae")
        // Only explicit self-corrections can replace an earlier complete answer.
        for separator in [", nein ", ". nein ", ", ich meine ", ", no ", ", i mean "] {
            let parts = normalized.components(separatedBy: separator)
            if parts.count == 2 {
                guard parse(parts[0], language: language) != nil else { return nil }
                return parse(parts[1], language: language)
            }
        }
        var phrase = normalized.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
        let prefixes = ["ich glaube, es ist ", "ich glaube es ist ", "ich denke es ist ",
                        "meine antwort ist ", "es ist ", "ist es ", "ich sage ",
                        "i think it is ", "i think it's ", "my answer is ", "it is ", "it's ", "is it "]
        if let prefix = prefixes.first(where: { phrase.hasPrefix($0) }) { phrase.removeFirst(prefix.count) }
        phrase = phrase.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let german = language != .english
        let words = german
            ? ["null", "eins", "zwei", "drei", "vier", "fuenf", "sechs", "sieben", "acht", "neun", "zehn", "elf", "zwoelf", "dreizehn", "vierzehn", "fuenfzehn", "sechzehn", "siebzehn", "achtzehn", "neunzehn", "zwanzig", "einundzwanzig", "zweiundzwanzig", "dreiundzwanzig", "vierundzwanzig", "fuenfundzwanzig", "sechsundzwanzig", "siebenundzwanzig", "achtundzwanzig", "neunundzwanzig", "dreissig"]
            : ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "twenty-one", "twenty-two", "twenty-three", "twenty-four", "twenty-five", "twenty-six", "twenty-seven", "twenty-eight", "twenty-nine", "thirty"]
        func number(_ value: String) -> Int? {
            if german, ["ein", "eine"].contains(value) { return 1 }
            return words.firstIndex(of: value) ?? Int(value)
        }
        func answer(_ hour: Int?, _ minute: Int) -> ClockAnswerReport? {
            guard let hour, (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            return .init(hour: hour, minute: minute, unknown: false)
        }
        // Digital text is commonly emitted by Live for spoken numeric times.
        let digital = phrase.hasSuffix(" uhr") ? String(phrase.dropLast(4)) : phrase
        let fields = digital.split(separator: ":", omittingEmptySubsequences: false)
        if fields.count == 2, let hour = Int(fields[0]), let minute = Int(fields[1]) {
            return answer(hour, minute)
        }
        if german, phrase.hasPrefix("halb "), let next = number(String(phrase.dropFirst(5))), (1...12).contains(next) {
            return answer(next == 1 ? 12 : next - 1, 30)
        }
        if !german, phrase.hasPrefix("half past ") { return answer(number(String(phrase.dropFirst(10))), 30) }
        let relations = german ? [(" nach ", false), (" vor ", true)] : [(" past ", false), (" to ", true)]
        for (separator, before) in relations {
            let parts = phrase.components(separatedBy: separator)
            guard parts.count == 2 else { continue }
            let amount = parts[0] == (german ? "viertel" : "quarter") ? 15 : number(parts[0])
            guard let amount, (1...30).contains(amount), let hour = number(parts[1]), (1...12).contains(hour) else { return nil }
            return answer(before ? (hour == 1 ? 12 : hour - 1) : hour, before ? 60 - amount : amount)
        }
        let hourSeparator = german ? " uhr" : " o'clock"
        let parts = phrase.components(separatedBy: hourSeparator)
        if parts.count == 2 {
            let remainder = parts[1].trimmingCharacters(in: .whitespaces)
            guard let minute = remainder.isEmpty ? 0 : number(remainder) else { return nil }
            return answer(number(parts[0]), minute)
        }
        let tokens = phrase.split(separator: " ").map(String.init)
        if tokens.count == 2, let minute = number(tokens[1]) { return answer(number(tokens[0]), minute) }
        // A lone hour is a valid clock attempt only in this delegation path.
        return answer(number(phrase), 0)
    }
}

/// Both automatic parsing and delegated work claim the same transient text.
/// Claiming consumes it before asynchronous work, preventing duplicate grading.
struct LiveClockTranscriptBuffer {
    private(set) var text = ""
    private(set) var changedAt: TimeInterval = -.infinity
    private var lastInputEndMS: Double?
    private var coachReply: (start: Double, end: Double)?

    mutating func observeCoachTranscript(startMS: Double?, endMS: Double?) {
        guard let startMS, let endMS, startMS.isFinite, endMS.isFinite, endMS >= startMS else { return }
        if endMS > (coachReply?.end ?? -.infinity) { coachReply = (startMS, endMS) }
    }

    mutating func append(_ fragment: String, at time: TimeInterval, startMS: Double? = nil, endMS: Double? = nil) {
        // A new reply after the coach's response is not a continuation of the
        // earlier request for help. Only discard recognizable help requests:
        // duplex coach speech may fall between fragments of the SAME time.
        let previous = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let helpRequest = ["kannst du", "hilf mir", "erklär", "erklaer", "ich verstehe", "was bedeutet", "wie lese",
                           "can you", "help me", "please explain", "i don't understand", "what does", "how do i read"]
            .contains { previous.hasPrefix($0) }
        if helpRequest, let startMS, let lastInputEndMS, let coachReply,
           startMS >= coachReply.end, lastInputEndMS <= coachReply.start {
            text = ""
        }
        if let endMS, endMS.isFinite { lastInputEndMS = max(lastInputEndMS ?? 0, endMS) }
        text = String((text + fragment).suffix(3000)); changedAt = time
    }
    var settlingSeconds: TimeInterval {
        // A punctuated complete time can be delivered promptly. Unfinished
        // fragments retain the longer window for minutes and self-corrections.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.last.map { ".!?".contains($0) } == true && !trimmed.hasSuffix("...") ? 0.4 : 1
    }
    func isSettled(at time: TimeInterval) -> Bool { time - changedAt >= settlingSeconds }
    func localAnswer(language: RealtimeCoachLanguage, at time: TimeInterval) -> ClockAnswerReport? {
        guard isSettled(at: time) else { return nil }
        return SpokenClockAnswerParser.parseExplicitTime(text, language: language)
    }
    mutating func take() -> String { let value = text; text = ""; return value }
    mutating func reset() { text = ""; changedAt = -.infinity; lastInputEndMS = nil; coachReply = nil }
}
