import Foundation

/// Decides when a hands-free speaker has finished their turn, from the live
/// transcript. A pause after a finished sentence sends; a pause after "um",
/// "and", "but", a comma, or a fragment waits much longer, because that's
/// someone thinking, not someone done. Pure logic, so it's unit-tested; the
/// listener feeds it transcripts and measures the silence.
public struct TurnDetector: Sendable, Equatable {
    public enum Ending: Sendable, Equatable {
        /// Ended with "send it" or similar: send right away (the phrase is removed).
        case sendNow
        /// A complete sentence: send after the normal pause.
        case finished
        /// No punctuation yet: a little longer than finished.
        case uncertain
        /// Trailing filler, conjunction, comma, or fragment: wait much longer.
        case unfinished
        /// "Wait", "hold on", "let me think": hold the turn open.
        case holding
    }

    /// Silence after a finished sentence before sending. The user's setting.
    public var pause: TimeInterval
    /// Extra silence allowed after an unfinished thought.
    public var hesitationExtra: TimeInterval = 3
    /// Extra silence allowed after "wait" / "hold on".
    public var holdExtra: TimeInterval = 6
    /// How long before sending the warning cue plays; speaking during it keeps the turn.
    public var warningLead: TimeInterval = 1.0
    public static let defaultPause: TimeInterval = 3.0

    public init(pause: TimeInterval = TurnDetector.defaultPause) {
        self.pause = pause
    }

    public func ending(of transcript: String) -> Ending {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .uncertain }
        let words = Self.words(text)
        if Self.matchesTail(words, Self.sendPhrases) { return .sendNow }
        if Self.matchesTail(words, Self.holdPhrases) { return .holding }

        if let last = text.last, ",;:-–—…".contains(last) || text.hasSuffix("...") { return .unfinished }
        if let word = words.last, Self.continuers.contains(word) { return .unfinished }
        if words.count >= 2, Self.continuerPairs.contains("\(words[words.count - 2]) \(words[words.count - 1])") {
            return .unfinished
        }
        let terminal = text.last.map { ".?!".contains($0) } ?? false
        // "Okay." is a whole turn, but "So I was" without punctuation is a fragment.
        if words.count < 3 && !terminal { return .unfinished }
        return terminal ? .finished : .uncertain
    }

    /// Seconds of silence that end the turn, given what's been said so far.
    public func requiredSilence(for transcript: String) -> TimeInterval {
        switch ending(of: transcript) {
        case .sendNow: 0.6
        case .finished: pause
        case .uncertain: pause + 1.5
        case .unfinished: pause + hesitationExtra
        case .holding: pause + holdExtra
        }
    }

    /// When to play the "about to send" cue, or nil if the wait is too short to warn.
    public func warningAt(for transcript: String) -> TimeInterval? {
        let required = requiredSilence(for: transcript)
        return required > warningLead + 0.5 ? required - warningLead : nil
    }

    public enum Decision: Sendable, Equatable {
        case listen
        /// Play the "about to send" cue; speaking again keeps the turn.
        case warn
        case send
    }

    /// Sound without new words keeps the turn open at most this long past the
    /// last word, so road noise or music can't hold it forever.
    public var soundHold: TimeInterval = 6

    /// The call the listener makes ten times a second.
    /// - Parameters:
    ///   - sinceText: seconds since the transcript last changed.
    ///   - sinceSound: seconds since the mic last heard voice-level sound, if ever.
    public func decide(_ transcript: String, sinceText: TimeInterval, sinceSound: TimeInterval?) -> Decision {
        var silence = sinceText
        if let sinceSound {
            // An audible "ummm" counts as still talking, up to `soundHold` past the last word.
            silence = min(silence, max(sinceSound, sinceText - soundHold))
        }
        if silence >= requiredSilence(for: transcript) { return .send }
        if let warning = warningAt(for: transcript), silence >= warning { return .warn }
        return .listen
    }

    /// The transcript without a trailing "send it" (and its punctuation).
    public static func removingSendPhrase(_ transcript: String) -> String {
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = words(text)
        guard let phrase = sendPhrases.first(where: { tailMatches(words, $0) }) else { return text }
        // Drop as many trailing words as the phrase has, keeping the original casing.
        var remaining = phrase.count
        while remaining > 0, !text.isEmpty {
            while let last = text.last, !last.isLetter && !last.isNumber && last != "'" { text.removeLast() }
            while let last = text.last, last.isLetter || last.isNumber || last == "'" { text.removeLast() }
            remaining -= 1
        }
        while let last = text.last, last == " " || last == "," || last == "-" { text.removeLast() }
        return text
    }

    // MARK: Vocabulary

    /// Words a speaker trails off on mid-thought.
    static let continuers: Set<String> = [
        // fillers
        "um", "umm", "uh", "uhh", "er", "erm", "ah", "eh", "hmm", "hm", "mm", "like", "basically", "actually",
        // conjunctions
        "and", "but", "or", "so", "because", "cause", "cuz", "since", "although", "though", "while", "whereas",
        "if", "unless", "when", "whenever", "where", "then", "also", "plus", "nor", "yet", "than", "that", "which", "who",
        // prepositions and articles
        "the", "a", "an", "to", "of", "for", "with", "without", "in", "on", "at", "by", "from", "into", "onto",
        "about", "as", "over", "under", "after", "before", "between", "through", "my", "your", "our", "their", "his", "her", "its", "this", "these", "those",
        // auxiliaries and pronouns that need a continuation
        "i", "i'm", "i've", "i'd", "i'll", "we", "we're", "you", "you're", "it's", "is", "are", "was", "were",
        "be", "been", "have", "has", "had", "do", "does", "did", "can", "could", "should", "would", "will", "might", "must",
        "gonna", "wanna", "gotta", "let's", "maybe", "just", "really", "very", "some", "any",
    ]

    static let continuerPairs: Set<String> = [
        "you know", "i mean", "kind of", "sort of", "and then", "so then", "as well", "such as",
    ]

    static let sendPhrases: [[String]] = [["send", "it"], ["send", "that"], ["send", "now"], ["over", "and", "out"]]
    static let holdPhrases: [[String]] = [
        ["wait"], ["hold", "on"], ["hang", "on"], ["one", "sec"], ["one", "second"], ["let", "me", "think"], ["give", "me", "a", "second"],
    ]

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }

    private static func matchesTail(_ words: [String], _ phrases: [[String]]) -> Bool {
        phrases.contains { tailMatches(words, $0) }
    }

    private static func tailMatches(_ words: [String], _ phrase: [String]) -> Bool {
        words.count >= phrase.count && Array(words.suffix(phrase.count)) == phrase
    }
}
