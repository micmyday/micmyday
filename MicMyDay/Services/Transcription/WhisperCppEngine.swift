import Foundation
import OSLog
import whisper

/// Serial wrapper around the whisper.cpp C API. Keeps the most recently used
/// model loaded so consecutive dictations skip the multi-second model load.
final class WhisperCppEngine: @unchecked Sendable {
    static let shared = WhisperCppEngine()

    /// A transcript and what it cost to produce it.
    ///
    /// `tokens` is the decoder's own output count, read from the segments that
    /// were decoded anyway. Speech has no input tokens: audio goes in, so what
    /// the model consumed is measured in seconds.
    struct Result: Sendable {
        let text: String
        let tokens: Int
        let audioSeconds: Double
        /// Time spent inferring, excluding loading the model. A first run that
        /// reads gigabytes from disk says nothing about which engine is faster.
        let processingSeconds: Double
    }

    private static let logger = Logger(subsystem: "com.micmyday.app", category: "WhisperCpp")

    /// What the samples handed to these engines are resampled to, which is what
    /// makes a sample count a duration.
    private static let inferenceSampleRate: Double = 16_000

    private let queue = DispatchQueue(label: "com.micmyday.app.whisper", qos: .userInitiated)
    private var context: OpaquePointer?
    private var contextModelPath: String?
    private var contextEngine: LocalModelEngine = .whisper
    /// Queue-confined. Once termination has freed the context, work that was
    /// enqueued concurrently must not reload a model, or the app can still
    /// exit with a live Metal context and trip ggml's atexit assert.
    private var terminating = false

    private init() {}

    deinit {
        freeContext()
    }

