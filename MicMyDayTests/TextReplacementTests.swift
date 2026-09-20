import XCTest
@testable import MicMyDay

/// Corrections run on every transcript, so the matching rules matter: too
/// eager and it mangles ordinary words, too strict and it never fires.
final class TextReplacementTests: XCTestCase {
    private func rule(_ spoken: String, _ written: String, enabled: Bool = true) -> TextReplacement {
        TextReplacement(spoken: spoken, written: written, isEnabled: enabled)
    }

    func testFixesSpellingRegardlessOfCase() {
        let rules = [rule("micmyday", "MicMyDay")]
        XCTAssertEqual(TextReplacementEngine.apply(rules, to: "open micmyday"), "open MicMyDay")
        XCTAssertEqual(TextReplacementEngine.apply(rules, to: "Open Micmyday now"), "Open MicMyDay now")
        XCTAssertEqual(TextReplacementEngine.apply(rules, to: "MICMYDAY"), "MicMyDay")
    }

    func testOnlyMatchesWholeWords() {
        let rules = [rule("code", "Code")]
        // Substrings inside larger words must be left alone.
        XCTAssertEqual(TextReplacementEngine.apply(rules, to: "encoded barcode"), "encoded barcode")
        XCTAssertEqual(TextReplacementEngine.apply(rules, to: "the code runs"), "the Code runs")
    }

    func testPunctuationStillCountsAsAWordBoundary() {
        let rules = [rule("kubernetes", "Kubernetes")]
        XCTAssertEqual(
            TextReplacementEngine.apply(rules, to: "deploy kubernetes, then wait"),
            "deploy Kubernetes, then wait"
        )
        XCTAssertEqual(TextReplacementEngine.apply(rules, to: "(kubernetes)"), "(Kubernetes)")
    }

    func testMultiWordPhrasesWinOverShorterOverlappingRules() {
        let rules = [rule("code", "Code"), rule("visual studio code", "VS Code")]
        XCTAssertEqual(
            TextReplacementEngine.apply(rules, to: "open visual studio code now"),
            "open VS Code now"
        )
    }

    func testReplacementsAreNotRescanned() {
        // "a" -> "b" and "b" -> "c" must not chain into "c".
        let rules = [rule("alpha", "beta"), rule("beta", "gamma")]
        XCTAssertEqual(TextReplacementEngine.apply(rules, to: "alpha"), "beta")
    }

    func testDisabledRulesAreSkipped() {
        let rules = [rule("micmyday", "MicMyDay", enabled: false)]
        XCTAssertEqual(TextReplacementEngine.apply(rules, to: "micmyday"), "micmyday")
    }

    func testEmptyRulesAndBlankPhrasesAreIgnored() {
        XCTAssertEqual(TextReplacementEngine.apply([], to: "unchanged"), "unchanged")
        XCTAssertEqual(TextReplacementEngine.apply([rule("   ", "x")], to: "unchanged"), "unchanged")
    }

    func testLongerReplacementActsAsASnippet() {
        let rules = [rule("my sign off", "Kind regards, and thanks for your patience.")]
        XCTAssertEqual(
            TextReplacementEngine.apply(rules, to: "my sign off"),
            "Kind regards, and thanks for your patience."
        )
    }

    func testDiacriticsAreMatchedLoosely() {
        let rules = [rule("grafenwiesbach", "Grävenwiesbach")]
        XCTAssertEqual(
            TextReplacementEngine.apply(rules, to: "in gräfenwiesbach"),
            "in Grävenwiesbach"
        )
    }
}

/// Auto-send only fires on a real paste, and only for the profile in force.
final class AutoSendTests: XCTestCase {
    func testOffProducesNoKeystroke() {
        XCTAssertNil(AutoSendKey.off.keyStroke)
    }

    func testEachVariantTargetsReturnWithTheRightModifier() {
        XCTAssertEqual(AutoSendKey.returnKey.keyStroke?.keyCode, 36)
        XCTAssertEqual(AutoSendKey.returnKey.keyStroke?.flags, [])
        XCTAssertEqual(AutoSendKey.commandReturn.keyStroke?.flags, .maskCommand)
        XCTAssertEqual(AutoSendKey.shiftReturn.keyStroke?.flags, .maskShift)
    }

    @MainActor
    func testDefaultsToOffAndFollowsTheActiveProfile() {
        let name = "AutoSendTests"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(
            defaults: defaults,
            keychain: KeychainStore(service: "AutoSendTests.\(UUID().uuidString)")
        )
        // Pressing Return by surprise is destructive, so nothing is sent until
        // the user asks for it.
        XCTAssertEqual(settings.autoSendKey, .off)

        settings.autoSendKey = .returnKey
        XCTAssertEqual(settings.autoSendKey, .returnKey)

        // The same answer whatever is rewriting: one setting for every
        // dictation, not one per profile.
        settings.enhancementEnabled = true
        settings.rewriteProfileID = "agentPrompt"
        XCTAssertEqual(settings.autoSendKey, .returnKey)

        settings.rewriteProfileID = "email"
        XCTAssertEqual(settings.autoSendKey, .returnKey)
    }
}
