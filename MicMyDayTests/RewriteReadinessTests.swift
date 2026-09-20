import XCTest
@testable import MicMyDay

/// Covers the two provider-configuration bugs found in the pre-release audit:
/// a non-empty key alone used to count as "connected", and the Custom provider
/// used to default its endpoint to OpenAI.
final class RewriteReadinessTests: XCTestCase {
    @MainActor
    private func makeStore(_ name: String) -> (SettingsStore, UserDefaults, String) {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let service = "RewriteReadinessTests.\(UUID().uuidString)"
        return (SettingsStore(defaults: defaults, keychain: KeychainStore(service: service)), defaults, name)
    }

    @MainActor
    func testCustomProviderDoesNotDefaultToOpenAI() {
        let (settings, defaults, name) = makeStore("RewriteReadinessTests.custom")
        defer { defaults.removePersistentDomain(forName: name) }
        // Choosing "Custom" must not silently point at api.openai.com.
        XCTAssertTrue(settings.enhancementBaseURL.isEmpty)
        XCTAssertTrue(settings.enhancementModel.isEmpty)
    }

    @MainActor
    func testKeyAloneIsNotEnoughToCountAsConfigured() {
        let (settings, defaults, name) = makeStore("RewriteReadinessTests.key")
        defer { defaults.removePersistentDomain(forName: name) }
        settings.rewriteProvider = .openai
        settings.enhancementAPIKey = "sk-whatever"
        // No model entry at all is the real fresh-install shape. The provider
        // still advertises a default model, so the predicate must look at the
        // stored value that only successful validation writes.
        XCTAssertNil(settings.rewriteProviderModels[RewriteProviderKind.openai.rawValue])
        XCTAssertNotNil(settings.rewriteModel(for: .openai), "provider still offers a default")
        XCTAssertFalse(settings.rewriteProviderIsConfigured, "An unvalidated key must not read as connected")

        settings.rewriteProviderModels[RewriteProviderKind.openai.rawValue] = "gpt-5.6-luna"
        XCTAssertTrue(settings.rewriteProviderIsConfigured)
    }

    @MainActor
    func testCustomProviderNeedsBothURLAndModel() {
        let (settings, defaults, name) = makeStore("RewriteReadinessTests.customBoth")
        defer { defaults.removePersistentDomain(forName: name) }
        settings.rewriteProvider = .custom
        XCTAssertFalse(settings.rewriteProviderIsConfigured)

        settings.enhancementBaseURL = "http://127.0.0.1:11434/v1"
        XCTAssertFalse(settings.rewriteProviderIsConfigured, "A URL with no model must not read as connected")

        settings.enhancementModel = "llama3.1:8b"
        XCTAssertTrue(settings.rewriteProviderIsConfigured)
    }

    /// Rewriting switched on with nothing behind it used to insert the raw
    /// transcript and say nothing, which reads as a rewrite that ran and
    /// changed its mind rather than one that never started.
    @MainActor
    func testEnabledButUnconfiguredRewriteExplainsItself() {
        let (settings, defaults, name) = makeStore("RewriteReadinessTests.blocked")
        defer { defaults.removePersistentDomain(forName: name) }

        settings.enhancementEnabled = false
        XCTAssertNil(settings.rewriteUnavailableReason, "Nothing to explain while rewriting is off")

        settings.enhancementEnabled = true
        settings.rewriteProvider = .custom
        XCTAssertNil(settings.enhancementConfiguration())
        let reason = try? XCTUnwrap(settings.rewriteUnavailableReason)
        XCTAssertEqual(reason, "Custom is not connected yet.")

        settings.enhancementBaseURL = "http://127.0.0.1:11434/v1"
        settings.enhancementModel = "llama3.1:8b"
        XCTAssertTrue(settings.rewriteProviderIsConfigured)
        XCTAssertNotNil(settings.enhancementConfiguration())
        XCTAssertNil(settings.rewriteUnavailableReason, "A working setup has nothing to report")

        // A profile whose prompt was emptied is the other way a configured
        // provider still has nothing to run.
        settings.rewritePrompts[settings.rewriteProfileID] = "   "
        XCTAssertNil(settings.enhancementConfiguration())
        XCTAssertEqual(settings.rewriteUnavailableReason, "No rewrite instructions are set up.")
    }

    /// The on-device provider reports the system's own reason, so a Mac that
    /// cannot run it says which of the requirements is missing.
    @MainActor
    func testOnDeviceReasonComesFromTheSystem() {
        let (settings, defaults, name) = makeStore("RewriteReadinessTests.onDevice")
        defer { defaults.removePersistentDomain(forName: name) }
        settings.enhancementEnabled = true
        settings.rewriteProvider = .onDevice
        settings.localRewriteModelID = RewriteModelCatalog.appleModelID

        let availability = AppleOnDeviceRewriter.availability
        if availability.isAvailable {
            XCTAssertTrue(settings.rewriteProviderIsConfigured)
            XCTAssertNil(settings.rewriteUnavailableReason)
        } else {
            XCTAssertFalse(settings.rewriteProviderIsConfigured)
            XCTAssertEqual(settings.rewriteUnavailableReason, availability.explanation)
            XCTAssertNil(settings.enhancementConfiguration(), "Nothing may be sent for a provider that cannot run")
        }
    }

    /// "Automatic" is not a language anyone can check in advance, and a Mac
    /// with no model has no list to check against. Both must stay silent: a
    /// warning that fires for most people tells nobody anything.
    func testLanguageSupportIsOnlyAnsweredWhenItCanBe() {
        XCTAssertNil(AppleOnDeviceRewriter.supportsLanguage(""), "Automatic cannot be judged in advance")
        XCTAssertNil(AppleOnDeviceRewriter.supportsLanguage("   "))

        let answer = AppleOnDeviceRewriter.supportsLanguage("en")
        if AppleOnDeviceRewriter.availability.isAvailable {
            // Apple's model has always covered English; if that ever stops
            // being true the warning copy needs rethinking anyway.
            XCTAssertEqual(answer, true)
            XCTAssertEqual(AppleOnDeviceRewriter.supportsLanguage("EN"), true, "Stored codes vary in case")
        } else {
            XCTAssertNil(answer, "No model means no list to consult")
        }
    }
}
