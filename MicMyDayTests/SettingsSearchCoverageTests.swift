import XCTest
@testable import MicMyDay

/// The index is written by hand, so the thing that can go wrong is drift: a
/// card renamed, added, or moved to another pane, with the search quietly no
/// longer finding it or scrolling to nothing. These read the pane sources and
/// fail when the two disagree.
///
/// Destinations are compared as pane and anchor together. Comparing bare
/// titles let an entry name the wrong pane and still pass, which is exactly
/// the drift that breaks navigation while looking healthy.
@MainActor
final class SettingsSearchCoverageTests: XCTestCase {
    private struct Destination: Hashable {
        let pane: SettingsPane
        let anchor: String
    }

    /// The debug-only switchboard, deliberately unindexed.
    private static let unindexedPanes: Set<SettingsPane> = [.states]

    private static let paneForType: [String: SettingsPane] = [
        "GeneralPane": .general,
        "VoicePane": .voice,
        "EnginePane": .engine,
        "RewritePane": .rewrite,
        "OutputPane": .output,
        "OverlayPane": .overlay,
        "UsagePane": .usage,
        "PermissionsPane": .permissions,
        "LicencePane": .licence,
        "StatesPane": .states,
        // Cards that live in a helper view rather than directly in a pane.
        // Attributing by "the nearest type above" would otherwise put them
        // outside every pane, which is how the Updates card was found to be
        // missing from the index in the first place.
        "UpdatesCard": .general,
    ]

