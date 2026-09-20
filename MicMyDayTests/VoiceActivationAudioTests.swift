import AVFoundation
import XCTest
@testable import MicMyDay

/// Pins the buffer handling behind voice activation. Both of these were broken
/// in ways that only show on real hardware: interleaved input, and microphones
/// wired to a channel other than the first.
final class VoiceActivationAudioTests: XCTestCase {
    private func buffer(
        format: AVAudioFormat,
        frames: AVAudioFrameCount,
        fill: (AVAudioPCMBuffer) -> Void
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        fill(buffer)
        return buffer
    }

    func testInterleavedCopyPreservesEverySample() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 2, interleaved: true
        )!
        let source = buffer(format: format, frames: 4) { b in
            let p = b.floatChannelData![0]
            for i in 0 ..< 8 { p[i] = Float(i + 1) }   // 1...8 interleaved L,R
        }

        let copy = try XCTUnwrap(VoiceActivationListener.copyForTesting(source))
        XCTAssertEqual(copy.frameLength, 4)
        let copied = copy.floatChannelData![0]
        // The old implementation produced [1,2,3,4,5,0,0,0].
        XCTAssertEqual((0 ..< 8).map { copied[$0] }, [1, 2, 3, 4, 5, 6, 7, 8])
    }

    func testNonInterleavedCopyPreservesBothChannels() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 2, interleaved: false
        )!
        let source = buffer(format: format, frames: 3) { b in
            for frame in 0 ..< 3 {
                b.floatChannelData![0][frame] = 0.5
                b.floatChannelData![1][frame] = -0.5
            }
        }
        let copy = try XCTUnwrap(VoiceActivationListener.copyForTesting(source))
        XCTAssertEqual((0 ..< 3).map { copy.floatChannelData![0][$0] }, [0.5, 0.5, 0.5])
        XCTAssertEqual((0 ..< 3).map { copy.floatChannelData![1][$0] }, [-0.5, -0.5, -0.5])
    }

    func testSpeechOnASecondChannelIsHeard() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 2, interleaved: true
        )!
        // Channel 0 silent, channel 1 loud: a mic on input 2 of an interface.
        let b = buffer(format: format, frames: 64) { b in
            let p = b.floatChannelData![0]
            for frame in 0 ..< 64 {
                p[frame * 2] = 0
                p[frame * 2 + 1] = 0.6
            }
        }
        // Previously 0, so voice activation never triggered on such a device.
        XCTAssertGreaterThan(VoiceActivationListener.rmsForTesting(b), 0.3)
    }

    func testIntegerFormatsAreMeasuredNotIgnored() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
        )!
        let b = buffer(format: format, frames: 32) { b in
            let p = b.int16ChannelData![0]
            for frame in 0 ..< 32 { p[frame] = Int16.max / 2 }
        }
        // Previously 0 for every integer buffer.
        XCTAssertGreaterThan(VoiceActivationListener.rmsForTesting(b), 0.4)
    }

    func testSilenceMeasuresZero() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        )!
        let b = buffer(format: format, frames: 32) { b in
            for frame in 0 ..< 32 { b.floatChannelData![0][frame] = 0 }
        }
        XCTAssertEqual(VoiceActivationListener.rmsForTesting(b), 0, accuracy: 0.0001)
    }
}
