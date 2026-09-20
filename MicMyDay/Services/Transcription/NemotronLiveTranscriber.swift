import AVFoundation
import FluidAudio
import Foundation
import OSLog

/// Streams a dictation through Nemotron as it is spoken, in whichever
/// language is being spoken.
///
/// The audio has to be carried from the capture thread to a Core ML session
/// that may still be loading when the first words are already said. The
/// answer to that gap is a queue with a single consumer: buffers pile up in
/// arrival order while the model loads, and the consumer works through them
/// the moment it can, so the model hears the dictation from its first sample
/// without the recording ever waiting for the model. When the session is
/// healthy its `finish()` is the final transcript; on any failure the
/// recorded file carries the take instead.
final class NemotronLiveTranscriber: LiveTranscribing, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.micmyday.app", category: "NemotronLive")

    /// The most audio allowed to wait in the queue: thirty seconds or 32 MiB,
    /// whichever comes first. A consumer that has fallen this far behind is
    /// not going to catch up, and a transcript quietly missing the dropped
    /// stretch would be worse than no live transcript at all — so overflow
    /// abandons the live result entirely and the recording carries the take.
    private static let maximumQueuedSeconds: Double = 30
    private static let maximumQueuedBytes = 32 * 1024 * 1024

    private let language: String
    /// Which streaming build to load: the variants differ in how much audio
    /// they take at a time, and each is a separate download on disk.
    private let modelID: String
    private let onPartial: @Sendable (String) -> Void

    private let lock = NSLock()
    private var latest = ""
    private var intakeClosed = false
    private var abandoned = false
    private var cancelled = false
    private var settled = false
    private var finalContinuation: CheckedContinuation<String, Never>?
    private var queuedFrames = 0
    private var queuedBytes = 0

    private let audio: AsyncStream<AVAudioPCMBuffer>
    private var intake: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var worker: Task<String, Never>?

    /// Loading, converting, the decode backlog and `finish()`'s own rescue
    /// pass can all still be under way at stop; ten seconds bounds the whole
    /// of it.
    var finishBudget: Duration { .seconds(10) }

    init(language: String, modelID: String, onPartial: @escaping @Sendable (String) -> Void) {
        self.language = language
        self.modelID = modelID
        self.onPartial = onPartial
        var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        audio = AsyncStream { continuation = $0 }
        intake = continuation
    }

    // MARK: - LiveTranscribing

    func start() {
        let task = Task(priority: .userInitiated) { [weak self] in
            await self?.run() ?? ""
        }
        lock.lock()
        worker = task
        lock.unlock()
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
            Self.logger.notice("live queue overflowed; the recording will carry this take")
            return
        }
        queuedFrames += frames
        queuedBytes += bytes
        lock.unlock()

        guard let copy = Self.copied(buffer) else {
            // A transcript quietly missing this stretch would be worse than
            // no live transcript; a failed copy condemns the live result the
            // same way an overflow does.
            markAbandoned()
            intake?.finish()
            return
        }
        intake?.yield(copy)
    }

    func finishOrGiveUp(after limit: Duration) async -> String {
        lock.lock()
        intakeClosed = true
        lock.unlock()
        intake?.finish()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if settled {
                    let text = latest
                    lock.unlock()
                    continuation.resume(returning: text)
                    return
                }
                finalContinuation = continuation
                lock.unlock()

                // Two racers settle the one continuation: the worker with its
                // real result, or the deadline with the empty string that
                // routes the dictation to the recording. Deliberately not a
                // task group — a group waits for its children, and a stuck
                // Core ML call would have defeated the timeout it was
                // supposed to enforce. The worker keeps running after a lost
                // race purely to clean up after itself.
                Task { [weak self] in
                    guard let self else { return }
                    guard let worker = self.workerNow else {
                        self.settle("")
                        return
                    }
                    let text = await worker.value
                    self.settle(self.cancelledNow ? self.currentText : text)
                }
                Task { [weak self] in
                    try? await Task.sleep(for: limit)
                    guard let self else { return }
                    self.settle("")
                }
            }
        } onCancel: {
            // Escape. The words already produced must survive for
            // insert-again, exactly as the Apple path preserves them.
            settle(currentText)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        intakeClosed = true
        lock.unlock()
        intake?.finish()
        settle(currentText)
    }

    var currentText: String {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    // MARK: - The consumer

    /// The one task that owns the manager: loads it, works the queue, and
    /// tears it down. Everything sequential, so no two of the manager's
    /// calls can ever overlap — its actor isolation alone would not prevent
    /// a finish() interleaving with a process() across suspension points.
    private func run() async -> String {
        let manager = StreamingNemotronMultilingualAsrManager()
        await manager.setPartialCallback { [weak self] text in
            guard let self else { return }
            // Cleaned at the source, so everything downstream of a partial —
            // the preview, currentText, what a cancellation preserves for
            // insert-again — carries collapsed loops. finish() cleans its
            // own return; doing it twice is harmless, missing the cancel
            // paths was not.
            let cleaned = TranscriptCleaner.collapsingRepetitionLoops(text)
            self.lock.lock()
            let dead = self.settled || self.abandoned
            if !dead { self.latest = cleaned }
            self.lock.unlock()
            guard !dead else { return }
            self.onPartial(cleaned)
        }

        do {
            try await manager.loadModels(from: NemotronEngine.variantDirectory(for: modelID))
            // After loading, not before: setting the language resets the
            // model's prompt id, and a load would put it back.
            await manager.setLanguage(NemotronEngine.languageArgument(for: language))
        } catch {
            Self.logger.notice("streaming model failed to load: \(error.localizedDescription, privacy: .public)")
            markAbandoned()
            await drainDiscarding()
            await manager.cleanup()
            return ""
        }

        var converter: AVAudioConverter?
        var failed = false
        for await buffer in audio {
            // Dead sessions do no more inference; see the transcriber twin.
            if failed || cancelledNow || abandonedNow || settledNow { continue }
            do {
                let converted = try convert(buffer, using: &converter)
                if let floats = Self.floats(of: converted), !floats.isEmpty {
                    _ = try await manager.process(samples: floats)
                }
                lock.lock()
                queuedFrames -= Int(buffer.frameLength)
                queuedBytes -= Self.byteCount(of: buffer)
                lock.unlock()
            } catch {
                Self.logger.notice("streaming failed mid-take: \(error.localizedDescription, privacy: .public)")
                failed = true
                markAbandoned()
            }
        }

        if failed || abandonedNow || cancelledNow || settledNow {
            await manager.cleanup()
            return ""
        }

        do {
            // The converter holds a resampler's worth of unplayed frames;
            // they come out on end-of-stream. No silence padding here —
            // finish() pads its own residual chunk and rescues a trailing
            // blank span itself.
            if let converter, let flushed = Self.flush(converter),
               let floats = Self.floats(of: flushed), !floats.isEmpty {
                _ = try await manager.process(samples: floats)
            }
            let text = try await manager.finish()
            await manager.cleanup()
            return TranscriptCleaner.collapsingRepetitionLoops(
                text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            Self.logger.notice("streaming finish failed: \(error.localizedDescription, privacy: .public)")
            await manager.cleanup()
            return ""
        }
    }

    private var cancelledNow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private var abandonedNow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return abandoned
    }

    private var settledNow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return settled
    }

    private var workerNow: Task<String, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return worker
    }

    private func markAbandoned() {
        lock.lock()
        abandoned = true
        lock.unlock()
    }

    /// Consumes and discards whatever is queued, so a failed session does not
    /// leave producers' copies alive in an abandoned stream.
    private func drainDiscarding() async {
        for await _ in audio {}
    }

    private func settle(_ text: String) {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return
        }
        settled = true
        latest = text
        let continuation = finalContinuation
        finalContinuation = nil
        lock.unlock()
        continuation?.resume(returning: text)
    }

    // MARK: - Audio plumbing

    /// The model's contract: 16 kHz, mono, Float32.
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

    /// Everything the resampler is still holding, released by end-of-stream.
    private static func flush(_ converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4_096) else {
            return nil
        }
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        guard conversionError == nil, status != .error else { return nil }
        return output
    }

    private static func floats(of buffer: AVAudioPCMBuffer) -> [Float]? {
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

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
        worker?.cancel()
    }
}
