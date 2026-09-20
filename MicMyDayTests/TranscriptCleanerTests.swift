import XCTest
@testable import MicMyDay

final class TranscriptCleanerTests: XCTestCase {
    func testAWordLoopCollapsesToTwo() {
        XCTAssertEqual(
            TranscriptCleaner.collapsingRepetitionLoops("so the the the the the the the meeting"),
            "so the the meeting"
        )
    }

    func testDictatedNumbersAreNeverCollapsed() {
        // With numbers the count is the content: a PIN, a phone number, a
        // repeated digit string must come through exactly as spoken.
        let pin = "five five five five one two three"
        XCTAssertEqual(TranscriptCleaner.collapsingRepetitionLoops(pin), pin)
        let digits = "5 5 5 5 5 5 5 5 1 2"
        XCTAssertEqual(TranscriptCleaner.collapsingRepetitionLoops(digits), digits)
    }

    func testACountingCadenceSurvives() {
        let cadence = "one two one two one two"
        XCTAssertEqual(TranscriptCleaner.collapsingRepetitionLoops(cadence), cadence)
    }

    func testFiveRepeatsOfAWordSurvive() {
        // Below the loop threshold: emphasis and stutters stay verbatim.
        let five = "no no no no no way"
        XCTAssertEqual(TranscriptCleaner.collapsingRepetitionLoops(five), five)
    }

    func testLegitimateDoublesAndEmphasisSurvive() {
        let doubled = "the work that that had had done was very very good"
        XCTAssertEqual(TranscriptCleaner.collapsingRepetitionLoops(doubled), doubled)
        let emphasis = "it was very very very very very important"
        XCTAssertEqual(TranscriptCleaner.collapsingRepetitionLoops(emphasis), emphasis)
    }

    func testAPhraseLoopCollapsesToOne() {
        XCTAssertEqual(
            TranscriptCleaner.collapsingRepetitionLoops(
                "Thank you. Thank you. Thank you. Thank you."
            ),
            "Thank you."
        )
    }

    func testALongPhraseLoopCollapses() {
        let phrase = "please write down the notes"
        let looped = Array(repeating: phrase, count: 5).joined(separator: " ")
        XCTAssertEqual(TranscriptCleaner.collapsingRepetitionLoops(looped), phrase)
    }

    func testTwoPhraseRepeatsSurvive() {
        // Saying something twice is speech; three times is a loop.
        let twice = "check the door check the door and leave"
        XCTAssertEqual(TranscriptCleaner.collapsingRepetitionLoops(twice), twice)
    }

    func testASentenceWithALoopInTheMiddleKeepsItsEnds() {
        XCTAssertEqual(
            TranscriptCleaner.collapsingRepetitionLoops(
                "start here and and and and and and and now finish there"
            ),
            "start here and and now finish there"
        )
    }

    func testOrdinaryTextPassesUntouched() {
        let text = "Refactor the auth module to use the new session store, and add tests."
        XCTAssertEqual(TranscriptCleaner.collapsingRepetitionLoops(text), text)
    }

    func testShortAndEmptyInputsPassThrough() {
        XCTAssertEqual(TranscriptCleaner.collapsingRepetitionLoops(""), "")
        XCTAssertEqual(TranscriptCleaner.collapsingRepetitionLoops("yes yes"), "yes yes")
    }

    func testACollapseThatLeavesAFreshLoopGetsSweptAgain() {
        // Collapsing the length-3 loop leaves four "a b" pairs in a row —
        // itself a loop, which a single pass would have walked past.
        let text = "a b a b a b a a b a a b a b"
        let cleaned = TranscriptCleaner.collapsingRepetitionLoops(text)
        let words = cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
        for length in [1, 2, 3] {
            var index = 0
            while index + length * 4 <= words.count {
                let phrase = Array(words[index..<(index + length)])
                let next = Array(words[(index + length)..<(index + 2 * length)])
                let third = Array(words[(index + 2 * length)..<(index + 3 * length)])
                let fourth = Array(words[(index + 3 * length)..<(index + 4 * length)])
                XCTAssertFalse(
                    phrase == next && next == third && third == fourth,
                    "a four-fold loop survived: \(cleaned)"
                )
                index += 1
            }
        }
    }

    func testALongDigitStringCleansQuickly() {
        let digits = Array(repeating: "5", count: 4_000).joined(separator: " ")
        let began = ContinuousClock.now
        let cleaned = TranscriptCleaner.collapsingRepetitionLoops(digits)
        let elapsed = began.duration(to: .now)
        XCTAssertEqual(cleaned, digits)
        XCTAssertLessThan(elapsed, .milliseconds(500), "digit flood took \(elapsed)")
    }

    func testDeepNestedLoopsSweepToStability() {
        // A construction that needed five sweeps to settle; a capped sweep
        // count left a full qualifying loop standing.
        let text = "b a b a b a a b a a b b a a b a b a a b a a b a b a a b a a b a b b a a b a b a"
        let cleaned = TranscriptCleaner.collapsingRepetitionLoops(text)
        XCTAssertEqual(TranscriptCleaner.collapsingRepetitionLoops(cleaned), cleaned,
                       "the result was not a fixpoint: \(cleaned)")
    }

    func testCaseAndPunctuationDifferencesAreNotLoops() {
        let text = "No. no, no said no one"
        XCTAssertEqual(TranscriptCleaner.collapsingRepetitionLoops(text), text)
    }
}
