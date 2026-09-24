import XCTest
@testable import MicMyDay

/// The apps MicMyDay will not type into.
///
/// The rule itself is one predicate, and these cover it directly rather than
/// through the delivery path: what the path does with the answer is the same
/// thing it already does when automatic pasting is off, and that has its own
/// tests. What is worth pinning here is that the answer is right, and that an
/// empty list never changes anybody's behaviour.
final class NeverPasteTests: XCTestCase {
    @MainActor
    private func freshSettings(_ name: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return SettingsStore(defaults: defaults, keychain: KeychainStore(service: name))
    }

    @MainActor
    func testNothingIsExcludedUntilSomebodyExcludesIt() {
        let name = "NeverPasteTests.empty"
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let settings = freshSettings(name)

        XCTAssertEqual(settings.neverPasteBundleIDs, [])
        XCTAssertTrue(settings.allowsAutomaticPaste(intoBundleID: "com.apple.Terminal"))
    }

    @MainActor
    func testAnExcludedAppIsRefusedAndItsNeighboursAreNot() {
        let name = "NeverPasteTests.excluded"
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let settings = freshSettings(name)
        settings.neverPasteBundleIDs = ["com.apple.Terminal"]

        XCTAssertFalse(settings.allowsAutomaticPaste(intoBundleID: "com.apple.Terminal"))
        XCTAssertTrue(settings.allowsAutomaticPaste(intoBundleID: "com.apple.TextEdit"))
    }

    /// A bundle identifier is matched whole. Prefix matching would take
    /// "com.apple.Terminal" as permission to refuse "com.apple.TerminalX",
    /// which is a different app by a different author.
    @MainActor
    func testMatchingIsExactRatherThanByPrefix() {
        let name = "NeverPasteTests.prefix"
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let settings = freshSettings(name)
        settings.neverPasteBundleIDs = ["com.apple.Terminal"]

        XCTAssertTrue(settings.allowsAutomaticPaste(intoBundleID: "com.apple.TerminalX"))
        XCTAssertTrue(settings.allowsAutomaticPaste(intoBundleID: "com.apple"))
    }

    /// Nothing in front is not an excluded app. Treating nil as excluded would
    /// quietly stop pasting for dictations that had no destination to begin
    /// with, which is a different feature nobody asked for.
    @MainActor
    func testNoFrontmostAppIsNotAnExclusion() {
        let name = "NeverPasteTests.nilTarget"
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let settings = freshSettings(name)
        settings.neverPasteBundleIDs = ["com.apple.Terminal"]

        XCTAssertTrue(settings.allowsAutomaticPaste(intoBundleID: nil))
    }

    @MainActor
    func testTheListSurvivesARestart() {
        let name = "NeverPasteTests.persist"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }

        let first = SettingsStore(defaults: defaults, keychain: KeychainStore(service: name))
        first.neverPasteBundleIDs = ["com.agilebits.onepassword7", "com.apple.Terminal"]

        let returning = SettingsStore(defaults: defaults, keychain: KeychainStore(service: name))
        XCTAssertEqual(
            returning.neverPasteBundleIDs,
            ["com.agilebits.onepassword7", "com.apple.Terminal"]
        )
        XCTAssertFalse(returning.allowsAutomaticPaste(intoBundleID: "com.agilebits.onepassword7"))
    }
}
