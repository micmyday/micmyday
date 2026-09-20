import XCTest
@testable import MicMyDay

/// Covers the parts of local rewriting that need neither a model file nor a
/// GPU: what the catalogue promises, when the app considers itself ready, and
/// what is stripped from a small model's answer before it reaches the cursor.
final class LocalRewriteModelTests: XCTestCase {
    @MainActor
    private func makeStore(_ name: String) -> (SettingsStore, UserDefaults, String) {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let service = "LocalRewriteModelTests.\(UUID().uuidString)"
        return (SettingsStore(defaults: defaults, keychain: KeychainStore(service: service)), defaults, name)
    }

    // MARK: - Catalogue

    func testExactlyOneModelIsBuiltIntoMacOS() {
        let builtIn = RewriteModelCatalog.models.filter(\.isAppleBuiltIn)
        XCTAssertEqual(builtIn.count, 1)
        XCTAssertEqual(builtIn.first?.id, RewriteModelCatalog.appleModelID)
        XCTAssertNil(builtIn.first?.download, "The built-in model must never be downloadable")
    }

    func testEveryOtherModelIsDownloadableAndDescribed() {
        for model in RewriteModelCatalog.downloadable {
            guard let download = model.download else {
                XCTFail("\(model.id) is listed as downloadable but has no download")
                continue
            }
            XCTAssertFalse(model.note.isEmpty, "\(model.id) has nothing to tell the user")
            XCTAssertGreaterThan(download.megabytes, 0, "\(model.id) claims to be free")
            // The file name is also the name on disk, so two models sharing one
            // would have them overwrite each other.
            XCTAssertTrue(download.file.hasSuffix(".gguf"), model.id)
        }
        let files = RewriteModelCatalog.downloadable.compactMap { $0.download?.file }
        XCTAssertEqual(Set(files).count, files.count, "Two models would share a file on disk")
        let ids = RewriteModelCatalog.models.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testDownloadURLsPointAtTheNamedFile() {
        for model in RewriteModelCatalog.downloadable {
            guard let download = model.download else { continue }
            let url = download.url
            XCTAssertEqual(url.scheme, "https", model.id)
            XCTAssertEqual(url.host, "huggingface.co", model.id)
            XCTAssertEqual(url.lastPathComponent, download.file, model.id)
            XCTAssertTrue(url.path.contains(download.repository), model.id)
        }
    }

    func testSizeLabelSwitchesToGigabytes() {
        let small = LocalRewriteModel(
            id: "s", displayName: "S", note: "n",
            download: .init(repository: "o/r", file: "s.gguf", format: .chatML, megabytes: 806)
        )
        let large = LocalRewriteModel(
            id: "l", displayName: "L", note: "n",
            download: .init(repository: "o/r", file: "l.gguf", format: .chatML, megabytes: 2740)
        )
        XCTAssertEqual(small.sizeLabel, "806 MB")
        XCTAssertEqual(large.sizeLabel, "2.7 GB")
        XCTAssertEqual(RewriteModelCatalog.model(withID: RewriteModelCatalog.appleModelID)?.sizeLabel,
                       "Built into macOS")
    }

    @MainActor
    func testFreshSettingsUseTheRecommendedGemmaE4B() {
        let (settings, defaults, name) = makeStore("LocalRewriteModelTests.default")
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(settings.localRewriteModelID, "gemma4-e4b")
        let model = RewriteModelCatalog.model(withID: settings.localRewriteModelID)
        XCTAssertEqual(model?.isRecommended, true)
        XCTAssertNotNil(model?.download)
    }

    @MainActor
    func testChangingTheDefaultPreservesAnExistingModelChoice() {
        let (first, defaults, name) = makeStore("LocalRewriteModelTests.savedChoice")
        defer { defaults.removePersistentDomain(forName: name) }
        for id in [RewriteModelCatalog.appleModelID, "gemma4-e2b", "qwen3.5-4b", "qwen3.5-2b"] {
            first.localRewriteModelID = id
            let restored = SettingsStore(defaults: defaults, keychain: KeychainStore(service: name))
            XCTAssertEqual(restored.localRewriteModelID, id)
        }
    }

    // MARK: - Readiness

    /// A downloaded model is not ready before it has been downloaded, whatever
    /// Apple Intelligence happens to be doing on this Mac.
    @MainActor
    func testADownloadableModelIsNotReadyUntilItIsOnDisk() {
        let (settings, defaults, name) = makeStore("LocalRewriteModelTests.readiness")
        defer { defaults.removePersistentDomain(forName: name) }
        settings.enhancementEnabled = true
        settings.rewriteProvider = .onDevice

        guard let model = RewriteModelCatalog.downloadable.first else { return XCTFail("No downloadable models") }
        settings.localRewriteModelID = model.id

        // These tests must never depend on what happens to be downloaded on the
        // machine running them, so both outcomes are asserted honestly.
        if RewriteModelManager.isInstalled(modelID: model.id) {
            XCTAssertTrue(settings.rewriteProviderIsConfigured)
            XCTAssertNil(settings.rewriteUnavailableReason)
        } else {
            XCTAssertFalse(settings.rewriteProviderIsConfigured)
            XCTAssertEqual(settings.rewriteUnavailableReason, "\(model.displayName) has not been downloaded yet.")
            XCTAssertNil(settings.enhancementConfiguration(), "A model that is not there must not be run")
        }
    }

    /// The configuration carries which local model to use, because the enhancer
    /// cannot reach back into settings from the thread it runs on.
    @MainActor
    func testConfigurationCarriesTheChosenLocalModel() throws {
        let (settings, defaults, name) = makeStore("LocalRewriteModelTests.configuration")
        defer { defaults.removePersistentDomain(forName: name) }
        settings.enhancementEnabled = true
        settings.rewriteProvider = .onDevice
        settings.localRewriteModelID = RewriteModelCatalog.appleModelID

        guard AppleOnDeviceRewriter.availability.isAvailable else {
            throw XCTSkip("This Mac has no built-in model, so there is no configuration to inspect")
        }
        let configuration = try XCTUnwrap(settings.enhancementConfiguration())
        XCTAssertEqual(configuration.model, RewriteModelCatalog.appleModelID)
        XCTAssertTrue(configuration.usesOnDeviceModel)
        XCTAssertEqual(configuration.baseURL, "")
        XCTAssertEqual(configuration.apiKey, "", "Nothing on this path is authenticated")
    }

    /// An id from a newer build, or one we have dropped, must not leave the
    /// picker with nothing selected.
    @MainActor
    func testAnUnknownStoredModelFallsBack() {
        let name = "LocalRewriteModelTests.unknown"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("a-model-from-the-future", forKey: "localRewriteModelID")

        let settings = SettingsStore(
            defaults: defaults,
            keychain: KeychainStore(service: "LocalRewriteModelTests.\(UUID().uuidString)")
        )
        XCTAssertEqual(settings.localRewriteModelID, RewriteModelCatalog.defaultModelID)
    }

    // MARK: - What the model produces

    func testReasoningIsRemovedBeforeTheTextIsUsed() {
        XCTAssertEqual(
            LlamaCppEngine.stripReasoning("<think>weighing it up</think>The finished sentence."),
            "The finished sentence."
        )
        XCTAssertEqual(
            LlamaCppEngine.stripReasoning("Before <think>aside</think>after."),
            "Before after."
        )
    }

    /// A model that opens a thinking block and runs out of tokens has produced
    /// no answer at all. Returning its reasoning would be worse than returning
    /// nothing, because the caller falls back to the raw transcript.
    func testUnclosedReasoningLeavesNothingBehind() {
        XCTAssertEqual(
            LlamaCppEngine.stripReasoning("<think>still thinking and thinking and"),
            ""
        )
    }

    func testTextWithoutReasoningIsUntouched() {
        let plain = "Nothing to strip here, <not a think> tag."
        XCTAssertEqual(LlamaCppEngine.stripReasoning(plain), plain)
    }
}
