import Foundation

/// Turns the raw text of successive decode passes into a draft that stops
/// fidgeting.
///
/// The engines that redecode a whole take every pass keep changing their
/// minds: about a comma, about the newest word, and — given more context —
/// even about the very first word, sentences after it was said. Shown raw,
/// that reads as text dancing on screen. The rules here, in order of force:
///
/// 1. A word that comes out identical in two consecutive passes is
///    **committed**: it joins the settled prefix and never changes on screen
///    again, whatever a later pass thinks of it. Every new pass is anchored
///    by finding the committed text's ending inside it; a pass that cannot
///    even produce our committed words is not displayed at all.
/// 2. Behind the committed prefix, a change of formatting alone — a capital
///    letter, a comma on the same word — keeps the form already on screen
///    until the new form repeats.
/// 3. A worded revision hides everything from the disputed word on, until it
///    stands a second pass; if the dispute refuses to settle for two passes,
///    the newest words show anyway, tentative, because a pinned panel is
///    worse than a moving one.
///
/// This is a *display* discipline, nothing more. The committed prefix is not
/// fed into any transcript: the final text always comes from the engine's
/// own full pass over the complete recording, so the worst this type can do
/// is show a draft that differs from the eventual truth — which a draft, by
/// its nature, may.
struct PreviewStabilizer {
    /// What one pass produced for the screen: the text, and how many of its
    /// leading words are settled for good.
    struct Draft: Equatable {
        var text: String
        var firmWords: Int
    }

    /// The engine's newest words, whatever became of them — including passes
    /// the display ignored. This is what a cancelled dictation preserves:
    /// what was recognised, never what happened to be shown or accepted.
    private(set) var latestHeard = ""

    /// The newest pass the display accepted, for repeat detection, and
    /// whether the pass before the current one was accepted at all: a repeat
    /// only settles words when it repeats a pass that was itself believed.
    private var lastAccepted = ""
    private var lastPassAccepted = false

    /// The screen keeps at most this much settled text. Text scrolled far
    /// past what the panel can show serves nobody, and an unbounded prefix
    /// would grow for the length of a lecture.
    private static let committedCap = 600

    /// Settled text whose anchor words have left the decode window for
    /// good. It still displays, but alignment no longer looks for it:
    /// after a complete window turnover the committed suffix is simply not
    /// in any pass any more, and searching for it pinned the panel forever.
    private var frozenPrefix: [String] = []
    private var committed: [String] = []
    /// The previous accepted pass's words beyond the committed prefix, and
    /// the forms that were actually displayed for them.
    private var previousTail: [String] = []
    private var shownTail: [String] = []
    private var lastBoundary = Int.max
    private var stuck = 0
    /// Consecutive passes that could not be aligned. Three in a row means
    /// the window has turned over completely; the display rebases.
    private var unaligned = 0

    /// Feeds one pass; returns what the screen should show now, or nil when
    /// this pass must not change the screen.
    mutating func ingest(_ raw: String) -> Draft? {
        let words = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        let repeated = raw == latestHeard && lastPassAccepted
        latestHeard = raw

        if repeated {
            // The engine repeated a whole pass, which settles what it said —
            // except the newest two words, which stay in play at the live
            // edge like everywhere else. Committing them here proved costly:
            // a later pass that reformatted them could no longer align.
            let keep = min(2, previousTail.count)
            let settled = previousTail.count - keep
            commit(Array(previousTail[..<settled]))
            previousTail = Array(previousTail[settled...])
            // The repeat put the raw forms on screen, so the display memory
            // follows them: leaving the older shown forms behind let a
            // comma adopted by this very repeat vanish again one pass later.
            shownTail = previousTail
            stuck = 0
            lastBoundary = Int.max
            lastAccepted = raw
            return Draft(
                text: (frozenPrefix + committed + previousTail).joined(separator: " "),
                firmWords: frozenPrefix.count + committed.count
            )
        }

        guard let start = alignedStart(in: words) else {
            lastPassAccepted = false
            unaligned += 1
            if unaligned >= 3 {
                // The window has turned over completely: nothing we
                // committed exists in any pass any more. What is settled
                // freezes as a prefix, and anchoring restarts fresh on the
                // words being said now.
                frozenPrefix.append(contentsOf: committed)
                committed = []
                previousTail = []
                shownTail = []
                stuck = 0
                lastBoundary = Int.max
                unaligned = 0
            }
            return nil
        }
        unaligned = 0
        lastPassAccepted = true
        lastAccepted = raw
        let tail = Array(words[start...])

        // Word stability against the previous tail. No offset search here:
        // the committed anchor has already absorbed the sliding window.
        var exact = 0
        var boundary = 0
        var exactUnbroken = true
        while boundary < min(previousTail.count, tail.count) {
            let held = previousTail[boundary]
            let fresh = tail[boundary]
            if held == fresh {
                if exactUnbroken { exact += 1 }
            } else if Self.folded(held) == Self.folded(fresh) {
                exactUnbroken = false
            } else {
                break
            }
            boundary += 1
        }

        // Two identical passes settle a word for good — except the newest
        // two, which stay in play at the live edge.
        let newlySettled = max(0, min(exact, tail.count - 2))
        if newlySettled > 0 {
            commit(Array(tail[..<newlySettled]))
        }

        // The valve's clock: a dispute that fails to advance past the same
        // boundary twice stops hiding. Reset whenever a pass has no dispute,
        // so the count always means consecutive disputed passes.
        if boundary < previousTail.count {
            if boundary <= lastBoundary { stuck += 1 } else { stuck = 0 }
            lastBoundary = boundary - newlySettled
        } else {
            stuck = 0
            lastBoundary = Int.max
        }

        var visible: [String] = []
        visible.reserveCapacity(tail.count - newlySettled)
        for index in newlySettled..<boundary {
            let fresh = tail[index]
            if previousTail[index] == fresh {
                visible.append(fresh)
            } else if index < shownTail.count {
                // Held against what was DISPLAYED: holding the previous raw
                // form let an alternating engine flap through one pass late.
                visible.append(shownTail[index])
            } else {
                visible.append(previousTail[index])
            }
        }
        if boundary >= previousTail.count || stuck >= 2 {
            visible.append(contentsOf: tail[boundary...])
        }

        // Bookkeeping for the next pass, index-aligned to the new tail and
        // padded with raw forms for anything hidden.
        previousTail = Array(tail[newlySettled...])
        var shown = visible
        if shown.count < previousTail.count {
            shown.append(contentsOf: previousTail[shown.count...])
        }
        shownTail = shown

        let text = (frozenPrefix + committed + visible).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return Draft(text: text, firmWords: frozenPrefix.count + committed.count)
    }

