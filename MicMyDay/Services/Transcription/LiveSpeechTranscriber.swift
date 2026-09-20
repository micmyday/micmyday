import AVFoundation
import Foundation
import OSLog
import Speech

/// Transcribes while the user is still speaking, rather than after they stop.
///
/// Everything else in the app records to a file and transcribes it once the
/// recording ends, which is the only thing most engines allow: they take a
/// complete recording. Apple's recogniser also accepts a live stream and
/// reports the text as it forms, which is the difference between watching words
/// appear and watching a spinner.
///
/// It runs *alongside* the file recording rather than instead of it. The file
/// is still written, so if recognition fails, is unavailable, or returns
/// nothing, the dictation falls back to transcribing the recording in the
/// ordinary way and the user loses nothing but the live display.
final class LiveSpeechTranscriber: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.micmyday.app", category: "LiveSpeech")

    /// Text so far, delivered as the recogniser revises it.
    ///
    /// Each call carries the whole transcript rather than a delta, because the
    /// recogniser revises what it has already said: "to" becomes "two" becomes
    /// "too" as more context arrives, and a delta cannot express that.
    private let onPartial: @Sendable (String) -> Void

    private let recognizer: SFSpeechRecognizer
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private let lock = NSLock()
    private var latest = ""
    private var finished = false
    /// Set when `finish()` closes the stream. A final result that arrives
    /// before this is the recogniser giving up early — Apple's has a hard
    /// one-minute ceiling — and what it has then is a prefix of a dictation
    /// that is still going, not the dictation.
    private var audioEnded = false
    private var finalizedEarly = false
    private var finalContinuation: CheckedContinuation<String, Never>?

    /// Nil when this Mac cannot do it: no recogniser for the language, or
    /// on-device recognition was required and is not available. The caller
    /// carries on without live text rather than failing the dictation.
    init?(
        language: String,
        preferOnDevice: Bool,
        contextualStrings: [String],
        onPartial: @escaping @Sendable (String) -> Void
    ) {
        let locale = language.isEmpty ? Locale.current : Locale(identifier: language)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            return nil
        }
        if preferOnDevice, !recognizer.supportsOnDeviceRecognition { return nil }
        self.recognizer = recognizer
        self.onPartial = onPartial

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = preferOnDevice
        request.contextualStrings = contextualStrings
        self.request = request
    }

    /// Begins recognising. Buffers handed to `append` from this point are
    /// transcribed as they arrive.
    func start() {
        guard let request else { return }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.lock.lock()
                self.latest = text
                self.lock.unlock()
                self.onPartial(text)
                if result.isFinal {
                    self.lock.lock()
                    let early = !self.audioEnded
                    if early { self.finalizedEarly = true }
                    self.lock.unlock()
                    self.settle(early ? "" : text)
                }
            }
            if let error {
                // Everything heard so far is thrown away deliberately. The
                // recogniser stopped part way, so what it has is the beginning
                // of a sentence, and returning it would suppress transcribing
                // the recording and lose the rest of what the user said. An
                // empty result sends the dictation down the ordinary path,
                // where the whole recording is transcribed.
                Self.logger.notice("live recognition failed, falling back to the recording: \(error.localizedDescription, privacy: .public)")
                self.settle("")
            }
        }
    }

    /// Feeds one captured buffer. Called on the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let stopped = finished
        lock.unlock()
        guard !stopped else { return }
        request?.append(buffer)
    }

    /// Closes the stream and waits for the recogniser's last word.
    ///
    /// Returns what it has either way. A recogniser that never reports a final
    /// result must not hold up the dictation, so the text it had already given
    /// is used: it is the same words, just without the last revision.
    func finish() async -> String {
        // Taken in a non-async helper: holding an NSLock across a suspension
        // point is unsound, and Swift 6 makes it an error.
        lock.lock()
        audioEnded = true
        lock.unlock()
        if let already = textIfFinished() { return already }
        request?.endAudio()
        return await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                let text = latest
                lock.unlock()
                continuation.resume(returning: text)
                return
            }
            finalContinuation = continuation
            lock.unlock()
        }
    }

    /// `finish()`, but giving up after `limit` rather than waiting forever.
    ///
    /// The recogniser normally reports a final result within a moment of the
    /// audio ending. Normally is not always, and a dictation cannot be left
    /// open on the strength of it: this is a bound on a wait, not an ordering.
    /// What it has already said is the same words without the last revision.
    func finishOrGiveUp(after limit: Duration) async -> String {
        await withTaskGroup(of: String.self) { group in
            group.addTask { await self.finish() }
            group.addTask {
                do {
                    try await Task.sleep(for: limit)
                } catch {
                    // The wait was cancelled — Escape, not a stalled
                    // recogniser. The words it already produced are complete
                    // up to the last revision and must survive for
                    // insert-again; settling empty here blanked them an
                    // instant before the caller tried to preserve them.
                    let text = self.currentText
                    self.settle(text)
                    return text
                }
                // Elapsed, deliberately empty: what a recogniser has when it
                // STALLS is the beginning of a sentence, and returning it
                // would suppress transcribing the recording and lose the rest.
                // Releases the other task's continuation too, so nothing is
                // left suspended holding the recogniser alive.
                self.settle("")
                return ""
            }
            let first = await group.next() ?? ""
            group.cancelAll()
            return first
        }
    }

    /// Abandons recognition without waiting, for a cancelled dictation.
    func cancel() {
        settle(currentText)
        task?.cancel()
    }

    private func textIfFinished() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard finished else { return nil }
        // Settled before the audio ended: whatever it holds is a prefix, and
        // returning it would suppress transcribing the recording that holds
        // the rest. Empty sends the caller down the ordinary path.
        return finalizedEarly ? "" : latest
    }

    var currentText: String {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    private func settle(_ text: String) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        latest = text
        let continuation = finalContinuation
        finalContinuation = nil
        lock.unlock()
        continuation?.resume(returning: text)
    }

    deinit {
        task?.cancel()
    }
}
