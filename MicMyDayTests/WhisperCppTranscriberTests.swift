import AVFoundation
import XCTest
@testable import MicMyDay

final class WhisperCppTranscriberTests: XCTestCase {
    func testCatalogContainsDefaultModel() {
        XCTAssertNotNil(WhisperModelCatalog.model(withID: WhisperModelCatalog.defaultModelID))
        for model in WhisperModelCatalog.models {
            // The Core ML model is fetched by its own package, not by file
            // name; its URL is the model's page rather than a download.
            guard model.engine != .nemotron else { continue }
            XCTAssertTrue(model.downloadURL.absoluteString.hasSuffix("\(model.fileName)"))
        }
    }

    func testConvertsStereoRecordingTo16kHzMono() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("micmyday-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: source) }

        let seconds = 2.0
        // Scoped so the AVAudioFile writer deallocates and flushes before reading.
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let frames = AVAudioFrameCount(48_000 * seconds)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for channel in 0 ..< 2 {
                for frame in 0 ..< Int(frames) {
                    buffer.floatChannelData![channel][frame] = sinf(Float(frame) * 2 * .pi * 440 / 48_000) * 0.25
                }
            }
            try file.write(from: buffer)
        }

        let samples = try WhisperCppTranscriber.monoSamples16kHz(from: source)
        let expected = Int(WhisperCppTranscriber.requiredSampleRate * seconds)
        XCTAssertEqual(Double(samples.count), Double(expected), accuracy: Double(expected) * 0.01)
        XCTAssertTrue(samples.contains { abs($0) > 0.01 }, "Converted audio should not be silent")
    }

    func testTranscribesSynthesizedSpeechWithTinyModel() async throws {
        try await assertTranscribesSynthesizedSpeech(modelID: "tiny.en", language: "en")
    }

    func testTranscribesSynthesizedSpeechWithParakeet() async throws {
        try await assertTranscribesSynthesizedSpeech(modelID: "parakeet-tdt-0.6b-v3-q8_0", language: "")
    }

    private func assertTranscribesSynthesizedSpeech(modelID: String, language: String) async throws {
        guard let modelURL = WhisperModelManager.localURL(forModelID: modelID),
              FileManager.default.fileExists(atPath: modelURL.path)
        else {
            throw XCTSkip("Model \(modelID) is not downloaded; skipping local inference test.")
        }

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("micmyday-say-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        // A named voice, not the default one. The default is whatever the Mac
        // running this happens to be set to, and a voice that is selected but
        // not downloaded synthesizes silence without failing: `say` exits 0 and
        // writes a file a few milliseconds long. The engine then transcribes
        // nothing, correctly, and the test blamed the engine.
        say.arguments = [
            "-v", "Albert",
            "-o", audioURL.path,
            "--data-format=LEI16@22050",
            "The quick brown fox jumps over the lazy dog.",
        ]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0)

        // Whether there is any speech to transcribe is a question about this
        // machine, so it decides whether the test can run, not whether it
        // passes. Half a second of audio cannot hold the sentence.
        let spokenFrames = try AVAudioFile(forReading: audioURL).length
        let spokenSeconds = Double(spokenFrames) / 22_050
        guard spokenSeconds > 0.5 else {
            throw XCTSkip("""
                macOS synthesized \(String(format: "%.3f", spokenSeconds))s of audio for a full sentence, \
                so there is nothing to transcribe. The selected voice is probably not downloaded.
                """)
        }

        let configuration = TranscriptionConfiguration(
            provider: .whisper,
            baseURL: "",
            model: modelID,
            apiKey: "",
            language: language,
            prompt: "",
            preferOnDevice: true,
            localModelURL: modelURL
        )
        let transcript = try await WhisperCppTranscriber().transcribe(fileURL: audioURL, configuration: configuration)
        XCTAssertTrue(
            transcript.lowercased().contains("quick brown fox"),
            "Unexpected transcript from \(modelID): \(transcript)"
        )
    }
}
