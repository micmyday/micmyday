import XCTest
@testable import MicMyDay

/// The Engine pane offers a language picker; these pin the per-engine code
/// mapping behind it, since the engines disagree about the format.
final class LanguageNormalizationTests: XCTestCase {
    @MainActor
    private func language(_ stored: String, provider: TranscriptionProviderKind) -> String {
        let name = "LanguageNormalizationTests"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(
            defaults: defaults,
            keychain: KeychainStore(service: "LanguageNormalizationTests.\(UUID().uuidString)")
        )
        settings.provider = provider
        settings.language = stored
        return settings.transcriptionConfiguration().language
    }

    @MainActor
    func testAutomaticSendsNothingSoEnginesDetect() {
        for provider in TranscriptionProviderKind.allCases {
            XCTAssertEqual(language("", provider: provider), "", "\(provider) should auto-detect")
        }
    }

    @MainActor
    func testEnginesThatRejectARegionGetTheBaseCode() {
        // whisper_lang_id("de-DE") is -1, and the OpenAI-style multipart APIs
        // document a plain language code.
        XCTAssertEqual(language("de", provider: .whisper), "de")
        XCTAssertEqual(language("de", provider: .openAI), "de")
        XCTAssertEqual(language("de", provider: .custom), "de")
    }

    @MainActor
    func testGeminiAndAppleSpeechGetAFullBCP47Tag() {
        XCTAssertEqual(language("de", provider: .gemini), "de-DE")
        XCTAssertEqual(language("de", provider: .appleSpeech), "de-DE")
        XCTAssertEqual(language("pt", provider: .gemini), "pt-PT")
    }

    @MainActor
    func testStoredValuesFromOlderBuildsStillResolve() {
        // The field used to be free text, so anything could be on disk.
        XCTAssertEqual(language("de_DE", provider: .gemini), "de-DE")
        XCTAssertEqual(language("EN ", provider: .openAI), "en")
        XCTAssertEqual(language("de-DE", provider: .whisper), "de")
    }

    @MainActor
    func testUnknownCodesFallBackToAutomaticRatherThanBreakingAnEngine() {
        XCTAssertEqual(language("German", provider: .whisper), "")
        XCTAssertEqual(language("xx", provider: .gemini), "")
    }

    func testCatalogIsWellFormed() {
        let all = SpokenLanguageCatalog.all
        XCTAssertEqual(all.first?.id, "", "Automatic must be first")
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "ids must be unique")
        for entry in all.dropFirst() {
            XCTAssertFalse(entry.id.isEmpty)
            XCTAssertTrue(entry.regionalTag.hasPrefix(entry.id + "-") || entry.regionalTag.hasPrefix("nb-"),
                          "\(entry.id): regional tag \(entry.regionalTag) should extend the base code")
        }
    }
}