    private mutating func commit(_ words: [String]) {
        committed.append(contentsOf: words)
        var overflow = frozenPrefix.count + committed.count - Self.committedCap
        if overflow > 0 {
            let fromFrozen = min(overflow, frozenPrefix.count)
            frozenPrefix.removeFirst(fromFrozen)
            overflow -= fromFrozen
        }
        if overflow > 0 {
            committed.removeFirst(overflow)
        }
    }

    /// Where the words after the committed prefix begin in this pass, or nil
    /// when the pass does not contain our committed text.
    ///
    /// The anchor is searched for near the smaller of the committed count
    /// and the pass length: however much audio has slid out of the decode
    /// window, the committed text's ending always sits within one pass's
    /// worth of new words of the window's end, so the lifetime count is only
    /// an upper bound — anchoring on it froze marathon takes solid.
    ///
    /// Matching is folded (case and edge punctuation ignored), so a pass
    /// that reformats an already-committed word still aligns; the flip lands
    /// in the probe, scores as a match, and its new form is then ignored
    /// forever. Distant candidates must reproduce the whole probe exactly:
    /// accepting a partial match far from home let a repeated phrase
    /// elsewhere in the text capture the anchor and splice the display.
    private func alignedStart(in words: [String]) -> Int? {
        guard !committed.isEmpty else {
            // Fresh anchoring after a rebase. A glitch that forced the
            // rebase may resolve, bringing the old text back in full — and
            // displaying it after the frozen copy of itself duplicated the
            // take on screen. Any solid overlap between the frozen ending
            // and this pass's beginning is the same speech twice; the pass
            // continues from where the overlap ends.
            guard !frozenPrefix.isEmpty else { return 0 }
            let frozen = frozenPrefix.map(Self.folded)
            let fresh = words.map(Self.folded)
            var overlap = min(frozen.count, fresh.count)
            while overlap >= 3 {
                let tail = Array(frozen.suffix(overlap))
                let head = Array(fresh.prefix(overlap))
                var matches = 0
                for index in 0..<overlap where tail[index] == head[index] {
                    matches += 1
                }
                // One revised word inside the overlap is still the same
                // speech: the revision that forced the rebase is usually
                // sitting right there, and demanding a perfect match let it
                // duplicate the take after all.
                if matches >= overlap - (overlap >= 4 ? 1 : 0) {
                    return overlap
                }
                overlap -= 1
            }
            return 0
        }
        let probe = committed.suffix(6).map(Self.folded)
        let expected = min(committed.count, words.count)
        let nearBudget = 3

        var delta = 0
        var candidates = 0
        while candidates < 96 {
            for j in delta == 0 ? [expected] : [expected - delta, expected + delta] {
                guard j >= 1, j <= words.count else { continue }
                candidates += 1
                let width = min(probe.count, j)
                let sample = words[(j - width)..<j].map(Self.folded)
                let target = Array(probe.suffix(width))
                var score = 0
                for (index, word) in target.enumerated() where sample[index] == word {
                    score += 1
                }
                if delta <= nearBudget {
                    // Close to home a near-miss is trusted: the mismatch is
                    // an engine revising a committed word, not a different
                    // part of the text. A probe of one or two words carries
                    // no slack at all — one shared word must not move the
                    // anchor.
                    if width <= 2 {
                        if score == width { return j }
                    } else if score >= width - 1 {
                        return j
                    }
                } else {
                    // Far from home only the full probe convinces, and a
                    // short probe never does: one shared word must not let
                    // the display teleport.
                    if width == probe.count, probe.count >= 5, score == width { return j }
                }
            }
            delta += 1
            if delta > words.count + probe.count { break }
        }
        return nil
    }

    /// A word reduced to what was spoken: lowercased, with the punctuation
    /// the engines keep re-deciding trimmed from both ends.
    static func folded(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: Self.foldedPunctuation)
    }

    private static let foldedPunctuation = CharacterSet(
        charactersIn: ",.;:!?\u{2026}\u{2019}\u{201D}\u{00BB}\u{0022}"
    )
}
