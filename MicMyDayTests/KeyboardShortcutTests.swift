import Carbon
import XCTest
@testable import MicMyDay

final class KeyboardShortcutTests: XCTestCase {
    func testDisplayStringUsesMacModifierOrder() {
        let shortcut = KeyboardShortcut(
            keyCode: 49,
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
            keyLabel: "Space"
        )
        XCTAssertEqual(shortcut.displayString, "⌃⌥⇧⌘Space")
    }

    func testShortcutRoundTripsThroughJSON() throws {
        let original = KeyboardShortcut.default
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardShortcut.self, from: data), original)
    }

    @MainActor
    func testFreshSettingsCycleProfilesWithControlOptionCommandArrowKeys() {
        let name = "KeyboardShortcutTests.cycleDefault"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults, keychain: KeychainStore(service: name))
        XCTAssertEqual(settings.cycleProfilesShortcut?.keyCode, UInt32(kVK_RightArrow))
        XCTAssertEqual(
            settings.cycleProfilesShortcut?.modifiers,
            UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
        )
        XCTAssertEqual(settings.cycleProfilesShortcut?.displayString, "⌃⌥⌘→")
        XCTAssertEqual(settings.previousProfileShortcut?.keyCode, UInt32(kVK_LeftArrow))
        XCTAssertEqual(
            settings.previousProfileShortcut?.modifiers,
            UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
        )
        XCTAssertEqual(settings.previousProfileShortcut?.displayString, "⌃⌥⌘←")
    }

    @MainActor
    func testCycleProfileShortcutChoiceAndClearingSurviveRestart() {
        let name = "KeyboardShortcutTests.cycleSaved"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let first = SettingsStore(defaults: defaults, keychain: KeychainStore(service: name))
        let chosen = KeyboardShortcut(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(cmdKey | optionKey), keyLabel: "↑")
        let previous = KeyboardShortcut(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(cmdKey | optionKey), keyLabel: "←")
        first.cycleProfilesShortcut = chosen
        first.previousProfileShortcut = previous
        let restored = SettingsStore(defaults: defaults, keychain: KeychainStore(service: name))
        XCTAssertEqual(restored.cycleProfilesShortcut, chosen)
        XCTAssertEqual(restored.previousProfileShortcut, previous)
        restored.cycleProfilesShortcut = nil
        restored.previousProfileShortcut = nil
        let cleared = SettingsStore(defaults: defaults, keychain: KeychainStore(service: name))
        XCTAssertNil(cleared.cycleProfilesShortcut)
        XCTAssertNil(cleared.previousProfileShortcut)
        cleared.cycleProfilesShortcut = .cycleProfilesDefault
        cleared.previousProfileShortcut = .previousProfileDefault
        let reset = SettingsStore(defaults: defaults, keychain: KeychainStore(service: name))
        XCTAssertEqual(reset.cycleProfilesShortcut, .cycleProfilesDefault)
        XCTAssertEqual(reset.previousProfileShortcut, .previousProfileDefault)
    }

    @MainActor
    func testProfileCyclingMovesBothWaysAndWraps() {
        let name = "KeyboardShortcutTests.cycleDirection"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults, keychain: KeychainStore(service: name))
        settings.rewriteProfiles = ["a", "b", "c"].map { RewriteProfile(id: $0, name: $0, builtin: false) }
        settings.rewriteProfileID = "b"
        XCTAssertEqual(settings.cycleRewriteProfile(backwards: true)?.id, "a")
        XCTAssertEqual(settings.cycleRewriteProfile(backwards: true)?.id, "c")
        XCTAssertEqual(settings.rewriteProfileID, "c")
        XCTAssertEqual(settings.cycleRewriteProfile()?.id, "a")
        XCTAssertEqual(settings.cycleRewriteProfile()?.id, "b")
        XCTAssertEqual(settings.rewriteProfileID, "b")
    }

    @MainActor
    func testProfileCyclingHandlesMissingSelectionAndShortLists() {
        let name = "KeyboardShortcutTests.cycleEdges"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults, keychain: KeychainStore(service: name))
        settings.rewriteProfiles = ["a", "b"].map { RewriteProfile(id: $0, name: $0, builtin: false) }
        settings.rewriteProfileID = "removed"
        XCTAssertEqual(settings.cycleRewriteProfile(backwards: true)?.id, "b")
        settings.rewriteProfileID = "removed"
        XCTAssertEqual(settings.cycleRewriteProfile()?.id, "a")

        settings.rewriteProfiles.removeLast()
        XCTAssertEqual(settings.cycleRewriteProfile(backwards: true)?.id, "a")
        XCTAssertEqual(settings.cycleRewriteProfile()?.id, "a")
        settings.rewriteProfiles = []
        XCTAssertNil(settings.cycleRewriteProfile(backwards: true))
        XCTAssertNil(settings.cycleRewriteProfile())
        XCTAssertEqual(settings.rewriteProfileID, "a")
    }
}


extension KeyboardShortcutTests {
    func testLoneModifierShortcutIsModifierOnly() {
        let rightShift = KeyboardShortcut(keyCode: 60, modifiers: 0, keyLabel: "Right ⇧")
        XCTAssertTrue(rightShift.isModifierOnly)
        XCTAssertEqual(rightShift.displayString, "Right ⇧")
    }

    func testComboAndBareFunctionKeyAreNotModifierOnly() {
        // The default itself is modifier-only (right Shift), so use an
        // explicit combo to prove combos never count as modifier-only.
        let combo = KeyboardShortcut(keyCode: 49, modifiers: UInt32(controlKey | optionKey), keyLabel: "Space")
        XCTAssertFalse(combo.isModifierOnly)
        let bareF13 = KeyboardShortcut(keyCode: 105, modifiers: 0, keyLabel: "F13")
        XCTAssertFalse(bareF13.isModifierOnly)
    }

    func testDefaultShortcutIsRightShift() {
        XCTAssertTrue(KeyboardShortcut.default.isModifierOnly)
        XCTAssertEqual(KeyboardShortcut.default.keyCode, 60)
    }
}
