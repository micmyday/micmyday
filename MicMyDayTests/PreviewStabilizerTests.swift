import XCTest
@testable import MicMyDay

/// The preview must stop fidgeting: these pin the display rules against the
/// exact misbehaviours seen in real dictation — a first word flapping five
/// sentences later, commas blinking in and out, and passes that restructure
/// wholesale.
final class PreviewStabilizerTests: XCTestCase {
    private func drafts(_ passes: [String]) -> [String] {
        var stabilizer = PreviewStabilizer()
        var shown: [String] = []
        var current = ""
        for pass in passes {
            if let draft = stabilizer.ingest(pass) {
                current = draft.text
            }
            shown.append(current)
        }
        return shown
    }

    func testACommittedWordNeverChangesOnScreenAgain() {
        // "they" agrees twice, is committed, and a later pass flipping it to
        // "May" changes nothing on screen.
        let shown = drafts([
            "they went to the market",
            "they went to the market and bought",
            "they went to the market and bought bread today",
            "May went to the market and bought bread today now",
        ])
        XCTAssertTrue(shown[2].hasPrefix("they went to the market"))
        XCTAssertTrue(shown[3].hasPrefix("they went to the market"), "a committed word moved: \(shown[3])")
        XCTAssertFalse(shown[3].contains("May"))
    }

    func testAnAlternatingCommaNeverRenders() {
        let shown = drafts([
            "hello world how are",
            "hello, world how are you",
            "hello world how are you today",
            "hello, world how are you today then",
        ])
        // The comma never made it to the screen: the first form shown is the
        // form held throughout.
        for text in shown.dropFirst() {
            XCTAssertTrue(text.hasPrefix("hello world") || text.hasPrefix("hello wor"),
                          "the comma flapped through: \(text)")
        }
    }

    func testAPersistentFormattingChangeIsAdopted() {
        let shown = drafts([
            "hello world how are",
            "hello, world how are you",
            "hello, world how are you today",
            "hello, world how are you today then",
        ])
        // Two passes agreeing on the comma adopt and then commit it.
        XCTAssertTrue(shown.last!.hasPrefix("hello, world"))
    }

    func testAWordedRevisionHidesUntilItStands() {
        let shown = drafts([
            "the quick brown fox jumps",
            "the quick brown box jumps over",
        ])
        // "box" is a worded revision of "fox": everything from it on hides,
        // and only the still-agreed head displays.
        XCTAssertEqual(shown[1], "the quick brown")
    }

    func testARepeatedPassSettlesAllButTheLiveEdge() {
        var stabilizer = PreviewStabilizer()
        _ = stabilizer.ingest("one two three four")
        let second = stabilizer.ingest("one two three four")
        XCTAssertEqual(second?.text, "one two three four")
        // The newest two words stay in play even after a repeat, so a later
        // pass that reformats them can still align.
        XCTAssertEqual(second?.firmWords, 2)
    }

    func testAPassWithoutTheCommittedTextIsIgnored() {
        var stabilizer = PreviewStabilizer()
        _ = stabilizer.ingest("alpha beta gamma delta epsilon")
        _ = stabilizer.ingest("alpha beta gamma delta epsilon zeta eta")
        let committedDraft = stabilizer.ingest("alpha beta gamma delta epsilon zeta eta theta")
        XCTAssertNotNil(committedDraft)
        // A wholesale different pass cannot find the committed words and must
        // not touch the screen.
        XCTAssertNil(stabilizer.ingest("completely different words entirely here now"))
    }

    func testASlidWindowStillAligns() {
        var stabilizer = PreviewStabilizer()
        _ = stabilizer.ingest("one two three four five six seven eight")
        _ = stabilizer.ingest("one two three four five six seven eight nine")
        // The window slid: the head words fell out of the raw text, but the
        // committed suffix still anchors the alignment.
        let draft = stabilizer.ingest("three four five six seven eight nine ten eleven")
        XCTAssertNotNil(draft)
        XCTAssertTrue(draft!.text.hasPrefix("one two three"), "committed head lost: \(draft!.text)")
        XCTAssertTrue(draft!.text.contains("ten"))
    }

    func testAMarathonSlideNeverFreezesTheDisplay() {
        // Simulates the decode window sliding: the pass text keeps losing
        // words from the front while new ones arrive at the back. Anchoring
        // on the lifetime committed count instead of the window froze this
        // solid a couple of minutes into any long take.
        var stabilizer = PreviewStabilizer()
        let vocabulary = (0..<400).map { "word\($0)" }
        var updates = 0
        for end in stride(from: 8, to: 400, by: 2) {
            let start = max(0, end - 40)
            let pass = vocabulary[start..<end].joined(separator: " ")
            if stabilizer.ingest(pass) != nil { updates += 1 }
        }
        // The display must keep updating all the way to the end, not stall
        // once the slide exceeds the anchor search's reach.
        XCTAssertGreaterThan(updates, 150, "the marathon take froze")
    }

    func testARepeatedPhraseCannotSpliceTheDisplay() {
        var stabilizer = PreviewStabilizer()
        _ = stabilizer.ingest("a b c d a b c d")
        _ = stabilizer.ingest("a b c d a b c d e")
        _ = stabilizer.ingest("a b c d a b c d e f")
        // The engine flips two committed words; the identical four-gram at
        // the head of the text must not capture the anchor and duplicate
        // half the sentence.
        _ = stabilizer.ingest("a b c d a b x y e f g")
        let draft = stabilizer.ingest("a b c d a b x y e f g h")
        if let draft {
            let words = draft.text.split(whereSeparator: \.isWhitespace).map(String.init)
            XCTAssertLessThanOrEqual(words.count, 12, "the display spliced: \(draft.text)")
        }
    }

