import AVFoundation
import Foundation
import OSLog

/// Live preview for the GGML engines, which only know how to transcribe a
/// complete take: every second or so the take so far is decoded again in
/// full, and the whole result replaces the preview. The words revise
/// wholesale between passes, exactly as Apple's partials do, and the overlay
/// is already built for that.
///
/// Deliberately preview-only: `finishOrGiveUp` always answers with the empty
/// string, so the final transcript always comes from the ordinary
/// file-transcription pass, with the same engine, the same configuration and
/// the complete audio. There is no agreement algorithm and no second source
/// of truth to diverge; the worst this class can do is show a rough draft.
final class ChunkedLocalLiveTranscriber: LiveTranscribing, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.micmyday.app", category: "ChunkedLive")

    /// The most audio allowed to wait unconverted: thirty seconds or 32 MiB.
    /// A consumer this far behind is not catching up, and a preview silently
    /// missing a stretch would misrepresent the dictation, so overflow ends
    /// the preview outright. The recording is untouched either way.
    private static let maximumQueuedSeconds: Double = 30
    private static let maximumQueuedBytes = 32 * 1024 * 1024

    /// Only this much of the tail is kept and decoded. The preview's job is
    /// the words being said now; the final pass reads the whole file. Kept by
    /// discarding older samples, not by slicing a growing array, so a long
    /// dictation's memory stays bounded.
    private static let retainedSeconds = 120
    private static let retainedSamples = retainedSeconds * 16_000

    /// The pacing is duty-based, not a fixed clock: the gap between decode
    /// starts is always four times what the previous decode cost, floored at
    /// 0.6 seconds. A fast engine on a fast Mac refreshes every 0.6 seconds;
    /// a machine where a pass takes two seconds refreshes every eight and
    /// runs the GPU at most a quarter of the time either way, growing stale
    /// rather than hot. Deliberate, documented pacing rather than a
    /// completion to wait on: the thing being timed is "how stale may the
    /// preview grow", which has no event.
    private static let decodeIntervalFastest: Duration = .milliseconds(600)
    /// One anomalous pass — a cold Metal pipeline, a page-in, competing GPU
    /// load — must not silence the preview for four times its own length;
    /// staleness is capped even when the duty rule asks for more.
    private static let decodeIntervalLongest: Duration = .seconds(6)
    private static let decodeFloor: Duration = .milliseconds(200)
    /// A decode may occupy at most about a quarter of the cadence.
    private static let decodeDutyFactor = 4

    /// What the decode passes run with, captured when recording starts so a
    /// setting changed mid-take cannot make the preview and the final pass
    /// systematically disagree.
    struct Configuration {
        let modelPath: String
        let engine: LocalModelEngine
        let language: String
        let prompt: String
    }

    private let configuration: Configuration
    private let onPartial: @Sendable (String) -> Void

    private let lock = NSLock()
    private var latest = ""
    private var intakeClosed = false
    private var abandoned = false
    private var queuedFrames = 0
    private var queuedBytes = 0
    /// The converted take, trailing window only; see `retainedSamples`.
    private var samples: [Float] = []
    private var samplesSinceDecode = 0
    /// Set once consecutive converted buffers carry voice-level energy.
    /// Decoding pure silence is worse than useless — these models invent
    /// filler words for it — so until something is actually heard nothing
    /// runs and nothing is shown. Two buffers in a row, because a single
    /// spike is not a voice: the very keystroke that starts the recording
    /// peaks far above any sensible threshold on a built-in microphone.
    private var heardSignal = false
    private var energeticBuffers = 0

    private let audio: AsyncStream<AVAudioPCMBuffer>
    private var intake: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var consumer: Task<Void, Never>?
    private var decoder: Task<Void, Never>?
    private let cancellation = WhisperCppEngine.InferenceCancellation()

    /// Nothing is ever waited for: the answer is always empty, immediately.
    var finishBudget: Duration { .zero }

    init(configuration: Configuration, onPartial: @escaping @Sendable (String) -> Void) {
        self.configuration = configuration
        self.onPartial = onPartial
        var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        audio = AsyncStream { continuation = $0 }
        intake = continuation
    }

    // MARK: - LiveTranscribing

    func start() {
        consumer = Task(priority: .userInitiated) { [weak self] in
            await self?.consume()
        }
        decoder = Task(priority: .utility) { [weak self] in
            await self?.decodeLoop()
        }
    }

    /// Called on the audio thread. The buffer is copied before this returns:
    /// the engine reuses its buffers, and a reference yielded into the queue
    /// would be rewritten by later audio before the consumer read it.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if intakeClosed || abandoned {
            lock.unlock()
            return
        }
        let frames = Int(buffer.frameLength)
        let bytes = Self.byteCount(of: buffer)
        let limitFrames = Int(buffer.format.sampleRate * Self.maximumQueuedSeconds)
        if queuedFrames + frames > limitFrames || queuedBytes + bytes > Self.maximumQueuedBytes {
            abandoned = true
            lock.unlock()
            intake?.finish()
            Self.logger.notice("preview queue overflowed; the preview ends here")
            return
        }
        queuedFrames += frames
        queuedBytes += bytes
        lock.unlock()

        guard let copy = Self.copied(buffer) else {
            lock.lock()
            abandoned = true
            lock.unlock()
            intake?.finish()
            return
        }
        intake?.yield(copy)
    }

    /// Always empty, always at once: the preview never supplies the final
    /// text, so there is nothing to wait for. Ends the preview work so the
    /// final pass is not queued behind a decode of a draft.
    func finishOrGiveUp(after limit: Duration) async -> String {
        close()
        return ""
    }

    func cancel() {
        close()
    }

    var currentText: String {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    private func close() {
        lock.lock()
        intakeClosed = true
        lock.unlock()
        intake?.finish()
        cancellation.cancel()
        decoder?.cancel()
    }

    // MARK: - Conversion

    /// Drains buffers into the retained sample window. Runs independently of
    /// the decode loop, so conversion never stalls behind an inference.
    private func consume() async {
        var converter: AVAudioConverter?
        for await buffer in audio {
            do {
                let converted = try convert(buffer, using: &converter)
                appendSamples(converted)
                lock.lock()
                queuedFrames -= Int(buffer.frameLength)
                queuedBytes -= Self.byteCount(of: buffer)
                lock.unlock()
            } catch {
                Self.logger.notice("preview conversion failed: \(error.localizedDescription, privacy: .public)")
                lock.lock()
                abandoned = true
                lock.unlock()
                intake?.finish()
                // Nothing queued behind a failure is worth converting; the
                // preview is already condemned.
                return
            }
        }
    }

    private func appendSamples(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { return }
        let incoming = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        var energy: Float = 0
        for sample in incoming {
            energy += sample * sample
        }
        let level = (energy / Float(max(1, incoming.count))).squareRoot()
        lock.lock()
        samples.append(contentsOf: incoming)
        if samples.count > Self.retainedSamples {
            samples.removeFirst(samples.count - Self.retainedSamples)
        }
        samplesSinceDecode += incoming.count
        // Around minus 52 dBFS of sustained level: quiet input chains
        // deliver speech well above this and must not lose their preview,
        // while an empty room's floor and one keystroke's click both stay
        // out. Erring low costs one hallucinated draft; erring high costs
        // the whole feature for anyone with a quiet microphone.
        if !heardSignal {
            if level > 0.0025 {
                energeticBuffers += 1
                if energeticBuffers >= 2 { heardSignal = true }
            } else {
                energeticBuffers = 0
            }
        }
        lock.unlock()
    }

    // MARK: - Decoding

    private func decodeLoop() async {
        while !Task.isCancelled {
            let began = ContinuousClock.now
            let snapshot: [Float]?
            lock.lock()
            if abandoned || intakeClosed {
                lock.unlock()
                return
            }
            if heardSignal, samplesSinceDecode > 0, samples.count >= 16_000 / 2 {
                snapshot = samples
                samplesSinceDecode = 0
            } else {
                snapshot = nil
            }
            lock.unlock()

            var interval = Self.decodeIntervalFastest
            if let snapshot {
                do {
                    let result = try await WhisperCppEngine.shared.transcribe(
                        samples: snapshot,
                        modelPath: configuration.modelPath,
                        engine: configuration.engine,
                        language: configuration.language,
                        prompt: configuration.prompt,
                        cancellation: cancellation
                    )
                    // The draft never carries a trailing comma or full stop:
                    // it is the one thing every pass re-decides about an
                    // unfinished sentence, and watching it blink on and off
                    // was the single most visible instability. The settled
                    // text keeps its punctuation untouched.
                    // The density guard judges the RAW decode: a looped
                    // hallucination collapsed first would sail through as
                    // two words and get displayed, which is exactly what
                    // both the guard and the cleaner exist to prevent.
                    let rawText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let rawWordCount = rawText.split(whereSeparator: \.isWhitespace).count
                    var text = TranscriptCleaner.collapsingRepetitionLoops(rawText)
                    while let last = text.unicodeScalars.last,
                          Self.volatileTrailing.contains(last) {
                        text.removeLast()
                    }
                    // A model given a word and a stretch of near-silence
                    // invents a plausible sentence. Nobody speaks this many
                    // words in this little audio, so a pass that claims it
                    // is discarded and the last honest draft stands.
                    if Double(rawWordCount) > result.audioSeconds * 4 + 2 {
                        text = ""
                    }
                    lock.lock()
                    let dead = intakeClosed || abandoned
                    // An empty pass keeps the last useful draft, on screen
                    // and in `currentText` alike, so the two cannot disagree.
                    if !dead, !text.isEmpty { latest = text }
                    lock.unlock()
                    if !dead, !text.isEmpty { onPartial(text) }
                    // The cadence follows the engine; see the pacing note on
                    // the constants above.
                    let decodeCost = began.duration(to: .now)
                    interval = min(
                        max(Self.decodeIntervalFastest, decodeCost * Self.decodeDutyFactor),
                        Self.decodeIntervalLongest
                    )
                } catch {
                    // A cancelled pass is the normal end; anything else ends
                    // the preview quietly, and the recording is unharmed.
                    if !(error is CancellationError) {
                        Self.logger.notice("preview decode failed: \(error.localizedDescription, privacy: .public)")
                    }
                    return
                }
            } else {
                // Nothing to decode yet. Check again soon rather than waiting
                // out a whole interval: the first half-second of audio used
                // to sit undecoded while this loop slept, which pushed the
                // very first words more than a second late.
                interval = Self.decodeFloor
            }

            let elapsed = began.duration(to: .now)
            let wait = max(interval - elapsed, Self.decodeFloor)
            do {
                try await Task.sleep(for: wait)
            } catch {
                return
            }
        }
    }

    /// Sentence punctuation that an unfinished draft keeps re-deciding,
    /// including the CJK forms.
    private static let volatileTrailing = CharacterSet(charactersIn: ",.;:!?\u{2026}\u{3002}\u{3001}\u{FF01}\u{FF1F}")

    // MARK: - Audio plumbing

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    private func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: inout AVAudioConverter?
    ) throws -> AVAudioPCMBuffer {
        if converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: Self.targetFormat)
        }
        guard let converter else {
            throw TranscriptionError.localInferenceFailed("The audio format could not be converted.")
        }
        guard buffer.format == converter.inputFormat else {
            throw TranscriptionError.localInferenceFailed("The audio format changed mid-recording.")
        }
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            throw TranscriptionError.localInferenceFailed("The audio buffer could not be allocated.")
        }
        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        guard status != .error else {
            throw TranscriptionError.localInferenceFailed("The audio could not be resampled.")
        }
        return output
    }

    /// What the buffer actually holds, read from its buffer list, which is
    /// right for interleaved and deinterleaved layouts alike.
    private static func byteCount(of buffer: AVAudioPCMBuffer) -> Int {
        let list = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        return list.reduce(0) { $0 + Int($1.mDataByteSize) }
    }

    /// A deep copy the consumer owns outright; see `append`.
    private static func copied(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format, frameCapacity: buffer.frameLength
        ) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { return nil }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    deinit {
        intake?.finish()
        cancellation.cancel()
        decoder?.cancel()
    }
}
