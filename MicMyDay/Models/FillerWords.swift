import Foundation

/// Removes the noises people make while thinking, before anything else touches
/// the transcript.
///
/// Speech engines transcribe what they hear, so "um" and "er" arrive in the
/// text along with the words. Taking them out is a small, exact job: a list of
/// words, matched whole, removed with any comma or full stop they dragged
/// along, and the spacing tidied afterwards.
///
/// Deliberately a plain list rather than a model. It runs offline, costs
/// nothing, takes no time, and does exactly the same thing every time, which
/// means it can be turned off and its behaviour can be predicted from the list
/// alone. A rewrite can do far more, but it needs a provider, a network and a
/// wait, and it cannot be relied on to leave the rest of the sentence alone.
enum FillerWords {
    /// What a fresh install removes.
    ///
    /// The hesitation noises and nothing else. Words that only sometimes mean
    /// nothing, "like", "well", "so", are left out on purpose: deleting them
    /// changes sentences that meant something. Anyone who wants them gone can
    /// add them, and anyone dictating in another language can take out the ones
    /// that collide with real words there.
    static let defaults: [String] = [
        "uh", "uhh", "uhhh",
        "um", "umm", "uhm", "uhmm",
        "er", "err", "erm", "ermm",
        "ah", "ahh", "aah",
        "oh", "ooh", "ohh",
        "hm", "hmm", "hmmm",
        "mm", "mmm", "mhm", "mh",
        "eh", "ehh",
    ]

    /// Removes every listed word from `text`.
    ///
    /// Matching is whole-word and case-insensitive, so "Uh" goes and "uhlan"
    /// stays. A comma or full stop immediately after a filler goes with it,
    /// because "I think, um, yes" should not become "I think, , yes".
    static func strip(_ words: [String], from text: String) -> String {
        let wanted = words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !wanted.isEmpty, !text.isEmpty else { return text }

        var result = text
        for word in wanted {
            let escaped = NSRegularExpression.escapedPattern(for: word)
            // The trailing punctuation is optional and deliberately limited to a
            // comma or a full stop: a filler before a question mark is rare, and
            // swallowing one would change the sentence.
            guard let expression = try? NSRegularExpression(
                pattern: "\\b\(escaped)\\b[,.]?",
                options: [.caseInsensitive]
            ) else { continue }
            result = expression.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        return tidy(result)
    }

    /// Closes the gaps the removals left.
    ///
    /// Taking a word out of the middle of a sentence leaves two spaces, and
    /// taking one out from in front of punctuation leaves a space before it.
    /// Neither is something a person would have typed.
    private static func tidy(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in [
            ("[ \\t]{2,}", " "),        // two spaces where a word used to be
            ("[ \\t]+([,.!?;:])", "$1"), // a space left in front of punctuation
            ("([,.!?;:])\\1+", "$1"),    // ".." where a filler sat between two
            ("\\n[ \\t]+", "\n"),        // a line that now starts with a space
        ] {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            result = expression.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
