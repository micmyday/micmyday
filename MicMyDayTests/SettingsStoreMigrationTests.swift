import XCTest
@testable import MicMyDay

final class SettingsStoreMigrationTests: XCTestCase {
    private func makeDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// The check is on for somebody who has never heard of it, because the
    /// words it removes were never spoken. A stored choice still wins, so
    /// anybody who turned it off stays off across updates.
    @MainActor
    func testTheSilenceCheckIsOnUnlessItWasTurnedOff() {
        let name = "SettingsStoreMigrationTests.voiceActivity"
        let defaults = makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }

        let fresh = SettingsStore(defaults: defaults, keychain: KeychainStore(service: "SettingsStoreMigrationTests.\(UUID().uuidString)"))
        XCTAssertTrue(fresh.requireVoiceActivity)

        defaults.set(false, forKey: "requireVoiceActivity")
        let returning = SettingsStore(defaults: defaults, keychain: KeychainStore(service: "SettingsStoreMigrationTests.\(UUID().uuidString)"))
        XCTAssertFalse(returning.requireVoiceActivity)
    }

    @MainActor
    func testStoredChatGPTProviderFallsBackToOpenAI() {
        let name = "SettingsStoreMigrationTests.chatgpt"
        let defaults = makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("chatgpt", forKey: "rewriteProvider")

        let settings = SettingsStore(defaults: defaults, keychain: KeychainStore(service: "SettingsStoreMigrationTests.\(UUID().uuidString)"))
        // The Codex route is gone; a stored selection must land on a provider
        // that still exists rather than crashing or staying undecodable.
        XCTAssertEqual(settings.rewriteProvider, .openai)
    }

    @MainActor
    func testChatGPTMigrationDisablesRewritingInsteadOfSilentlySwitchingProviders() {
        let name = "SettingsStoreMigrationTests.chatgptEnabled"
        let defaults = makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("chatgpt", forKey: "rewriteProvider")
        defaults.set(true, forKey: "enhancementEnabled")

        let settings = SettingsStore(defaults: defaults, keychain: KeychainStore(service: "SettingsStoreMigrationTests.\(UUID().uuidString)"))
        // A user who rewrote through their ChatGPT plan may hold an OpenAI key
        // and a remembered consent; their transcripts must not start flowing
        // to the billed API without an explicit new choice.
        XCTAssertFalse(settings.enhancementEnabled)
        XCTAssertEqual(defaults.object(forKey: "enhancementEnabled") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: "rewriteProvider"), "openai")
    }

    @MainActor
    func testFreshInstallDefaultsToOpenAIRewriteProvider() {
        let name = "SettingsStoreMigrationTests.fresh"
        let defaults = makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = SettingsStore(defaults: defaults, keychain: KeychainStore(service: "SettingsStoreMigrationTests.\(UUID().uuidString)"))
        XCTAssertEqual(settings.rewriteProvider, .openai)
        XCTAssertFalse(settings.enhancementEnabled, "Rewriting must stay opt-in")
    }

    @MainActor
    func testLegacyCompletionSoundPreferenceCarriesOverOnce() {
        let name = "SettingsStoreMigrationTests.sound"
        let defaults = makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "playCompletionSound")

        let settings = SettingsStore(defaults: defaults, keychain: KeychainStore(service: "SettingsStoreMigrationTests.\(UUID().uuidString)"))
        XCTAssertFalse(settings.playFeedbackSounds)
        // The fallback is written to the new key so later launches do not
        // depend on the legacy one surviving.
        XCTAssertEqual(defaults.object(forKey: "playFeedbackSounds") as? Bool, false)
    }

    @MainActor
    func testExplicitFeedbackSoundSettingBeatsLegacyValue() {
        let name = "SettingsStoreMigrationTests.soundNew"
        let defaults = makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "playCompletionSound")
        defaults.set(true, forKey: "playFeedbackSounds")

        let settings = SettingsStore(defaults: defaults, keychain: KeychainStore(service: "SettingsStoreMigrationTests.\(UUID().uuidString)"))
        XCTAssertTrue(settings.playFeedbackSounds)
    }
}
