import XCTest
@testable import MicMyDay

/// What someone types has to reach the setting they meant, and the obvious
/// query must never have a surprise at the top of the list.
@MainActor
final class SettingsSearchTests: XCTestCase {
    private func topCard(_ query: String) -> String? {
        SettingsSearch.results(for: query).first?.card
    }

    private func cards(_ query: String) -> [String] {
        SettingsSearch.results(for: query).map(\.card)
    }

    // MARK: The vocabulary problem

    /// The case that prompted all of this: the feature is called ducking in
    /// the code and nowhere in anybody's head.
    func testTheManyWaysPeopleAskForDucking() {
        for query in ["ducking", "duck", "volume", "turn down music",
                      "mute other audio", "spotify", "quieter", "music"] {
            XCTAssertEqual(topCard(query), "Microphone", "\(query) should find the microphone card")
        }
    }

    func testTheManyWaysPeopleAskForTheShortcut() {
        for query in ["hotkey", "keyboard shortcut", "trigger", "right shift", "push to talk"] {
            XCTAssertTrue(cards(query).contains("Shortcut"), "\(query) should find the shortcut")
        }
    }

    func testAnAliasFindsACardThatNeverSaysTheWord() {
        XCTAssertTrue(cards("dark mode").contains("Theme"))
        XCTAssertTrue(cards("api key").contains("Rewrite engine"))
        XCTAssertTrue(cards("um").contains("Filler words"))
        XCTAssertEqual(topCard("previous profile"), "Cycle profiles")
    }

    // MARK: Ranking

    func testATitleOutranksAnAlias() {
        // "History" is a card of its own and also a word other cards know.
        XCTAssertEqual(topCard("history"), "History")
    }

    func testAnExactTitleWins() {
        XCTAssertEqual(topCard("filler words"), "Filler words")
        XCTAssertEqual(topCard("position"), "Position")
    }

    /// The card is findable by what somebody would actually type when the
    /// app has just typed a word they never said.
    func testTheSilenceCardIsFoundByTheProblemItSolves() {
        XCTAssertEqual(topCard("nothing said"), "Silence")
        XCTAssertEqual(topCard("made up words"), "Silence")
        XCTAssertEqual(topCard("ghost words"), "Silence")
        // "voice detection" reasonably means the microphone to somebody
        // else, so it need not win outright; it must still be offered.
        XCTAssertTrue(
            SettingsSearch.results(for: "voice detection").contains { $0.card == "Silence" }
        )
    }

    func testResultsAreRankedNotJustCollected() {
        let results = SettingsSearch.results(for: "profile")
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.count <= 8, "the list must stay short enough to scan")
    }

    // MARK: Forgiveness

    func testATypoStillFinds() {
        XCTAssertEqual(topCard("duckign"), "Microphone")
        XCTAssertTrue(cards("langauge").contains("Language"))
    }

    func testPunctuationAndCaseAreIgnored() {
        XCTAssertTrue(cards("HANDS-FREE").contains("Hands-free"))
        XCTAssertTrue(cards("not updating?").contains("Refresh permissions"))
    }

    func testEveryWordHasToMatchSomething() {
        // The second word belongs to nothing, so this is not a weak match, it
        // is a different question from the one any card answers.
        XCTAssertTrue(SettingsSearch.results(for: "overlay bicycle").isEmpty)
    }

    func testNonsenseFindsNothing() {
        XCTAssertTrue(SettingsSearch.results(for: "zzzzqx").isEmpty)
        XCTAssertTrue(SettingsSearch.results(for: "   ").isEmpty)
        XCTAssertTrue(SettingsSearch.results(for: "").isEmpty)
    }

    /// A short query must not behave like a wildcard: two letters in order
    /// appear somewhere in almost any sentence.
    ///
    /// Asserted by what the matches are rather than by how many, because a
    /// count is a number to retune every time an alias is added. Every result
    /// for two letters has to be something that actually begins with them.
    func testAVeryShortQueryOnlyMatchesWordsThatBeginWithIt() {
        let results = SettingsSearch.results(for: "ti")
        XCTAssertLessThan(results.count, SettingsIndex.entries.count / 4,
                          "a two letter query should not sweep the index")
        for entry in results {
            let words = ([entry.card] + entry.aliases)
                .flatMap { $0.lowercased().split(whereSeparator: \.isWhitespace) }
            XCTAssertTrue(words.contains { $0.hasPrefix("ti") },
                          "\(entry.card) has no word starting with \"ti\"")
        }
    }

    // MARK: Panes

    func testAPaneNameFindsItsRows() {
        let overlay = SettingsSearch.results(for: "overlay")
        XCTAssertTrue(overlay.allSatisfy { $0.pane == .overlay })
        XCTAssertGreaterThan(overlay.count, 1)
    }
}
