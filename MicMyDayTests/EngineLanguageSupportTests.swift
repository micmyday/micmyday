import Speech
import XCTest
@testable import MicMyDay

/// Which languages each engine can actually transcribe, and what the app says
/// when the chosen one is not among them.
@MainActor
final class EngineLanguageSupportTests: XCTestCase {
    /// NVIDIA's model card for parakeet-tdt-0.6b-v3 lists 25 European
    /// languages. It takes no language parameter, so this list is the only
    /// thing standing between a user and silence.
    func testParakeetKnowsItsTwentyFiveLanguages() {
        XCTAssertEqual(SpokenLanguageCatalog.parakeetLanguageCodes.count, 25)
        for code in ["en", "de", "fr", "es", "it", "pl", "ru", "uk", "sv", "el"] {
            XCTAssertTrue(SpokenLanguageCatalog.parakeetLanguageCodes.contains(code), code)
        }
    }

    /// The eleven MicMyDay offers that Parakeet cannot do. Somebody who picks
    /// one of these and then chooses Parakeet gets no transcription of what
    /// they said, which is why the pane warns rather than staying silent.
    func testTheLanguagesParakeetCannotDoAreKnown() {
        let unsupported = SpokenLanguageCatalog.all
            .filter { !$0.id.isEmpty && !SpokenLanguageCatalog.parakeetLanguageCodes.contains($0.id) }
            .map(\.id)
            .sorted()
        XCTAssertEqual(unsupported, ["ar", "he", "hi", "id", "ja", "ko", "no", "th", "tr", "vi", "zh"])
    }

    /// Automatic is not a language, so it can never be the unsupported one.
    func testAutomaticIsNeverTreatedAsUnsupported() {
        XCTAssertFalse(SpokenLanguageCatalog.parakeetLanguageCodes.contains(""))
        XCTAssertTrue(SpokenLanguageCatalog.automatic.id.isEmpty)
    }

    /// Every language offered carries what the engines need: an ISO code for
    /// Whisper and the hosted APIs, a regional tag for Apple Speech and
    /// Gemini.
    func testEveryOfferedLanguageCarriesBothForms() {
        for language in SpokenLanguageCatalog.all where !language.id.isEmpty {
            XCTAssertFalse(language.name.isEmpty, language.id)
            XCTAssertFalse(language.regionalTag.isEmpty, "\(language.id) has no regional tag")
            // Usually the tag extends the code, but not always: Norwegian is
            // stored as "no" and spoken as Bokmal, "nb-NO", which is right.
            let related = language.regionalTag.hasPrefix(language.id)
                || (language.id == "no" && language.regionalTag.hasPrefix("nb"))
            XCTAssertTrue(related, "\(language.regionalTag) does not belong to \(language.id)")
        }
    }

    func testMissingGermanDownloadOnlyWarnsWhenLocalRecognitionIsRequired() {
        let installed = [Locale(identifier: "en-US")]
        let germanInstalled = AppleSpeechAvailability.isInstalled(Locale(identifier: "de-DE"), in: installed)
        XCTAssertFalse(germanInstalled)
        XCTAssertEqual(AppleSpeechAvailability.evaluate(
            languageSupported: true, serviceAvailable: true, supportsOnDevice: true,
            installedOnDevice: germanInstalled, preferOnDevice: true
        ), .onDeviceUnavailable)
        XCTAssertEqual(AppleSpeechAvailability.evaluate(
            languageSupported: true, serviceAvailable: true, supportsOnDevice: true,
            installedOnDevice: germanInstalled, preferOnDevice: false
        ), .available)
    }

    func testOnlineOnlyLanguageCanBeUsedWithLocalPreferenceOff() {
        XCTAssertEqual(AppleSpeechAvailability.evaluate(
            languageSupported: true, serviceAvailable: true, supportsOnDevice: false,
            installedOnDevice: false, preferOnDevice: false
        ), .available)
        XCTAssertEqual(AppleSpeechAvailability.evaluate(
            languageSupported: true, serviceAvailable: true, supportsOnDevice: false,
            installedOnDevice: nil, preferOnDevice: true
        ), .onDeviceUnavailable)
    }