    func testARepeatSparesTheLiveEdge() {
        var stabilizer = PreviewStabilizer()
        _ = stabilizer.ingest("one two three four")
        _ = stabilizer.ingest("one two three four")
        // The repeat settles everything except the newest two words, so a
        // pass that later reformats those can still align and display.
        let next = stabilizer.ingest("one two THREE FOUR five six")
        XCTAssertNotNil(next)
        XCTAssertTrue(next!.text.contains("five") || next!.text.hasPrefix("one two"))
        let after = stabilizer.ingest("one two THREE FOUR five six seven")
        XCTAssertNotNil(after)
        XCTAssertTrue(after!.text.contains("five"), "the panel froze after a repeat: \(after!.text)")
    }

    func testAGarbagePassThenAnOldRepeatSettlesNothing() {
        var stabilizer = PreviewStabilizer()
        _ = stabilizer.ingest("alpha beta gamma delta epsilon zeta")
        _ = stabilizer.ingest("alpha beta gamma delta epsilon zeta eta")
        // A wholesale-different pass is ignored...
        XCTAssertNil(stabilizer.ingest("completely unrelated text right here now"))
        // ...and repeating the OLD text afterwards is not two consecutive
        // identical passes: it must go through alignment, not the repeat
        // fast path that settles everything.
        let draft = stabilizer.ingest("alpha beta gamma delta epsilon zeta eta")
        if let draft {
            XCTAssertLessThan(draft.firmWords,
                              draft.text.split(whereSeparator: \.isWhitespace).count,
                              "a non-consecutive repeat settled the live edge")
        }
    }

    func testCancellationKeepsTheNewestHeardWords() {
        var stabilizer = PreviewStabilizer()
        _ = stabilizer.ingest("alpha beta gamma delta epsilon zeta")
        _ = stabilizer.ingest("completely unrelated text right here now")
        // Even an ignored pass is what the engine last heard, and a
        // cancellation must preserve it.
        XCTAssertEqual(stabilizer.latestHeard, "completely unrelated text right here now")
    }

    func testShortProbesNeverSplice() {
        var stabilizer = PreviewStabilizer()
        _ = stabilizer.ingest("a b c d")
        _ = stabilizer.ingest("a b c d")
        _ = stabilizer.ingest("a a b c d e")
        let draft = stabilizer.ingest("a a b c d e")
        if let draft {
            XCTAssertFalse(draft.text.contains("b b"), "spliced: \(draft.text)")
        }
    }

    func testCompleteWindowTurnoverRebasesInsteadOfPinning() {
        var stabilizer = PreviewStabilizer()
        _ = stabilizer.ingest("one two three four five six")
        _ = stabilizer.ingest("one two three four five six seven")
        // The window turned over entirely: nothing committed appears in the
        // passes any more. After a few ignored passes the display must
        // rebase and follow the new words rather than stay pinned forever.
        var lastDraft: PreviewStabilizer.Draft?
        for pass in [
            "fresh words after the turnover here",
            "fresh words after the turnover here now",
            "fresh words after the turnover here now then",
            "fresh words after the turnover here now then too",
            "fresh words after the turnover here now then too yes",
        ] {
            if let draft = stabilizer.ingest(pass) { lastDraft = draft }
        }
        XCTAssertNotNil(lastDraft, "the panel stayed pinned after a full turnover")
        XCTAssertTrue(lastDraft!.text.contains("fresh"), "rebase lost the new words: \(lastDraft!.text)")
        XCTAssertTrue(lastDraft!.text.hasPrefix("one two three four"), "the settled prefix was lost: \(lastDraft!.text)")
    }

    func testACommaAdoptedByARepeatStaysAdopted() {
        var stabilizer = PreviewStabilizer()
        _ = stabilizer.ingest("hello world")
        _ = stabilizer.ingest("hello, world")
        _ = stabilizer.ingest("hello, world")
        // The repeat put the comma on screen; a later reformat of another
        // word must not resurrect the comma-free form.
        let draft = stabilizer.ingest("HELLO world today")
        if let draft {
            XCTAssertFalse(draft.text.hasPrefix("hello world"),
                           "the adopted comma vanished again: \(draft.text)")
        }
    }

    func testAGlitchRecoveryDoesNotDuplicateTheText() {
        var stabilizer = PreviewStabilizer()
        _ = stabilizer.ingest("they went to the market for bread")
        _ = stabilizer.ingest("they went to the market for bread")
        // Three garbage passes force a rebase...
        for _ in 0..<3 {
            _ = stabilizer.ingest("garbled nonsense entirely unrelated words here")
        }
        // ...and then the engine recovers — including the very revision that
        // caused the glitch. The frozen copy and the recovered copy are the
        // same speech and must appear once, revision notwithstanding.
        _ = stabilizer.ingest("May went to the market for bread and cheese")
        let draft = stabilizer.ingest("May went to the market for bread and cheese")
        XCTAssertNotNil(draft)
        let text = draft!.text
        XCTAssertEqual(
            text, "they went to the market for bread and cheese",
            "the recovery duplicated or lost text"
        )
    }

    func testFirmCountNeverExceedsDisplayedWords() {
        var stabilizer = PreviewStabilizer()
        for pass in [
            "a b c d e", "a b c d e f", "a x c d e f g", "a b c q e f g h",
        ] {
            guard let draft = stabilizer.ingest(pass) else { continue }
            let count = draft.text.split(whereSeparator: \.isWhitespace).count
            XCTAssertLessThanOrEqual(draft.firmWords, count)
        }
    }
}
