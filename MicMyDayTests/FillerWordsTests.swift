import XCTest
@testable import MicMyDay

/// Filler removal is a pure function over text, which makes it exactly the kind
/// of thing that should be pinned down here rather than discovered in a
/// dictation.
final class FillerWordsTests: XCTestCase {
    private let words = FillerWords.defaults

    func testTakesOutHesitationNoises() {
        XCTAssertEqual(
            FillerWords.strip(words, from: "um I think uh we should go"),
            "I think we should go"
        )
    }

    func testTakesThePunctuationTheFillerBroughtWithIt() {
        // "I think, , yes" is what happens without this.
        XCTAssertEqual(
            FillerWords.strip(words, from: "I think, um, yes"),
            "I think, yes"
        )
    }

    func testIgnoresCase() {
        XCTAssertEqual(FillerWords.strip(words, from: "Um, hello. Uh, hello again."), "hello. hello again.")
    }

    func testOnlyMatchesWholeWords() {
        // The obvious way to write this filter eats the start of these.
        for word in ["uhlan", "ahead", "ohio", "ermine", "summer", "maximum"] {
            XCTAssertEqual(
                FillerWords.strip(words, from: "the \(word) stayed"),
                "the \(word) stayed",
                "\"\(word)\" contains a filler but is not one"
            )
        }
    }

    func testLeavesTextAloneWhenThereIsNothingToRemove() {
        let text = "A sentence with nothing to take out."
        XCTAssertEqual(FillerWords.strip(words, from: text), text)
    }

    func testAnEmptyListChangesNothing() {
        let text = "um this should survive uh untouched"
        XCTAssertEqual(FillerWords.strip([], from: text), text)
    }

    func testRemovesOnlyTheWordsGiven() {
        // The list is the whole behaviour: anything not on it stays, however
        // filler-like it looks.
        XCTAssertEqual(
            FillerWords.strip(["um"], from: "um like you know uh whatever"),
            "like you know uh whatever"
        )
    }

    func testTidiesTheGapsItLeaves() {
        XCTAssertEqual(FillerWords.strip(words, from: "one um two   uh three"), "one two three")
        XCTAssertEqual(FillerWords.strip(words, from: "  um  leading and trailing  uh  "), "leading and trailing")
    }

    func testHandlesATranscriptThatIsNothingButFiller() {
        XCTAssertEqual(FillerWords.strip(words, from: "um uh hmm"), "")
    }

    func testWhitespaceAroundAConfiguredWordIsIgnored() {
        XCTAssertEqual(FillerWords.strip(["  um  "], from: "um yes"), "yes")
    }

    func testDefaultsAreLowercasedAndUnique() {
        XCTAssertEqual(FillerWords.defaults, FillerWords.defaults.map { $0.lowercased() })
        XCTAssertEqual(Set(FillerWords.defaults).count, FillerWords.defaults.count)
    }

    /// Words that carry meaning are deliberately absent: deleting them changes
    /// sentences rather than tidying them.
    func testDoesNotShipWithWordsThatMeanSomething() {
        for word in ["like", "well", "so", "right", "okay", "yeah", "I", "a"] {
            XCTAssertFalse(
                FillerWords.defaults.contains(word),
                "\"\(word)\" means something and must not be removed by default"
            )
        }
    }
}
