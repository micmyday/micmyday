import XCTest
@testable import MicMyDay

/// One local entry became three, which changes what a stored setup means and
/// which models a list may show.
@MainActor
final class LocalEngineSplitTests: XCTestCase {

    /// Parakeet knows 25 European languages and nothing else, so recommending
    /// it on a Mac set to a language it cannot hear recommends an app that
    /// cannot transcribe a word its owner says.
    func testTheRecommendedEngineCanActuallyHearThisMacsLanguage() {
        let code = Locale.current.language.languageCode?.identifier.lowercased() ?? ""
        let parakeetKnowsIt = SpokenLanguageCatalog.parakeetLanguageCodes.contains(code)
        XCTAssertEqual(
            WhisperModelCatalog.recommendedEngine,
            parakeetKnowsIt ? .parakeet : .whisper
        )
    }

    /// The default model has to belong to the engine that is recommended, or
    /// setup opens a list the selected model is not in.
    func testTheDefaultModelBelongsToTheRecommendedEngine() {
        let model = WhisperModelCatalog.model(withID: WhisperModelCatalog.defaultModelID)
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.engine, WhisperModelCatalog.recommendedEngine)
    }

    private var suiteName = ""

    private func store(provider: String?, model: String?) -> SettingsStore {
        suiteName = "LocalEngineSplit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        if let provider { defaults.set(provider, forKey: "provider") }
        if let model { defaults.set(model, forKey: "whisperModelID") }
        return SettingsStore(
            defaults: defaults,
            keychain: KeychainStore(service: "LocalEngineSplit.\(UUID().uuidString)")
        )
    }

    override func tearDown() {
        if !suiteName.isEmpty { UserDefaults().removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    /// The old single entry stored "localWhisper" whichever engine the chosen
    /// model belonged to, so the model decides which of the three a stored
    /// setup now means.
    func testAStoredParakeetSetupBecomesTheParakeetEngine() {
        let settings = store(provider: "localWhisper", model: "parakeet-tdt-0.6b-v3-q8_0")
        XCTAssertEqual(settings.provider, .parakeet)
        XCTAssertEqual(settings.whisperModelID, "parakeet-tdt-0.6b-v3-q8_0", "the model itself must not change")
    }

    func testAStoredNemotronSetupBecomesTheNemotronEngine() {
        let settings = store(provider: "localWhisper", model: NemotronEngine.modelID)
        XCTAssertEqual(settings.provider, .nemotron)
    }

    func testAStoredWhisperSetupIsLeftAlone() {
        let settings = store(provider: "localWhisper", model: "large-v3-turbo-q5_0")
        XCTAssertEqual(settings.provider, .whisper)
        XCTAssertEqual(settings.whisperModelID, "large-v3-turbo-q5_0")
    }

    /// Switching engine must leave a model of that engine selected, or the
    /// list shows nothing chosen and the app transcribes with something the
    /// list does not offer.
    func testChangingEngineSelectsOneOfItsOwnModels() {
        let settings = store(provider: "localWhisper", model: "large-v3-turbo-q5_0")
        settings.provider = .parakeet
        XCTAssertEqual(WhisperModelCatalog.model(withID: settings.whisperModelID)?.engine, .parakeet)
        settings.provider = .nemotron
        XCTAssertEqual(WhisperModelCatalog.model(withID: settings.whisperModelID)?.engine, .nemotron)
        settings.provider = .whisper
        XCTAssertEqual(WhisperModelCatalog.model(withID: settings.whisperModelID)?.engine, .whisper)
    }

    /// A cloud provider has no local engine, so nothing about the stored
    /// local model may be touched when one is chosen.
    func testChoosingACloudProviderLeavesTheLocalModelAlone() {
        let settings = store(provider: "localWhisper", model: "large-v3-turbo-q5_0")
        settings.provider = .openAI
        XCTAssertEqual(settings.whisperModelID, "large-v3-turbo-q5_0")
    }

    /// The three streaming builds are the same model at different latencies,
    /// and each is a separate download, so they must not share a directory.
    func testEachStreamingBuildHasItsOwnVariant() {
        let ids = [NemotronEngine.modelID, NemotronEngine.steadyModelID]
        XCTAssertEqual(ids.map(NemotronEngine.chunkMs(for:)), [1120, 2240])
        let directories = Set(ids.map { NemotronEngine.variantDirectory(for: $0).path })
        XCTAssertEqual(directories.count, 2, "each build needs its own directory")
        for id in ids {
            XCTAssertEqual(WhisperModelCatalog.model(withID: id)?.engine, .nemotron, "\(id) missing from the catalog")
        }
    }

    func testRatingsFollowTheSelectedModelAndProvider() {
        let settings = store(provider: "localWhisper", model: "tiny")
        let tiny = EngineCatalog.assessment(for: settings)
        settings.whisperModelID = "large-v3-turbo-q5_0"
        let turbo = EngineCatalog.assessment(for: settings)
        XCTAssertGreaterThan(turbo.accuracy, tiny.accuracy)

        settings.provider = .gemini
        settings.geminiModel = "gemini-2.5-flash"
        let flash = EngineCatalog.assessment(for: settings)
        settings.geminiModel = "gemini-3.5-transcribe"
        XCTAssertGreaterThan(EngineCatalog.assessment(for: settings).accuracy, flash.accuracy)

        settings.provider = .appleSpeech
        XCTAssertEqual(EngineCatalog.assessment(for: settings).accuracy, 1)
    }

    func testEveryDownloadableModelHasAnAssessmentForItsOwnEngine() {
        for provider in [TranscriptionProviderKind.whisper, .parakeet, .nemotron] {
            for model in WhisperModelCatalog.models where model.engine == provider.localEngine {
                let assessment = EngineCatalog.assessment(for: provider, modelID: model.id)
                XCTAssertTrue((1...4).contains(assessment.speed), model.id)
                XCTAssertTrue((2...4).contains(assessment.accuracy), model.id)
                XCTAssertEqual(assessment.note, model.note, "guidance should stay consistent across views")
            }
        }
    }

    func testUnknownModelsDoNotInheritAnEnginesRating() {
        for provider in TranscriptionProviderKind.allCases where provider != .appleSpeech {
            let assessment = EngineCatalog.assessment(for: provider, modelID: "unbenchmarked-model")
            XCTAssertEqual(assessment.speed, 0, provider.rawValue)
            XCTAssertEqual(assessment.accuracy, 0, provider.rawValue)
        }
        XCTAssertEqual(EngineCatalog.assessment(for: .custom, modelID: "gpt-transcribe").accuracy, 0,
                       "a compatible model name says nothing about a custom server")
        XCTAssertEqual(EngineCatalog.assessment(for: .parakeet, modelID: "tiny").accuracy, 0,
                       "a stale model from another engine must not supply its rating")
        XCTAssertEqual(EngineCatalog.assessment(for: .gemini, modelID: "gemini-3.8-flash").accuracy, 0,
                       "audio support alone is not benchmark evidence")
    }

    func testQuantizationAndStreamingDelayDoNotImplyDifferentAccuracy() {
        XCTAssertEqual(
            EngineCatalog.assessment(for: .parakeet, modelID: "parakeet-tdt-0.6b-v3-q8_0").accuracy,
            EngineCatalog.assessment(for: .parakeet, modelID: "parakeet-tdt-0.6b-v3-f16").accuracy)
        XCTAssertEqual(
            EngineCatalog.assessment(for: .whisper, modelID: "large-v3-turbo-q5_0").accuracy,
            EngineCatalog.assessment(for: .whisper, modelID: "large-v3-turbo").accuracy)
        XCTAssertEqual(
            EngineCatalog.assessment(for: .nemotron, modelID: NemotronEngine.modelID).accuracy,
            EngineCatalog.assessment(for: .nemotron, modelID: NemotronEngine.steadyModelID).accuracy)
    }
}
