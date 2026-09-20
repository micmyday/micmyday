import Carbon
import XCTest
@testable import MicMyDay

/// Inserting the last transcript again.
///
/// This exists because giving the clipboard back removed the accident that used
/// to serve as recovery: the transcript sitting on the clipboard after delivery.
/// So the default matters, and so does the fact that clearing it sticks.
final class InsertAgainTests: XCTestCase {
    @MainActor
    private func makeStore(_ name: String) -> (SettingsStore, UserDefaults, String) {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (
            SettingsStore(defaults: defaults, keychain: KeychainStore(service: "InsertAgainTests.\(UUID().uuidString)")),
            defaults,
            name
        )
    }

    func testTheDefaultIsControlOptionCommandV() {
        let shortcut = KeyboardShortcut.insertAgainDefault
        XCTAssertEqual(shortcut.keyCode, 9, "Key code 9 is V")
        XCTAssertNotEqual(shortcut.modifiers & UInt32(cmdKey), 0)
        XCTAssertNotEqual(shortcut.modifiers & UInt32(optionKey), 0)
        XCTAssertNotEqual(shortcut.modifiers & UInt32(controlKey), 0)
        // Plain Command-V is the system paste; Command-Option-V is the file
        // manager's move command. A global hotkey swallows its combination
        // system-wide, so neither may ever be the default.
        XCTAssertNotEqual(shortcut.modifiers, UInt32(cmdKey))
        XCTAssertNotEqual(shortcut.modifiers, UInt32(cmdKey) | UInt32(optionKey))
        XCTAssertFalse(shortcut.isModifierOnly, "A modifier alone would fire constantly")
    }

    @MainActor
    func testItIsSetOnAFreshInstall() {
        let (settings, defaults, name) = makeStore("InsertAgainTests.fresh")
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(settings.insertAgainShortcut, KeyboardShortcut.insertAgainDefault)
    }

    /// A shortcut the user deliberately cleared must not reappear on the next
    /// launch, which is what a plain "nil means use the default" would do.
    @MainActor
    func testClearingItSticksAcrossARestart() {
        let name = "InsertAgainTests.cleared"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }

        let first = SettingsStore(defaults: defaults, keychain: KeychainStore(service: name))
        first.insertAgainShortcut = nil

        let second = SettingsStore(defaults: defaults, keychain: KeychainStore(service: name))
        XCTAssertNil(second.insertAgainShortcut, "A cleared shortcut came back by itself")
    }

    @MainActor
    func testAChosenShortcutSurvivesARestart() {
        let name = "InsertAgainTests.chosen"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }

        let chosen = KeyboardShortcut(keyCode: 11, modifiers: UInt32(controlKey), keyLabel: "B")
        let first = SettingsStore(defaults: defaults, keychain: KeychainStore(service: name))
        first.insertAgainShortcut = chosen

        let second = SettingsStore(defaults: defaults, keychain: KeychainStore(service: name))
        XCTAssertEqual(second.insertAgainShortcut, chosen)
    }

    /// Two actions firing on one key combination would make one of them
    /// unreachable, and which one would depend on registration order.
    @MainActor
    func testItDoesNotCollideWithTheOtherDefaults() {
        let (settings, defaults, name) = makeStore("InsertAgainTests.collide")
        defer { defaults.removePersistentDomain(forName: name) }
        let others = [settings.shortcut, settings.cycleProfilesShortcut, settings.previousProfileShortcut, settings.editSelectionShortcut]
            .compactMap { $0 }
        for other in others {
            XCTAssertFalse(
                other.keyCode == KeyboardShortcut.insertAgainDefault.keyCode
                    && other.modifiers == KeyboardShortcut.insertAgainDefault.modifiers,
                "Two actions share a shortcut"
            )
        }
    }
}
