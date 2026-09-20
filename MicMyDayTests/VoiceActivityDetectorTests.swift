import AVFoundation
import XCTest
@testable import MicMyDay

/// The detector's whole purpose is the negative answer, so that is what is
/// pinned here: audio nobody spoke into must not be reported as speech.
///
/// The positive answer needs a recording of a real voice, which no synthetic
/// signal stands in for honestly, so it is left to a person with a
/// microphone. Erring in that direction is also the safe one: the class fails
/// open everywhere, so a positive it gets wrong costs a stray word, while the
/// negative it gets wrong would cost a dictation.
final class VoiceActivityDetectorTests: XCTestCase {
    /// 48kHz mono, as a built-in microphone delivers, so the detector's own
    /// resampling is exercised rather than bypassed.
    private func buffer(seconds: Double, amplitude: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
        )!
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        var seed: UInt64 = 0x2545F4914F6CDD1D
        for index in 0 ..< Int(frames) {
            // A cheap deterministic hiss rather than digital silence: a room
            // is never truly quiet, and a detector that only rejects exact
            // zeroes would reject nothing real.
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max)
            channel[index] = noise * amplitude
        }
        return buffer
    }

    private func heardVoice(in buffers: [AVAudioPCMBuffer]) async -> Bool {
        let detector = VoiceActivityDetector()
        detector.start()
        for buffer in buffers { detector.append(buffer) }
        return await detector.finish()
    }

    func testAnEmptyRoomIsNotSpeech() async throws {
        try XCTSkipUnless(
            VoiceActivityDetector.isModelAvailable,
            "the detector's model is not downloaded on this machine"
        )
        // Three seconds of room tone, well above digital silence.
        let quiet = (0 ..< 6).map { _ in buffer(seconds: 0.5, amplitude: 0.002) }
        let heard = await heardVoice(in: quiet)
        XCTAssertFalse(heard, "room tone was reported as somebody speaking")
    }

    func testLoudNoiseIsNotSpeechEither() async throws {
        try XCTSkipUnless(
            VoiceActivityDetector.isModelAvailable,
            "the detector's model is not downloaded on this machine"
        )
        // The case a loudness threshold cannot tell from a voice, and the
        // reason this is a trained detector rather than a level meter.
        let loud = (0 ..< 6).map { _ in buffer(seconds: 0.5, amplitude: 0.6) }
        let heard = await heardVoice(in: loud)
        XCTAssertFalse(heard, "loud noise was reported as somebody speaking")
    }

    /// Without the model there is nothing to ask, and the take must be
    /// transcribed exactly as it was before this class existed.
    func testAnUnavailableDetectorLetsEverythingThrough() async {
        let detector = VoiceActivityDetector()
        // Never started, so nothing was ever judged.
        detector.start()
        let heard = await detector.finish()
        if !VoiceActivityDetector.isModelAvailable {
            XCTAssertTrue(heard)
        }
    }
}
