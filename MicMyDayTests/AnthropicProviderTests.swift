import XCTest
@testable import MicMyDay

/// Claude as a rewrite provider.
///
/// It is reached through Anthropic's OpenAI-compatible surface, so no new
/// transport was written. That makes the URL the whole of the integration, and
/// the one thing worth pinning: `/v1` plus the builder's own suffix has to come
/// out as the endpoint that actually exists, which was checked against the live
/// service returning 401 rather than 404.
final class AnthropicProviderTests: XCTestCase {
    func testTheEndpointIsTheOneAnthropicServes() throws {
        let base = try XCTUnwrap(RewriteProviderKind.anthropic.apiBaseURL)
        XCTAssertEqual(base, "https://api.anthropic.com/v1")
        XCTAssertEqual(
            try TranscriptEnhancer.chatCompletionsEndpoint(for: base).absoluteString,
            "https://api.anthropic.com/v1/chat/completions"
        )
    }

    func testItNeedsAKeyAndNothingElse() {
        XCTAssertEqual(RewriteProviderKind.anthropic.requirement, .key)
        XCTAssertNotNil(RewriteProviderKind.anthropic.defaultModel)
        XCTAssertFalse(RewriteProviderKind.anthropic.keyLabel.isEmpty)
        XCTAssertFalse(RewriteProviderKind.anthropic.keyHint.isEmpty, "A key field with no hint leaves the user hunting")
    }

    /// A subscription is not API credit, and people conflate the two. The hint
    /// has to say so, as OpenAI's already does.
    func testTheHintSaysASubscriptionIsNotCredit() {
        XCTAssertTrue(
            RewriteProviderKind.anthropic.keyHint.lowercased().contains("subscription"),
            "The hint must head off the subscription-versus-API-credit confusion"
        )
    }

    func testItIsOfferedAndDistinct() {
        XCTAssertTrue(RewriteProviderKind.offered.contains(.anthropic))
        let titles = RewriteProviderKind.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "Two providers must not share a name")
        let bases = RewriteProviderKind.allCases.compactMap(\.apiBaseURL)
        XCTAssertEqual(Set(bases).count, bases.count, "Two providers must not share an endpoint")
    }

    /// The rewrite path carries this provider's own key, never another's.
    @MainActor
    func testItUsesItsOwnKeyAndModel() throws {
        let name = "AnthropicProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(
            defaults: defaults,
            keychain: KeychainStore(service: name)
        )
        settings.enhancementEnabled = true
        settings.rewriteProvider = .anthropic
        settings.enhancementAPIKey = "sk-ant-test"
        settings.rewriteProviderModels[RewriteProviderKind.anthropic.rawValue] = "claude-sonnet-5"

        let configuration = try XCTUnwrap(settings.enhancementConfiguration())
        XCTAssertEqual(configuration.baseURL, "https://api.anthropic.com/v1")
        XCTAssertEqual(configuration.model, "claude-sonnet-5")
        XCTAssertEqual(configuration.apiKey, "sk-ant-test")
        XCTAssertFalse(configuration.usesOnDeviceModel)
        XCTAssertTrue(configuration.customHeaders.isEmpty, "Only the custom provider carries headers")
    }
}
