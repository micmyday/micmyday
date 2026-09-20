import AVFoundation
import XCTest
@testable import MicMyDay

/// Exploration, not regression: feeds Parakeet controlled audio — silence,
/// noise, a lone word — and prints what it invents, so the transcript
/// cleaner's rules are shaped by measured behaviour rather than guesses.
/// Skips itself unless the probe model path is provided.
final class ParakeetSilenceProbeTests: XCTestCase {
    private var modelPath: String {
        ProcessInfo.processInfo.environment["MICMYDAY_PROBE_MODEL"] ?? ""
    }

    func testProbeRealisticAudio() async throws {
        guard !modelPath.isEmpty, FileManager.default.fileExists(atPath: modelPath) else {
            throw XCTSkip("No probe model provided.")
        }
        guard let dir = ProcessInfo.processInfo.environment["MICMYDAY_PROBE_DIR"],
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir)
        else {
            throw XCTSkip("No probe directory provided.")
        }
        for file in files.sorted() where file.hasSuffix(".wav") {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(file)
            do {
                let samples = try WhisperCppTranscriber.monoSamples16kHz(from: url)
                let result = try await WhisperCppEngine.shared.transcribe(
                    samples: samples,
                    modelPath: modelPath,
                    engine: .parakeet,
                    language: "",
                    prompt: ""
                )
                print("PROBE[\(file)]: \"\(result.text)\"")
            } catch {
                print("PROBE[\(file)]: ERROR \(error)")
            }
        }
    }

    func testProbeSilenceAndNoise() async throws {
        guard !modelPath.isEmpty, FileManager.default.fileExists(atPath: modelPath) else {
            throw XCTSkip("No probe model provided.")
        }

        var cases: [(name: String, samples: [Float])] = []
        cases.append(("silence 1s", [Float](repeating: 0, count: 16_000)))
        cases.append(("silence 3s", [Float](repeating: 0, count: 48_000)))
        cases.append(("silence 10s", [Float](repeating: 0, count: 160_000)))

        var generator = SystemRandomNumberGenerator()
        func noise(_ seconds: Double, amplitude: Float) -> [Float] {
            (0..<Int(seconds * 16_000)).map { _ in
                (Float(UInt32.random(in: 0...1_000_000, using: &generator)) / 500_000 - 1) * amplitude
            }
        }
        cases.append(("faint noise 3s (-52dB)", noise(3, amplitude: 0.0025)))
        cases.append(("room noise 3s (-40dB)", noise(3, amplitude: 0.01)))
        cases.append(("loud noise 3s (-20dB)", noise(3, amplitude: 0.1)))

        // A short tone burst then long silence, approximating one word then
        // a pause.
        var toneThenSilence = (0..<8_000).map { index -> Float in
            let t = Float(index) / 16_000
            return sin(2 * .pi * 220 * t) * sin(2 * .pi * 3 * t) * 0.3
        }
        toneThenSilence.append(contentsOf: [Float](repeating: 0, count: 112_000))
        cases.append(("tone 0.5s then silence 7s", toneThenSilence))

        for (name, samples) in cases {
            do {
                let result = try await WhisperCppEngine.shared.transcribe(
                    samples: samples,
                    modelPath: modelPath,
                    engine: .parakeet,
                    language: "",
                    prompt: ""
                )
                print("PROBE[\(name)]: \"\(result.text)\"")
            } catch {
                print("PROBE[\(name)]: ERROR \(error)")
            }
        }
    }
}
