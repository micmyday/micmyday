import Foundation

/// Collapses the repetition loops local speech models fall into.
///
/// Given awkward audio, Whisper-family models sometimes lock onto a token
/// and repeat it — a single word dozens of times, or a whole phrase over
/// and over. No person dictates like that, and one loop in a pasted
/// transcript is worse than a hundred small errors, because it reads as
/// the app breaking rather than the model mishearing.
///
/// The thresholds are deliberately conservative so real speech survives:
/// a word must appear six times in a row before anything is touched, and
/// even then two copies stay — doubled words are legitimate ("had had"),
/// so is emphasis ("very very"), and so is a dictated PIN ("five five
/// five five"), which is why four was too eager. Digit tokens are never
/// collapsed at all: with numbers, the count IS the content. A two-word
/// phrase must repeat four times (counting cadences like "one two one
/// two one two" are speech), longer phrases three — real speakers pause
/// or vary; looping models do not.
///
/// Applied only to the local engines' output. The hosted providers and
/// Apple's recogniser do not have this failure mode, and the fewer hands
/// on their text the better.
enum TranscriptCleaner {
    /// The longest phrase checked for looping, in words. Loops longer than
    /// this exist but are vanishingly rare, and every extra length is
    /// another scan of the text.
    private static let longestPhrase = 8

    static func collapsingRepetitionLoops(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 3 else { return text }
        // Note the flattening below: the local engines this runs on emit
        // space-joined segments, so nothing is lost today — but if an
        // engine ever starts emitting line breaks, this is the place that
        // would erase them, and the join must get smarter.

        // Swept to a fixpoint: collapsing a long loop can leave a fresh
        // shorter loop behind ("ABAB ABA ABA ABA B" contracts into four
        // ABs), and a single ascending pass would walk right past it.
        // Until unchanged, not a fixed number of sweeps — a capped count
        // proved reachable by pathological input, leaving a whole loop
        // standing. Every changing sweep deletes words, so this terminates.
        var cleaned = words
        while true {
            let before = cleaned.count
            cleaned = collapseWordRuns(cleaned)
            for length in 2...longestPhrase where cleaned.count >= length * 3 {
                cleaned = collapsePhraseRuns(cleaned, length: length)
            }
            if cleaned.count == before { break }
        }
        return cleaned.count == words.count ? text : cleaned.joined(separator: " ")
    }

    /// Runs of one identical word: six or more in a row keep two. Digits
    /// are exempt entirely; a spoken number's repetitions are its value.
    private static func collapseWordRuns(_ words: [String]) -> [String] {
        guard !words.isEmpty else { return words }
        var result: [String] = []
        result.reserveCapacity(words.count)
        var runStart = 0
        var index = 0
        while index <= words.count {
            if index == words.count || words[index] != words[runStart] {
                let run = index - runStart
                let numeric = words[runStart].allSatisfy(\.isNumber)
                let kept = (run >= 6 && !numeric) ? 2 : run
                result.append(contentsOf: repeatElement(words[runStart], count: kept))
                runStart = index
            }
            index += 1
        }
        return result
    }

    /// Runs of an identical multi-word phrase keep one copy: two-word
    /// phrases must repeat four times, longer ones three.
    private static func collapsePhraseRuns(_ words: [String], length: Int) -> [String] {
        let requiredRepeats = length == 2 ? 4 : 3
        var result: [String] = []
        result.reserveCapacity(words.count)
        var index = 0
        while index < words.count {
            guard index + length <= words.count else {
                result.append(words[index])
                index += 1
                continue
            }
            let phrase = Array(words[index..<(index + length)])
            // The digit exemption again: "5 5" repeated is a number being
            // read out, and the word pass's protection would be undone
            // here. Checked before counting repeats — checking after made a
            // long digit string rescan its own tail from every position,
            // which turned linear work quadratic.
            if phrase.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
                result.append(words[index])
                index += 1
                continue
            }
            var repeats = 1
            while index + (repeats + 1) * length <= words.count,
                  Array(words[(index + repeats * length)..<(index + (repeats + 1) * length)]) == phrase {
                repeats += 1
            }
            if repeats >= requiredRepeats {
                result.append(contentsOf: phrase)
                index += repeats * length
            } else {
                result.append(words[index])
                index += 1
            }
        }
        return result
    }
}
