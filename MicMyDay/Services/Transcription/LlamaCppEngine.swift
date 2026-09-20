import Foundation
import OSLog

/// Serial owner of the loaded rewrite model, used to clean up a transcript
/// without it leaving the Mac.
///
/// llama.cpp itself is reached through `LlamaBridge`, which explains why it is
/// not imported here directly. This type owns the two things that are Swift's
/// business: keeping exactly one model loaded at a time, and making sure it is
/// gone before the process exits.
///
/// Shaped after `WhisperCppEngine` on purpose. Both sit on the same ggml
/// runtime and inherit the same two constraints: inference is not thread safe,
/// so everything runs on one queue; and the Metal backend asserts in an atexit
/// destructor if a context is still alive at exit, so termination has to free
/// it explicitly rather than letting the process fall over the end.
///
/// The model stays loaded between rewrites. Reading a 1-3 GB file takes long
/// enough to be felt on every dictation, and the weights are memory-mapped, so
/// the resident cost is well below the file size and the system can reclaim it
/// under pressure.
final class LlamaCppEngine: @unchecked Sendable {
    static let shared = LlamaCppEngine()

    private static let logger = Logger(subsystem: "com.micmyday.app", category: "LlamaCpp")

    /// Longer than any sensible rewrite of a dictation. A small model that
    /// starts repeating itself would otherwise generate until the context is
    /// full while the user waits.
    private static let maximumNewTokens: Int32 = 2048

    private let queue = DispatchQueue(label: "com.micmyday.app.llama", qos: .userInitiated)

    private var session: OpaquePointer?
    private var loadedModelPath: String?
    /// Queue-confined. Once termination has freed the session, work enqueued
    /// concurrently must not load another model, or the app can still exit with
    /// a live Metal context and trip ggml's atexit assert.
    private var terminating = false

    private init() {}

    deinit {
        closeSession()
    }

