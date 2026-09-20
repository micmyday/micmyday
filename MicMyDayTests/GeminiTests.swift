import AVFoundation
import XCTest
@testable import MicMyDay

final class GeminiTests: XCTestCase {
    override func tearDown() {
        GeminiTestURLProtocol.handler = nil
        super.tearDown()
    }

    func testFilterIncludesMultimodalAndSpeechModelsAndDeduplicatesResourceNames() {
        let models = GeminiModelCatalog.transcriptionModels(in: [
            "models/gemini-2.5-flash", "gemini-3.8-flash", "models/gemini-3.5-transcribe",
            "gemini-2.5-flash", "gemini-3.5-flash-lite",
        ])
        XCTAssertEqual(models.map(\.id), [
            "gemini-3.5-transcribe", "gemini-3.5-flash-lite", "gemini-3.8-flash", "gemini-2.5-flash",
        ])
    }

    func testFilterExcludesUnsupportedTransportsAndNeverFallsBackToUnfilteredModels() {
        let unsupported = [
            "gemini-3.5-transcribe-live", "gemini-2.5-flash-native-audio-preview-12-2025",
            "gemini-2.5-flash-preview-tts", "gemini-3.1-flash-tts-preview",
            "gemini-3.1-flash-image", "gemini-3-pro-image", "gemini-embedding-001",
            "gemma-4-31b-it", "gemini-99-flash", "gemini-3.8-flash-image", "unknown-transcribe",
        ]
        XCTAssertTrue(GeminiModelCatalog.transcriptionModels(in: unsupported).isEmpty)
        XCTAssertTrue(GeminiModelCatalog.transcriptionModels(in: []).isEmpty)
    }

