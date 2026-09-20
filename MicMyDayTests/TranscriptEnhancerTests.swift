import XCTest
@testable import MicMyDay

final class TranscriptEnhancerTests: XCTestCase {
    func testBuildsChatEndpointFromVersionedBaseURL() throws {
        let url = try TranscriptEnhancer.chatCompletionsEndpoint(for: "https://api.openai.com/v1")
        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    func testKeepsCompleteChatEndpoint() throws {
        let url = try TranscriptEnhancer.chatCompletionsEndpoint(for: "http://127.0.0.1:11434/v1/chat/completions")
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
    }

    func testRejectsUnsupportedScheme() {
        XCTAssertThrowsError(try TranscriptEnhancer.chatCompletionsEndpoint(for: "ftp://example.com/v1"))
    }

    func testBuiltInProfilesCarrySystemPrompts() {
        for profile in RewriteProfile.builtins {
            XCTAssertFalse(RewriteProfile.defaultPrompt(for: profile.id).isEmpty, "\(profile.id) should define a prompt")
        }
        XCTAssertFalse(EnhancementOutput.instruction.isEmpty)
    }

    @MainActor
    func testDisabledEnhancementYieldsNoConfiguration() {
        let defaults = UserDefaults(suiteName: "TranscriptEnhancerTests")!
        defaults.removePersistentDomain(forName: "TranscriptEnhancerTests")
        defer { defaults.removePersistentDomain(forName: "TranscriptEnhancerTests") }
        let settings = SettingsStore(defaults: defaults, keychain: KeychainStore(service: "TranscriptEnhancerTests.\(UUID().uuidString)"))
        settings.enhancementEnabled = false
        XCTAssertNil(settings.enhancementConfiguration())

        settings.enhancementEnabled = true
        settings.rewriteProfileID = "agentPrompt"
        // A configured provider is now a precondition: an unvalidated key used
        // to yield a config and then fail on every dictation.
        settings.enhancementAPIKey = "test-key"
        settings.rewriteProviderModels[settings.rewriteProvider.rawValue] = "some-model"
        let configuration = settings.enhancementConfiguration()
        XCTAssertEqual(configuration?.systemPrompt, RewriteProfile.defaultPrompt(for: "agentPrompt"))

        // A custom mode without a prompt is misconfigured and must not run.
        settings.rewritePrompts[settings.rewriteProfileID] = "  "
        XCTAssertNil(settings.enhancementConfiguration())
    }

    @MainActor
    func testProviderSelectionRoutesRequestsAndIsolatesKeys() throws {
        let suite = "RewriteRoutingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let keychain = KeychainStore(service: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            for provider in RewriteProviderKind.allCases {
                try? keychain.set("", account: "rewrite-\(provider.rawValue)-api-key")
            }
        }
        let settings = SettingsStore(defaults: defaults, keychain: keychain)
        settings.enhancementEnabled = true
        settings.rewriteProvider = .openai
        settings.enhancementAPIKey = "test-openai-key"
        settings.rewriteProviderModels[RewriteProviderKind.openai.rawValue] = "gpt-5.6-luna"
        XCTAssertEqual(settings.enhancementConfiguration()?.baseURL, "https://api.openai.com/v1")
        settings.rewriteProvider = .gemini
        XCTAssertEqual(settings.enhancementAPIKey, "")
        settings.enhancementAPIKey = "test-gemini-key"
        settings.rewriteProviderModels[RewriteProviderKind.gemini.rawValue] = "gemini-2.5-flash"
        let gemini = try XCTUnwrap(settings.enhancementConfiguration())
        XCTAssertEqual(gemini.baseURL, "https://generativelanguage.googleapis.com/v1beta/openai")
        XCTAssertEqual(gemini.apiKey, "test-gemini-key")
        settings.rewriteProvider = .openai
        XCTAssertEqual(settings.enhancementAPIKey, "test-openai-key")
        settings.rewriteProvider = .custom
        settings.enhancementBaseURL = "http://homeserver.local:11434/v1"
        settings.enhancementModel = "local-model"
        XCTAssertEqual(settings.enhancementConfiguration()?.model, "local-model")
        XCTAssertEqual(settings.enhancementConfiguration()?.baseURL, settings.enhancementBaseURL)
        settings.rewritePrompts[settings.rewriteProfileID] = "Preserve my wording."
        XCTAssertEqual(settings.enhancementConfiguration()?.systemPrompt, "Preserve my wording.")
    }

    @MainActor
    func testCustomHeadersMigrateOutOfPreferences() throws {
        let suite = "RewriteHeaderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let keychain = KeychainStore(service: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? keychain.set("", account: "rewrite-custom-headers")
        }
        defaults.set(try JSONEncoder().encode([CustomHeader(name: "X-Test", value: "private")]), forKey: "rewriteCustomHeaders")
        let settings = SettingsStore(defaults: defaults, keychain: keychain)
        XCTAssertEqual(settings.rewriteCustomHeaders.first?.value, "private")
        XCTAssertNil(defaults.object(forKey: "rewriteCustomHeaders"))
        XCTAssertNotNil(try keychain.get(account: "rewrite-custom-headers"))
    }
}