    private var settingsViews: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MicMyDayTests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("MicMyDay/Views/Settings")
    }

    /// One card as the source declares it.
    struct ParsedCard: Equatable {
        let pane: SettingsPane?
        /// nil when the card can be addressed by nothing at all.
        let anchor: String?
    }

    /// Reads `SettingsCard(...)` calls out of Swift source.
    ///
    /// The arguments are delimited properly rather than by a fixed window of
    /// characters. A window let a card with a computed heading borrow the
    /// anchor of whichever card came next in the file, which made an
    /// unaddressable card look addressable: precisely the failure these
    /// tests exist to catch.
    static func parseCards(_ source: String) -> [ParsedCard] {
        let characters = Array(source)
        var cards: [ParsedCard] = []
        var paneStarts: [(index: Int, pane: SettingsPane?)] = []

        // Where each view type begins, so a card can be attributed to one.
        for match in source.ranges(of: "struct ") {
            let after = source[match.upperBound...]
            guard let colon = after.firstIndex(of: ":") else { continue }
            let name = after[..<colon].trimmingCharacters(in: .whitespaces)
            guard after[colon...].dropFirst().trimmingCharacters(in: .whitespaces).hasPrefix("View") else { continue }
            paneStarts.append((source.distance(from: source.startIndex, to: match.lowerBound),
                               paneForType[name]))
        }

        for match in source.ranges(of: "SettingsCard(") {
            let open = source.distance(from: source.startIndex, to: match.upperBound) - 1
            let segments = argumentSegments(characters, openParenthesis: open)
            let pane = paneStarts.last { $0.index < open }?.pane
            cards.append(ParsedCard(pane: pane, anchor: anchorName(in: segments)))
        }
        return cards
    }

    /// The call's own arguments, split at top-level commas, with nesting and
    /// string literals respected and the trailing closure excluded.
    private static func argumentSegments(_ characters: [Character], openParenthesis: Int) -> [String] {
        var segments: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        var escaped = false
        var index = openParenthesis
        func endSegment() {
            segments.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
            current = ""
        }
        while index < characters.count {
            let character = characters[index]
            index += 1
            if inString {
                current.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"":
                inString = true
                current.append(character)
            case "(", "[":
                depth += 1
                if depth > 1 { current.append(character) }
            case ")", "]":
                depth -= 1
                if depth == 0 { endSegment(); return segments }
                current.append(character)
            case "{":
                // The content closure: the arguments are over.
                if depth <= 1 { endSegment(); return segments }
                current.append(character)
            case ",":
                if depth == 1 { endSegment() } else { current.append(character) }
            default:
                current.append(character)
            }
        }
        endSegment()
        return segments
    }

    /// The string a literal argument holds, or nil when the argument is
    /// anything else.
    ///
    /// The whole argument has to be one constant literal. Accepting anything
    /// merely *starting* with a quote let `"Profiles" + suffix` pass as the
    /// constant "Profiles", and accepting interpolation would let
    /// `"Profiles \(suffix)"` pass as a destination that never exists at
    /// runtime. Escapes are decoded, so the value compared here is the string
    /// the app will really carry rather than its source spelling.
    private static func literalValue(_ argument: String) -> String? {
        var characters = Array(argument)
        guard characters.first == "\"" else { return nil }
        characters.removeFirst()
        var value = ""
        var escaped = false
        var closed = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            index += 1
            if escaped {
                escaped = false
                switch character {
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "\"", "\\": value.append(character)
                case "u":
                    // \u{XXXX}: decode it, because the app will hold the
                    // character and the index has to match that, not the
                    // source's spelling of it.
                    guard index < characters.count, characters[index] == "{",
                          let close = characters[index...].firstIndex(of: "}")
                    else { return nil }
                    let digits = String(characters[(index + 1)..<close])
                    guard let code = UInt32(digits, radix: 16),
                          let scalar = Unicode.Scalar(code) else { return nil }
                    value.append(Character(scalar))
                    index = close + 1
                default:
                    // An escape this does not understand would give a value
                    // that differs from the app's; refuse rather than guess.
                    return nil
                }
                continue
            }
            // Interpolation is not a constant, whatever it starts with.
            if character == "\\", index < characters.count, characters[index] == "(" { return nil }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { closed = true; break }
            value.append(character)
        }
        guard closed else { return nil }
        // Nothing may follow it, or the argument is an expression rather than
        // a constant.
        let rest = characters[index...].map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard rest.isEmpty else { return nil }
        return value
    }

    /// An explicit anchor if there is one, otherwise a literal heading.
    private static func anchorName(in segments: [String]) -> String? {
        for segment in segments where segment.hasPrefix("anchor:") {
            let value = segment.dropFirst("anchor:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            return literalValue(value)
        }
        guard let first = segments.first else { return nil }
        let heading = first.hasPrefix("eyebrow:")
            ? first.dropFirst("eyebrow:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            : first
        return literalValue(heading)
    }

    /// Every `SettingsCard(…)` across the settings views.
    private func declaredDestinations() throws -> (found: [Destination], unaddressable: [String]) {
        let files = try FileManager.default.contentsOfDirectory(
            at: settingsViews, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "no settings sources found at \(settingsViews.path)")

        var found: [Destination] = []
        var unaddressable: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for card in Self.parseCards(source) {
                guard let anchor = card.anchor else {
                    unaddressable.append("\(file.lastPathComponent): a card with no literal heading and no anchor:")
                    continue
                }
                guard let pane = card.pane else {
                    unaddressable.append("\(file.lastPathComponent): \(anchor) is not inside a known pane type")
                    continue
                }
                found.append(Destination(pane: pane, anchor: anchor))
            }
        }
        return (found, unaddressable)
    }

    /// Every card must be addressable at all. A computed heading with no
    /// anchor cannot be navigated to, and would slip past every check below.
    func testEveryCardCanBeAddressed() throws {
        let (_, unaddressable) = try declaredDestinations()
        XCTAssertTrue(unaddressable.isEmpty,
                      "cards search cannot target: \(unaddressable.joined(separator: "; "))")
    }

    /// Nothing may ship unsearchable.
    func testEveryCardIsInTheIndex() throws {
        let indexed = Set(SettingsIndex.entries.map { Destination(pane: $0.pane, anchor: $0.anchor) })
        let (declared, _) = try declaredDestinations()
        let missing = declared
            .filter { !Self.unindexedPanes.contains($0.pane) && !indexed.contains($0) }
            .map { "\($0.anchor) in \($0.pane.title)" }
        XCTAssertTrue(Set(missing).isEmpty,
                      "settings with no search entry: \(Set(missing).sorted().joined(separator: ", "))")
    }

    /// And the reverse, including the pane: an entry naming the right card in
    /// the wrong pane navigates somewhere the card is not.
    func testEveryEntryPointsAtARealCardInThatPane() throws {
        let (declared, _) = try declaredDestinations()
        let real = Set(declared)
        let dangling = SettingsIndex.entries
            .filter { !real.contains(Destination(pane: $0.pane, anchor: $0.anchor)) }
            .map { "\($0.anchor) claimed in \($0.pane.title)" }
        XCTAssertTrue(dangling.isEmpty, "entries with no card: \(dangling.joined(separator: ", "))")
    }

    /// The parser has to actually be finding things. Without this, a regex
    /// that matched nothing would make every test above pass.
    func testTheSourceParserFindsTheCards() throws {
        let (declared, _) = try declaredDestinations()
        XCTAssertGreaterThan(declared.count, 35, "the source parser found suspiciously few cards")
        XCTAssertTrue(declared.contains(Destination(pane: .voice, anchor: "Recording")))
        XCTAssertTrue(declared.contains(Destination(pane: .engine, anchor: "Engine account")),
                      "the engine's computed-heading card should be found by its anchor")
    }

    /// The parser's own regression: a card whose heading is computed must not
    /// be able to borrow the anchor of the card declared after it.
    func testAComputedHeadingCannotBorrowTheNextCardsAnchor() {
        let source = """
        struct EnginePane: View {
            var body: some View {
                SettingsCard(eyebrow: computedHeading) {
                    Text("something")
                }
                SettingsCard(eyebrow: "Language", anchor: "Language") {
                    Text("something else")
                }
            }
        }
        """
        let cards = Self.parseCards(source)
        XCTAssertEqual(cards.count, 2)
        XCTAssertNil(cards[0].anchor, "a computed heading with no anchor is unaddressable, not borrowed")
        XCTAssertEqual(cards[0].pane, .engine)
        XCTAssertEqual(cards[1].anchor, "Language")
    }

    func testTheParserReadsBothFormsAndPrefersTheAnchor() {
        let source = """
        struct OverlayPane: View {
            var body: some View {
                SettingsCard("Size") { Text("a") }
                SettingsCard(eyebrow: "Position") { Text("b") }
                SettingsCard(eyebrow: heading, anchor: "Engine account") { Text("c") }
                SettingsCard(
                    eyebrow: "Visibility",
                    caption: "words with a ) and a { inside"
                ) { Text("d") }
            }
        }
        """
        XCTAssertEqual(Self.parseCards(source).map(\.anchor),
                       ["Size", "Position", "Engine account", "Visibility"])
    }

    /// A heading built from an expression is not a constant destination, even
    /// when it begins with a quoted word.
    func testAnExpressionIsNotALiteralDestination() {
        let source = """
        struct EnginePane: View {
            var body: some View {
                SettingsCard(eyebrow: "Profiles" + suffix) { Text("a") }
                SettingsCard(eyebrow: "Language") { Text("b") }
            }
        }
        """
        let cards = Self.parseCards(source)
        XCTAssertEqual(cards.count, 2)
        XCTAssertNil(cards[0].anchor, "a concatenated heading is not a fixed destination")
        XCTAssertEqual(cards[1].anchor, "Language")
    }

    /// An anchor belonging to something nested inside the card must not be
    /// mistaken for the card's own.
    func testANestedAnchorArgumentIsNotTheCardsOwn() {
        let source = """
        struct OverlayPane: View {
            var body: some View {
                SettingsCard(eyebrow: heading, caption: helper(anchor: "not mine")) { Text("a") }
            }
        }
        """
        XCTAssertNil(Self.parseCards(source).first?.anchor)
    }

    func testInterpolationIsNotALiteralDestination() {
        // Raw, so the interpolation is what the fixture contains rather than
        // something this test performs.
        let source = #"""
        struct EnginePane: View {
            var body: some View {
                SettingsCard(eyebrow: "Profiles \(suffix)") { Text("a") }
            }
        }
        """#
        XCTAssertNil(Self.parseCards(source).first?.anchor,
                     "an interpolated heading is not a fixed destination")
    }

    /// The value compared against the index has to be the string the app
    /// carries, not the way the source spells it.
    func testEscapesAreDecoded() {
        let source = #"""
        struct OverlayPane: View {
            var body: some View {
                SettingsCard(eyebrow: "Say \"hello\"") { Text("a") }
                SettingsCard(eyebrow: "Not updating\u{2026}") { Text("b") }
            }
        }
        """#
        XCTAssertEqual(Self.parseCards(source).map(\.anchor),
                       ["Say \"hello\"", "Not updating\u{2026}"])
    }

    func testEveryVisiblePaneHasEntries() {
        for pane in SettingsPane.visibleCases where !Self.unindexedPanes.contains(pane) {
            XCTAssertFalse(
                SettingsIndex.entries.filter { $0.pane == pane }.isEmpty,
                "\(pane.title) has no searchable settings"
            )
        }
    }

    func testEntriesAreUnique() {
        let ids = SettingsIndex.entries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate entries in the index")
    }

    func testAliasesAreUsefulAndWellFormed() {
        for entry in SettingsIndex.entries {
            XCTAssertFalse(entry.aliases.isEmpty, "\(entry.card) has no aliases")
            for alias in entry.aliases {
                XCTAssertFalse(alias.trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(entry.card) has a blank alias")
                XCTAssertEqual(alias, alias.lowercased(),
                               "aliases are matched lowercased, so write them that way: \(alias)")
            }
        }
    }
}