    /// A flag an inference checks as it runs. `cancel()` makes the current
    /// ggml graph abort at its next checkpoint and any queued-but-unstarted
    /// run refuse to start. Needed because the live preview re-decodes the
    /// take every second or so, and a preview pass still running at stop
    /// would otherwise make the final transcription wait a full decode.
    final class InferenceCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func cancel() {
            lock.lock()
            flag = true
            lock.unlock()
        }
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return flag
        }
    }

    /// C-visible trampoline for ggml's abort callback: true means abort.
    private static let abortWhenCancelled: ggml_abort_callback = { userData in
        guard let userData else { return false }
        return Unmanaged<InferenceCancellation>.fromOpaque(userData)
            .takeUnretainedValue().isCancelled
    }

    func transcribe(
        samples: [Float],
        modelPath: String,
        engine: LocalModelEngine,
        language: String,
        prompt: String,
        cancellation: InferenceCancellation? = nil
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let cancellation, cancellation.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    // The token must outlive the C call that polls it.
                    try withExtendedLifetime(cancellation) {
                        switch engine {
                        case .whisper:
                            continuation.resume(returning: try runWhisper(
                                samples: samples,
                                modelPath: modelPath,
                                language: language,
                                prompt: prompt,
                                cancellation: cancellation
                            ))
                        case .parakeet:
                            continuation.resume(returning: try runParakeet(
                                samples: samples,
                                modelPath: modelPath,
                                cancellation: cancellation
                            ))
                        case .nemotron:
                            // Routed to NemotronEngine before this engine is
                            // ever asked; reaching here is a dispatch bug.
                            throw TranscriptionError.invalidConfiguration(
                                "The streaming model does not run on this engine.")
                        }
                    }
                } catch {
                    if let cancellation, cancellation.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Loads the model and runs a short silent inference so the Metal pipeline
    /// is compiled before the user's first real dictation.
    func preload(modelPath: String, engine: LocalModelEngine) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    let warmupSamples = [Float](repeating: 0, count: 16_000)
                    switch engine {
                    case .whisper:
                        _ = try runWhisper(samples: warmupSamples, modelPath: modelPath, language: "en", prompt: "")
                    case .parakeet:
                        _ = try runParakeet(samples: warmupSamples, modelPath: modelPath)
                    case .nemotron:
                        throw TranscriptionError.invalidConfiguration(
                            "The streaming model does not run on this engine.")
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Frees whatever model is loaded before exit handlers run: ggml's Metal
    /// backend asserts in an atexit destructor if a context is still alive.
    /// Returns false when an inference is still occupying the queue after the
    /// timeout; inference cannot be aborted mid-run, and quitting must not
    /// hang behind a possibly minutes-long transcription.
    func unloadForTermination(timeout: TimeInterval = 2) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            terminating = true
            freeContext()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }

    func unloadIfCached(modelPath: String) {
        queue.async { [self] in
            guard contextModelPath == modelPath else { return }
            freeContext()
        }
    }

    private func freeContext() {
        guard let context else { return }
        switch contextEngine {
        case .whisper: whisper_free(context)
        case .parakeet: parakeet_free(context)
        // Never loaded here, so never freed here.
        case .nemotron: break
        }
        self.context = nil
        contextModelPath = nil
    }

    private func runWhisper(
        samples: [Float],
        modelPath: String,
        language: String,
        prompt: String,
        cancellation: InferenceCancellation? = nil
    ) throws -> Result {
        let ctx = try loadContext(modelPath: modelPath, engine: .whisper)

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        if let cancellation {
            params.abort_callback = Self.abortWhenCancelled
            params.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
        }
        params.no_timestamps = true
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.suppress_blank = true

        let languageCode = language.isEmpty ? "auto" : language
        let began = ContinuousClock.now
        let status: Int32 = languageCode.withCString { languagePointer in
            params.language = languagePointer
            if prompt.isEmpty {
                return samples.withUnsafeBufferPointer { buffer in
                    whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
                }
            }
            return prompt.withCString { promptPointer in
                params.initial_prompt = promptPointer
                return samples.withUnsafeBufferPointer { buffer in
                    whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
                }
            }
        }

        let elapsed = began.duration(to: .now)
        guard status == 0 else {
            throw TranscriptionError.localInferenceFailed("whisper.cpp inference failed (status \(status)).")
        }

        var transcript = ""
        var tokens = 0
        for index in 0 ..< whisper_full_n_segments(ctx) {
            if let segment = whisper_full_get_segment_text(ctx, index) {
                transcript += String(cString: segment)
            }
            // One more call inside a loop that already runs. The decoder has
            // these tokens in hand; nothing is recomputed to ask for them.
            tokens += Int(whisper_full_n_tokens(ctx, index))
        }
        return Result(
            text: transcript,
            tokens: tokens,
            audioSeconds: Double(samples.count) / Self.inferenceSampleRate,
            processingSeconds: elapsed.seconds
        )
    }

    private func runParakeet(
        samples: [Float],
        modelPath: String,
        cancellation: InferenceCancellation? = nil
    ) throws -> Result {
        let ctx = try loadContext(modelPath: modelPath, engine: .parakeet)

        var params = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY)
        params.n_threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        if let cancellation {
            params.abort_callback = Self.abortWhenCancelled
            params.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
        }

        let began = ContinuousClock.now
        let status = samples.withUnsafeBufferPointer { buffer in
            parakeet_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
        }
        let elapsed = began.duration(to: .now)
        guard status == 0 else {
            throw TranscriptionError.localInferenceFailed("Parakeet inference failed (status \(status)).")
        }

        var transcript = ""
        var tokens = 0
        for index in 0 ..< parakeet_full_n_segments(ctx) {
            if let segment = parakeet_full_get_segment_text(ctx, index) {
                transcript += String(cString: segment)
            }
            tokens += Int(parakeet_full_n_tokens(ctx, index))
        }
        return Result(
            text: transcript,
            tokens: tokens,
            audioSeconds: Double(samples.count) / Self.inferenceSampleRate,
            processingSeconds: elapsed.seconds
        )
    }

    private func loadContext(modelPath: String, engine: LocalModelEngine) throws -> OpaquePointer {
        guard !terminating else {
            throw TranscriptionError.localInferenceFailed("The app is quitting.")
        }
        if let context, contextModelPath == modelPath, contextEngine == engine {
            return context
        }
        freeContext()

        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw TranscriptionError.invalidConfiguration(
                "The selected local model is not downloaded. Download it in Settings → Engine."
            )
        }

        Self.logger.info("Loading local model (\(engine.rawValue, privacy: .public)): \(modelPath, privacy: .public)")
        let loaded: OpaquePointer?
        switch engine {
        case .whisper:
            var contextParams = whisper_context_default_params()
            contextParams.use_gpu = true
            loaded = whisper_init_from_file_with_params(modelPath, contextParams)
        case .parakeet:
            var contextParams = parakeet_context_default_params()
            contextParams.use_gpu = true
            loaded = parakeet_init_from_file_with_params(modelPath, contextParams)
        case .nemotron:
            throw TranscriptionError.invalidConfiguration(
                "The streaming model does not run on this engine.")
        }
        guard let loaded else {
            throw TranscriptionError.localInferenceFailed("The local model could not be loaded. Re-download it in Settings.")
        }
        context = loaded
        contextModelPath = modelPath
        contextEngine = engine
        return loaded
    }
}