    func testModelDiscoveryUsesNativeAPIAndFiltersEveryPage() async throws {
        var pages = 0
        GeminiTestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "generativelanguage.googleapis.com")
            XCTAssertEqual(request.url?.path, "/v1beta/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertFalse(query.contains { $0.name == "key" })
            pages += 1
            if pages == 1 {
                XCTAssertFalse(query.contains { $0.name == "pageToken" })
                return (200, #"{"models":[{"name":"models/gemini-3.1-flash-tts-preview"}],"nextPageToken":"page/+2"}"#)
            }
            XCTAssertEqual(query.first { $0.name == "pageToken" }?.value, "page/+2")
            return (200, #"{"models":[{"name":"models/gemini-3.8-flash"},{"name":"models/gemini-3.5-transcribe"}]}"#)
        }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let models = try await GeminiModelCatalog.fetchModels(apiKey: " test-key\n", session: session)
        XCTAssertEqual(models.map(\.id), ["gemini-3.5-transcribe", "gemini-3.8-flash"])
        XCTAssertEqual(pages, 2)
    }

    func testModelDiscoveryStopsOnRepeatedPageTokens() async throws {
        GeminiTestURLProtocol.handler = { _ in (200, #"{"models":[],"nextPageToken":"same"}"#) }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await GeminiModelCatalog.fetchModels(apiKey: "test-key", session: session)
            XCTFail("Expected an invalid pagination response")
        } catch TranscriptionError.invalidResponse { }
    }

    func testGoogleErrorsPreserveStatusAndMessage() async throws {
        GeminiTestURLProtocol.handler = { _ in (429, #"{"error":{"message":"Quota exceeded"}}"#) }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await GeminiModelCatalog.fetchModels(apiKey: "test-key", session: session)
            XCTFail("Expected quota error")
        } catch TranscriptionError.server(let status, let message) {
            XCTAssertEqual(status, 429)
            XCTAssertEqual(message, "Quota exceeded")
        }
    }

    func testSpeechRequestPreservesLanguageAndVocabularyWithoutEnablingCleanupOrStorage() throws {
        let request = try GeminiTranscriber.request(audio: Data([1, 2, 3]), configuration: configuration(language: "de_DE", prompt: "MicMyDay, Kubernetes\nSwiftUI"))
        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/interactions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
        let body = try jsonBody(request)
        XCTAssertEqual(body["model"] as? String, "gemini-3.5-transcribe")
        XCTAssertEqual(body["store"] as? Bool, false)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"] as? String, "audio")
        XCTAssertEqual(input[0]["mime_type"] as? String, "audio/m4a")
        XCTAssertEqual(input[0]["data"] as? String, "AQID")
        let generation = try XCTUnwrap(body["generation_config"] as? [String: Any])
        let transcription = try XCTUnwrap(generation["transcription_config"] as? [String: Any])
        XCTAssertEqual(transcription["mode"] as? [String: String], ["type": "verbatim"])
        XCTAssertEqual(transcription["language_codes"] as? [String], ["de-DE"])
        XCTAssertEqual(transcription["custom_vocabulary"] as? [String], ["MicMyDay", "Kubernetes", "SwiftUI"])
    }

    func testAutomaticLanguageDetectionOmitsLanguageAndEmptyVocabulary() throws {
        let body = try jsonBody(GeminiTranscriber.request(audio: Data([1]), configuration: configuration()))
        let generation = try XCTUnwrap(body["generation_config"] as? [String: Any])
        let transcription = try XCTUnwrap(generation["transcription_config"] as? [String: Any])
        XCTAssertNil(transcription["language_codes"])
        XCTAssertNil(transcription["custom_vocabulary"])
    }

    func testMultimodalRequestUsesTranscriptionInstructionsAndAudio() throws {
        let body = try jsonBody(GeminiTranscriber.request(audio: Data([1]), configuration: configuration(model: "gemini-3.8-flash", language: "en", prompt: "MicMyDay")))
        XCTAssertNil(body["generation_config"])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 2)
        XCTAssertEqual(input[0]["type"] as? String, "text")
        let prompt = try XCTUnwrap(input[0]["text"] as? String)
        XCTAssertTrue(prompt.contains("Do not translate"))
        XCTAssertTrue(prompt.contains("Expected spoken language: en"))
        XCTAssertTrue(prompt.contains("MicMyDay"))
        XCTAssertEqual(input[1]["type"] as? String, "audio")
    }

    func testInvalidKeysModelsAudioAndOversizedRequestsAreRejectedBeforeSending() {
        XCTAssertThrowsError(try GeminiTranscriber.request(audio: Data([1]), configuration: configuration(apiKey: " \n")))
        XCTAssertThrowsError(try GeminiTranscriber.request(audio: Data([1]), configuration: configuration(model: "gemini-3.5-transcribe-live")))
        XCTAssertThrowsError(try GeminiTranscriber.request(audio: Data(), configuration: configuration()))
        XCTAssertThrowsError(try GeminiTranscriber.request(audio: Data(repeating: 0, count: 15_000_000), configuration: configuration()))
    }

    func testResponseOnlyReturnsCompletedModelText() throws {
        let response = #"{"status":"completed","steps":[{"type":"user_input","content":[{"type":"text","text":"Do not paste the prompt"}]},{"type":"model_output","content":[{"type":"thought","text":"Do not paste thoughts"},{"type":"text","text":"  Guten Morgen."},{"type":"text","text":"Hello.  "}]}]}"#
        XCTAssertEqual(try GeminiTranscriber.transcript(from: Data(response.utf8)), "Guten Morgen.\nHello.")
        XCTAssertThrowsError(try GeminiTranscriber.transcript(from: Data(#"{"status":"failed","steps":[{"type":"model_output","content":[{"type":"text","text":"Partial"}]}]}"#.utf8)))
        XCTAssertThrowsError(try GeminiTranscriber.transcript(from: Data(#"{"status":"completed","steps":[]}"#.utf8)))
        XCTAssertThrowsError(try GeminiTranscriber.transcript(from: Data(#"{"error":{"message":"Do not paste JSON"}}"#.utf8)))
    }

    func testRecordedStereoWAVIsConvertedAndTranscribedThroughNativeTransport() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("GeminiTests-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try writeAudioFixture(to: file)
        GeminiTestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1beta/interactions")
            let body = try self.jsonBody(request)
            let input = try XCTUnwrap(body["input"] as? [[String: Any]])
            let encoded = try XCTUnwrap(input.first?["data"] as? String)
            let audio = try XCTUnwrap(Data(base64Encoded: encoded))
            XCTAssertGreaterThan(audio.count, 16)
            XCTAssertEqual(String(data: audio.subdata(in: 4..<8), encoding: .ascii), "ftyp")
            return (200, #"{"status":"completed","steps":[{"type":"model_output","content":[{"type":"text","text":"Fixture transcript."}]}]}"#)
        }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let result = try await GeminiTranscriber(session: session).transcribe(fileURL: file, configuration: configuration())
        XCTAssertEqual(result, "Fixture transcript.")
    }

    @MainActor
    func testGeminiSettingsPersistAndUseSeparateKeychainCredentialsAndAudioConsent() throws {
        let suite = "GeminiSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let keychain = KeychainStore(service: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? keychain.set("", account: "gemini-api-key")
        }
        let settings = SettingsStore(defaults: defaults, keychain: keychain)
        settings.provider = .gemini
        settings.geminiAPIKey = "test-key"
        settings.geminiModel = "gemini-3.8-flash"
        let config = settings.transcriptionConfiguration()
        XCTAssertEqual(config.baseURL, GeminiAPI.baseURL)
        XCTAssertEqual(config.apiKey, "test-key")
        XCTAssertEqual(config.model, "gemini-3.8-flash")
        XCTAssertFalse(config.preferOnDevice)
        XCTAssertNil(defaults.object(forKey: "geminiAPIKey"))
        XCTAssertNil(try keychain.get(account: "rewrite-gemini-api-key"))
        let reloaded = SettingsStore(defaults: defaults, keychain: keychain)
        XCTAssertEqual(reloaded.provider, .gemini)
        XCTAssertEqual(reloaded.geminiModel, "gemini-3.8-flash")
        XCTAssertEqual(reloaded.geminiAPIKey, "test-key")
        let consent = try XCTUnwrap(DataSharingRequest.transcription(config))
        XCTAssertEqual(consent.recipient, GeminiAPI.baseURL)
        XCTAssertEqual(consent.content, .audio)
        XCTAssertNotNil(EngineCatalog.description(for: .gemini))
    }

    private func configuration(model: String = "gemini-3.5-transcribe", apiKey: String = "test-key", language: String = "", prompt: String = "") -> TranscriptionConfiguration {
        TranscriptionConfiguration(provider: .gemini, baseURL: GeminiAPI.baseURL, model: model, apiKey: apiKey, language: language, prompt: prompt, preferOnDevice: false)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func writeAudioFixture(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            for sample in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][sample] = sin(Float(sample) * 2 * .pi * 440 / 48_000) * 0.1
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

private final class GeminiTestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