    /// Rewrites `transcript` under `systemPrompt` using the GGUF at `modelPath`.
    ///
    /// Cancellation is checked between tokens rather than only at the start, so
    /// Escape during a rewrite stops generation within a token or two instead
    /// of letting it run on to produce text nobody will read.
    ///
    /// The flag exists because generation happens on a dispatch queue, outside
    /// any task. `Task.isCancelled` read from in there is always false, however
    /// thoroughly the surrounding task was cancelled, so the cancellation has
    /// to be carried across the boundary by hand.
    func rewrite(
        transcript: String,
        systemPrompt: String,
        modelPath: String,
        format: ChatPromptFormat,
        counted: (@Sendable (_ tokensIn: Int, _ tokensOut: Int, _ seconds: Double) -> Void)? = nil
    ) async throws -> String {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        continuation.resume(returning: try run(
                            transcript: transcript,
                            systemPrompt: systemPrompt,
                            modelPath: modelPath,
                            format: format,
                            counted: counted,
                            isCancelled: { flag.isCancelled }
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    /// Loads the model ahead of the first rewrite so that rewrite does not pay
    /// for it. Safe to call repeatedly.
    func preload(modelPath: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    _ = try loadIfNeeded(modelPath: modelPath)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Frees the model before exit handlers run, for the reason given above.
    /// Returns false when a rewrite still occupies the queue after the timeout:
    /// quitting must not hang behind one.
    func unloadForTermination(timeout: TimeInterval = 2) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            terminating = true
            closeSession()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }

    func unloadIfCached(modelPath: String) {
        queue.async { [self] in
            guard loadedModelPath == modelPath else { return }
            closeSession()
        }
    }

    // MARK: - Queue-confined

    private func closeSession() {
        guard let session else { return }
        mmd_llama_close(session)
        self.session = nil
        loadedModelPath = nil
    }

    private func loadIfNeeded(
        modelPath: String,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> OpaquePointer {
        guard !terminating else {
            throw TranscriptionError.invalidConfiguration("MicMyDay is quitting.")
        }
        if let session, loadedModelPath == modelPath { return session }

        // A different model was loaded: its memory goes back before the next
        // one is read, so a Mac never briefly holds both.
        closeSession()

        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw Self.message(for: .loadFailed)
        }

        var status = MMDLlamaStatus.OK
        guard let opened = mmd_llama_open(modelPath, { isCancelled() }, &status) else {
            if status == .cancelled { throw CancellationError() }
            throw Self.message(for: status)
        }
        session = opened
        loadedModelPath = modelPath
        Self.logger.notice("Loaded rewrite model: \((modelPath as NSString).lastPathComponent, privacy: .public)")
        return opened
    }

    private func run(
        transcript: String,
        systemPrompt: String,
        modelPath: String,
        format: ChatPromptFormat,
        counted: (@Sendable (_ tokensIn: Int, _ tokensOut: Int, _ seconds: Double) -> Void)?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> String {
        // Cancelled while queued behind another rewrite, or behind this model
        // being read from disk. Loading gigabytes for a dictation that has
        // already been abandoned helps nobody.
        if isCancelled() { throw CancellationError() }
        let session = try loadIfNeeded(modelPath: modelPath, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        let prompt = format.prompt(
            system: systemPrompt + "\n\n" + EnhancementOutput.instruction,
            user: transcript
        )

        // Started after the model is loaded: how long a rewrite takes is what a
        // choice between models turns on, and a one-off multi-gigabyte read is
        // not part of that. Also used for the log line below, which records
        // lengths and timings only: what the user said is theirs.
        let began = ContinuousClock.now
        // By-products of work already done: the prompt had to be tokenized
        // before the model could read it, and generation produces one token per
        // pass. Reading them back costs nothing.
        var tokensIn: Int32 = 0
        var tokensOut: Int32 = 0
        var status = MMDLlamaStatus.OK
        let produced = mmd_llama_generate(
            session,
            prompt,
            Self.maximumNewTokens,
            { isCancelled() },
            &tokensIn,
            &tokensOut,
            &status
        )
        guard let produced else {
            if status == .cancelled {
                Self.logger.notice("rewrite cancelled after \(began.duration(to: .now), privacy: .public)")
                throw CancellationError()
            }
            Self.logger.error("rewrite failed, status \(status.rawValue, privacy: .public)")
            throw Self.message(for: status)
        }
        defer { free(produced) }

        // Small models are often trained to reason before answering. The
        // thinking is not the rewrite and must never reach the user's cursor.
        // stripReasoning is a safety net, not the mechanism: the prompt format
        // already tells a reasoning model not to think. It stays because a
        // model that ignores that must not paste its deliberations.
        let text = Self.stripReasoning(String(cString: produced))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyResponse }
        // After the text is in hand, so counting can never be in its way.
        counted?(Int(tokensIn), Int(tokensOut), began.duration(to: .now).seconds)
        Self.logger.notice("""
            rewrote on \((modelPath as NSString).lastPathComponent, privacy: .public)             in \(began.duration(to: .now), privacy: .public):             \(transcript.count, privacy: .public) chars in, \(text.count, privacy: .public) out
            """)
        return text
    }

    /// The bridge reports a cause; the wording lives here with the rest of the
    /// interface copy, and says what the user can do rather than what failed.
    private static func message(for status: MMDLlamaStatus) -> TranscriptionError {
        switch status {
        case .loadFailed:
            return .invalidConfiguration(
                "The rewrite model could not be loaded. Deleting it and downloading it again usually fixes this."
            )
        case .promptTooLong:
            return .invalidConfiguration(
                "This dictation is too long for a model running on your Mac. A provider has no such limit."
            )
        case .empty:
            return .emptyResponse
        case .truncated:
            return .invalidConfiguration(
                "The rewrite ran longer than the model on this Mac allows. The original text was kept."
            )
        default:
            return .invalidConfiguration("The rewrite model stopped unexpectedly. The original text was kept.")
        }
    }

    /// Removes a leading chain-of-thought block. Written to survive the
    /// truncated case too: a model that opens a thinking block and hits the
    /// token limit before closing it has produced no answer at all, and
    /// returning its reasoning would be worse than returning nothing.
    static func stripReasoning(_ text: String) -> String {
        guard let open = text.range(of: "<think>") else { return text }
        guard let close = text.range(of: "</think>", range: open.upperBound ..< text.endIndex) else {
            return String(text[text.startIndex ..< open.lowerBound])
        }
        return String(text[text.startIndex ..< open.lowerBound]) + text[close.upperBound ..< text.endIndex]
    }
}

/// A cancellation flag that can be read from a dispatch queue.
///
/// Swift concurrency's own cancellation does not reach across to a queue: the
/// block running there is not in a task, so `Task.isCancelled` is false no
/// matter what happened to the task that started the work.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