    func testServiceAndUnsupportedLanguageWarningsApplyInBothModes() {
        for preferOnDevice in [true, false] {
            XCTAssertEqual(AppleSpeechAvailability.evaluate(
                languageSupported: false, serviceAvailable: true, supportsOnDevice: true,
                installedOnDevice: true, preferOnDevice: preferOnDevice
            ), .unsupportedLanguage)
            XCTAssertEqual(AppleSpeechAvailability.evaluate(
                languageSupported: true, serviceAvailable: false, supportsOnDevice: true,
                installedOnDevice: true, preferOnDevice: preferOnDevice
            ), .serviceUnavailable)
        }
    }

    func testOlderMacOSUsesTheRecognizersLocalCapabilityWhenNoInstalledListExists() {
        XCTAssertEqual(AppleSpeechAvailability.evaluate(
            languageSupported: true, serviceAvailable: true, supportsOnDevice: true,
            installedOnDevice: nil, preferOnDevice: true
        ), .available)
    }

    func testInstalledLocaleMatchingNormalizesScriptsAndSeparatorsButPreservesRegion() {
        XCTAssertTrue(AppleSpeechAvailability.isInstalled(
            Locale(identifier: "de-DE"), in: [Locale(identifier: "de_DE")]))
        XCTAssertTrue(AppleSpeechAvailability.isInstalled(
            Locale(identifier: "zh-CN"), in: [Locale(identifier: "zh-Hans-CN")]))
        XCTAssertFalse(AppleSpeechAvailability.isInstalled(
            Locale(identifier: "en-US"), in: [Locale(identifier: "en-GB")]))
    }

    func testAutomaticChecksTheSameLocaleUsedForRecognition() {
        let germanMac = Locale(identifier: "de-DE")
        XCTAssertEqual(AppleSpeechTranscriber.recognitionLocale(for: "", currentLocale: germanMac), germanMac)
        XCTAssertEqual(AppleSpeechTranscriber.recognitionLocale(for: "en-US", currentLocale: germanMac),
                       Locale(identifier: "en-US"))
    }

    func testAppleLanguagePickerOnlyOffersSupportedCatalogLanguages() {
        let languages = AppleSpeechTranscriber.languageOptions(supportedLocales: [
            Locale(identifier: "en-US"), Locale(identifier: "de-DE"),
            Locale(identifier: "de_DE"), Locale(identifier: "nb-NO"),
            Locale(identifier: "zh-Hans-CN"),
        ])
        XCTAssertEqual(languages.map(\.id), ["", "zh", "en", "de", "no"],
                       "preserve catalog order, normalize locale variants and avoid duplicate choices")
    }

    func testOnlineAndLocalLanguageListsCanDifferWithoutDependingOnDownloads() {
        let online = AppleSpeechTranscriber.languageOptions(supportedLocales: [
            Locale(identifier: "en-US"), Locale(identifier: "de-DE"), Locale(identifier: "fr-FR"),
        ])
        let local = AppleSpeechTranscriber.languageOptions(supportedLocales: [
            Locale(identifier: "en-US"), Locale(identifier: "de-DE"),
        ])
        XCTAssertTrue(online.contains { $0.id == "fr" })
        XCTAssertFalse(local.contains { $0.id == "fr" })
        XCTAssertTrue(local.contains { $0.id == "de" }, "supported German stays selectable before download")
        XCTAssertEqual(AppleSpeechAvailability.evaluate(
            languageSupported: true, serviceAvailable: true, supportsOnDevice: true,
            installedOnDevice: false, preferOnDevice: true
        ), .onDeviceUnavailable, "missing downloads are handled by the warning, not the supported-language filter")
    }

    func testEmptyAppleLanguageListKeepsAutomaticWithoutOfferingOtherLanguages() {
        XCTAssertEqual(AppleSpeechTranscriber.languageOptions(supportedLocales: []), [SpokenLanguageCatalog.automatic])
    }

    func testAppleLanguagePickerDoesNotOfferAnUnsupportedRegionalVariant() {
        let languages = AppleSpeechTranscriber.languageOptions(supportedLocales: [Locale(identifier: "en-GB")])
        XCTAssertFalse(languages.contains { $0.id == "en" }, "the catalog's English choice requests en-US")
    }
}
