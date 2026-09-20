import XCTest
@testable import MicMyDay

/// Building a rewrite for a profile the user named, which is what the Tools
/// menu does, follows different rules from building the one dictation uses.
@MainActor
final class NamedProfileConfigurationTests: XCTestCase {
    private var suiteName = ""

    private func makeSettings() -> SettingsStore {
        suiteName = "NamedProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(
            defaults: defaults,
            keychain: KeychainStore(service: "NamedProfileTests.\(UUID().uuidString)")
        )
        settings.rewriteProvider = .custom
        settings.enhancementBaseURL = "http://127.0.0.1:1/v1"
        settings.enhancementModel = "test-model"
        return settings
    }

    override func tearDown() {
        if !suiteName.isEmpty {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    func testANamedProfileWinsOverTheDictationProfile() {
        let settings = makeSettings()
        settings.rewriteProfileID = "cleanup"
        let configuration = settings.enhancementConfiguration(forProfileID: "email")
        XCTAssertEqual(configuration?.profileID, "email")
    }

    /// The switch decides what happens to dictation by default. Asking for a
    /// profile by name is a separate request and must still work with it off.
    func testANamedProfileRunsEvenWithDictationRewritingOff() {
        let settings = makeSettings()
        settings.enhancementEnabled = false
        XCTAssertNil(settings.enhancementConfiguration())
        XCTAssertNotNil(settings.enhancementConfiguration(forProfileID: "cleanup"))
    }

    /// A provider that cannot be reached is still a refusal, named profile or
    /// not: there is nothing to send the text to.
    func testAnUnconfiguredProviderRefusesEvenANamedProfile() {
        let settings = makeSettings()
        settings.enhancementModel = ""
        XCTAssertNil(settings.enhancementConfiguration(forProfileID: "cleanup"))
    }

    /// A profile deleted between the menu being built and the work starting
    /// must stop the rewrite, not hand the text to whichever profile
    /// dictation happens to use: that would rewrite it in a voice nobody
    /// chose, and nothing on screen would say so.
    func testAnUnknownProfileIsRefusedRatherThanSubstituted() {
        let settings = makeSettings()
        settings.rewriteProfileID = "email"
        XCTAssertNil(settings.enhancementConfiguration(forProfileID: "does-not-exist"))
        // The dictation path, which names no profile, is unaffected by the
        // stricter rule.
        settings.enhancementEnabled = true
        XCTAssertEqual(settings.enhancementConfiguration()?.profileID, "email")
    }
}
