import XCTest
@testable import MicMyDay

/// "No rewrite" is a choice in the profile picker rather than a profile.
///
/// It exists because turning rewriting off used to mean a trip into Settings
/// before dictating and another one afterwards to put it back — and forgetting
/// the second trip leaves every later dictation raw without saying so. Made a
/// selection instead, it lasts exactly as long as it is selected.
@MainActor
final class NoRewriteProfileTests: XCTestCase {
    private var suiteName = ""

    private func makeSettings() -> SettingsStore {
        suiteName = "NoRewriteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(
            defaults: defaults,
            keychain: KeychainStore(service: "NoRewriteTests.\(UUID().uuidString)")
        )
        settings.rewriteProvider = .custom
        settings.enhancementBaseURL = "http://127.0.0.1:1/v1"
        settings.enhancementModel = "test-model"
        settings.enhancementEnabled = true
        return settings
    }

    override func tearDown() {
        if !suiteName.isEmpty {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    /// The whole mechanism. No configuration is the path that inserts the
    /// transcript untouched, and it is already the one an unreachable provider
    /// takes, so nothing new happens downstream.
    func testChoosingItProducesNoConfiguration() {
        let settings = makeSettings()
        settings.rewriteProfileID = RewriteProfile.none.id
        XCTAssertNil(settings.enhancementConfiguration())
    }

    /// Even when asked for by name, which is what the Tools menu does.
    func testAskingForItByNameProducesNoConfiguration() {
        let settings = makeSettings()
        XCTAssertNil(settings.enhancementConfiguration(forProfileID: RewriteProfile.none.id))
    }

    /// Rewriting is left alone. Choosing it must not switch anything off that
    /// the next profile would then have to switch back on.
    func testChoosingItDoesNotDisableRewriting() {
        let settings = makeSettings()
        settings.rewriteProfileID = RewriteProfile.none.id
        XCTAssertTrue(settings.enhancementEnabled)
        settings.rewriteProfileID = "cleanup"
        XCTAssertNotNil(settings.enhancementConfiguration())
    }

    func testItIsOfferedWhereverAProfileIsChosen() {
        let settings = makeSettings()
        XCTAssertTrue(settings.selectableRewriteProfiles.contains { $0.id == RewriteProfile.none.id })
    }

    /// Never in the stored list: it cannot be renamed, edited or deleted, and
    /// an entry in that array would be all three.
    func testItIsNotOneOfTheStoredProfiles() {
        let settings = makeSettings()
        XCTAssertFalse(settings.rewriteProfiles.contains { $0.id == RewriteProfile.none.id })
        XCTAssertFalse(RewriteProfile.builtins.contains { $0.id == RewriteProfile.none.id })
    }

    /// Deliberately outside the cycle. Cycling moves between ways of
    /// rewriting, and a no-op in that loop would be a dead step on every lap
    /// for everyone. Binding a shortcut straight to it is how somebody who
    /// works by keyboard alone gets at it.
    func testCyclingDoesNotPassThroughIt() {
        let settings = makeSettings()
        var seen: Set<String> = []
        for _ in 0 ..< settings.selectableRewriteProfiles.count + 1 {
            if let next = settings.cycleRewriteProfile() { seen.insert(next.id) }
        }
        XCTAssertFalse(seen.contains(RewriteProfile.none.id))
        XCTAssertEqual(seen.count, settings.rewriteProfiles.count)
    }

    /// Selecting it must survive the check that rejects ids which no longer
    /// resolve, or a shortcut bound to it would quietly do nothing.
    func testItResolvesAsTheCurrentProfile() {
        let settings = makeSettings()
        settings.rewriteProfileID = RewriteProfile.none.id
        XCTAssertEqual(settings.currentRewriteProfile?.id, RewriteProfile.none.id)
        XCTAssertEqual(settings.currentRewriteProfile?.name, "No rewrite")
    }

    /// A shortcut can be given to it like any profile, which is how somebody
    /// dictates raw without touching the picker at all: a profile shortcut
    /// selects the profile and, from idle, starts recording, so one key means
    /// "dictate this one exactly as I say it".
    func testAShortcutCanBeAssignedToIt() {
        let settings = makeSettings()
        let key = KeyboardShortcut(keyCode: 18, modifiers: 256, keyLabel: "1")
        settings.profileShortcuts[RewriteProfile.none.id] = key
        XCTAssertEqual(settings.profileShortcuts[RewriteProfile.none.id], key)
        // The same list the shortcut recorder and the hot-key registration walk.
        XCTAssertTrue(settings.selectableRewriteProfiles.contains { $0.id == RewriteProfile.none.id })
    }

    /// An id unlike anything somebody would type, because a custom profile that
    /// collided with it would silently stop rewriting.
    func testTheIdCannotBeReachedByAccident() {
        XCTAssertEqual(RewriteProfile.none.id, "__none__")
    }
}
