import AVFoundation
import XCTest
@testable import MicMyDay

/// The import decoder is the wall between a dropped file and the pipeline:
/// whatever passes it is guaranteed to be real audio in the app's own
/// format, so nothing downstream has to wonder what it was handed.
final class AudioImportTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A stereo 44.1 kHz file, the shape most downloads have, comes out as
    /// 16 kHz mono of the same length.
    func testDecodesOrdinaryAudioToTheAppsFormat() throws {
        let source = scratch.appendingPathComponent("stereo.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let frames = AVAudioFrameCount(44_100 * 2)
        // Scoped so the writer closes; AVAudioFile flushes on deallocation,
        // and reading before that sees an empty file.
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            for channel in 0..<2 {
                let data = buffer.floatChannelData![channel]
                for i in 0..<Int(frames) {
                    data[i] = sin(Float(i) * 2 * .pi * 440 / 44_100) * 0.5
                }
            }
            buffer.frameLength = frames
            try file.write(from: buffer)
        }

        let prepared = try AppState.prepareImportedAudio(source)
        defer { try? FileManager.default.removeItem(at: prepared.url) }
        XCTAssertEqual(prepared.seconds, 2, accuracy: 0.05)

        let converted = try AVAudioFile(forReading: prepared.url)
        XCTAssertEqual(converted.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(converted.fileFormat.channelCount, 1)
        let expected = AVAudioFramePosition(16_000 * 2)
        XCTAssertEqual(Double(converted.length), Double(expected), accuracy: 800)
    }

    /// A document dropped by mistake must fail here, on this Mac, rather
    /// than being handed onwards as audio.
    func testRefusesAFileThatIsNotAudio() throws {
        let source = scratch.appendingPathComponent("notes.txt")
        try Data("meeting notes, not audio".utf8).write(to: source)
        XCTAssertThrowsError(try AppState.prepareImportedAudio(source))
    }

    func testRefusesAMissingFile() {
        let source = scratch.appendingPathComponent("gone.wav")
        XCTAssertThrowsError(try AppState.prepareImportedAudio(source))
    }
}
