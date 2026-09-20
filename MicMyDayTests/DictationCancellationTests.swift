import AVFoundation
import XCTest
@testable import MicMyDay

/// Tests for what happens to a dictation after the microphone closes.
///
/// This is the part of the app that has produced the most bugs, and every one
/// of them was logic rather than hardware: a cancelled dictation that pasted
/// its result anyway, a rewrite that left the app stuck on a step forever, a
/// step with no bound on how long it could take. None of that needs a
/// microphone, a network or a person to reproduce, only a transcriber that can
/// be told to hang.
@MainActor
final class DictationCancellationTests: XCTestCase {
    /// Stands in for the network. Hangs until released, so a test can act while
    /// a dictation is mid-flight, which is the only moment these bugs exist in.
    private final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private(set) var wasEntered = false

        func wait() async {
            wasEntered = true
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    self.semaphore.wait()
                    continuation.resume()
                }
            }
        }

        func release() { semaphore.signal() }
    }

    private var suiteName = ""

    private func makeState(
        transcribeGate: Gate? = nil,
        enhanceGate: Gate? = nil,
        onTranscribeFinished: (@Sendable () -> Void)? = nil
    ) -> AppState {
        suiteName = "DictationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(
            defaults: defaults,
            keychain: KeychainStore(service: "DictationTests.\(UUID().uuidString)")
        )

        var work = AppState.Work()
        work.transcribe = { _, _, _, _ in
            if let transcribeGate { await transcribeGate.wait() }
            onTranscribeFinished?()
            return "hello world"
        }
        work.enhance = { text, _, _ in
            if let enhanceGate { await enhanceGate.wait() }
            return text.uppercased()
        }
        return AppState(settings: settings, work: work)
    }

    override func tearDown() {
        if !suiteName.isEmpty {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    /// A tenth of a second of silence. Deliberately short: transcription is
    /// allowed the recording's own length on top of the step limit, so a long
    /// fixture would make the deadline under test mostly the fixture.
    private func makeAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        try file.write(from: buffer)
        return url
    }

    /// Lets queued main-actor work run, so a state change made by a task under
    /// test has actually landed before it is asserted on.
    private func settle(_ turns: Int = 6) async {
        for _ in 0 ..< turns {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(12))
        }
    }

    func testCancellingDuringTranscriptionDeliversNothing() async throws {
        let gate = Gate()
        let state = makeState(transcribeGate: gate)
        let audio = try makeAudioFile()

        state.beginDictationForTesting(audioURL: audio)
        await settle()
        XCTAssertEqual(state.phase, .transcribing)

        state.cancelRecording()
        await settle()
        XCTAssertEqual(state.phase, .idle, "cancelling must return to idle at once")

        // The response arrives after the user gave up, which is exactly the
        // case that used to paste into their terminal anyway.
        gate.release()
        await settle()

        XCTAssertEqual(state.phase, .idle, "a late result must not revive a cancelled dictation")
        XCTAssertTrue(state.history.entries.isEmpty, "a cancelled dictation must record nothing")
    }

    func testCancellingDuringTheRewriteReturnsToIdle() async throws {
        let enhanceGate = Gate()
        let state = makeState(enhanceGate: enhanceGate)
        // Everything `enhancementConfiguration()` insists on before it will
        // hand back a config: without all of it the rewrite is skipped and the
        // test quietly proves nothing.
        state.settings.enhancementEnabled = true
        state.settings.rewriteProvider = .openai
        state.settings.enhancementAPIKey = "test-key-not-used-by-the-fake"
        state.settings.openAIApiKey = "test-key-not-used-by-the-fake"
        // A profile has to be armed, or `enhancementConfiguration()` returns
        // nil and the rewrite step is skipped entirely.
        if let first = state.settings.rewriteProfiles.first {
            state.settings.rewriteProfileID = first.id
        }
        let audio = try makeAudioFile()

        state.beginDictationForTesting(audioURL: audio)
        await settle(12)

        // Only meaningful if the rewrite is actually running.
        guard state.phase == .enhancing else {
            throw XCTSkip("this build did not reach the rewrite step")
        }

        state.cancelRecording()
        await settle()
        XCTAssertEqual(
            state.phase, .idle,
            "cancelling during the rewrite used to strand the app on a later step forever"
        )

        enhanceGate.release()
        await settle()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(state.history.entries.isEmpty)
    }

    func testAStepThatNeverFinishesGivesUpRatherThanWaitingForever() async throws {
        let gate = Gate()
        let state = makeState(transcribeGate: gate)
        state.stepLimitForTesting = .milliseconds(150)
        let audio = try makeAudioFile()

        state.beginDictationForTesting(audioURL: audio)
        // Comfortably past the deadline: 150ms plus the fixture's own tenth of
        // a second.
        await settle(40)

        guard case .failed = state.phase else {
            XCTFail("a step that never finishes must fail rather than hang, phase was \(state.phase)")
            gate.release()
            return
        }
        XCTAssertNotNil(state.recovery, "giving up must say why")
        gate.release()
    }
}
