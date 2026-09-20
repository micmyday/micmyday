import AVFoundation
import FluidAudio
import Foundation
import OSLog

/// Decides whether a human voice was ever present in a take.
///
/// Transcription models have no way to answer "nothing was said". Handed a
/// stretch of silence they return their best guess at what a person might
/// have said, which is where a take nobody spoke into comes back as "Yeah"
/// or "Oh". The cure is not to ask them: a small detector trained on speech
/// listens to the same audio, and when it never hears a voice the take is
/// dropped before any engine sees it, and the live preview stays empty while
/// it runs.
///
/// Loudness alone cannot do this job. A keystroke, a fan or a passing lorry
/// all clear any threshold a quiet voice also has to clear, so a level meter
/// can only report that something was loud. This model was trained to
/// recognise a voice specifically, which is the question actually being
/// asked.
///
/// **Fails open, always.** Every path that cannot answer reports that a voice
/// was heard: no model on disk, a model that will not load, an audio format
/// that will not convert. The worst this class may do is fail to suppress an
/// invented word. It may never stand between the user and a real dictation,
/// because a dictation wrongly discarded is gone, while an invented word is
/// merely annoying.
final class VoiceActivityDetector: @unchecked Sendable {
    static let logger = Logger(subsystem: "com.micmyday.app", category: "VoiceActivity")

    /// The probability above which a chunk counts as speech.
    ///
    /// Below the package's own default of 0.85, deliberately. The costs here
    /// are not symmetric: a missed voice throws away something the user
    /// actually said, while a missed silence costs one stray word. Silero
    /// reports near zero for room tone and for the impulses that are not
    /// speech at all, so there is plenty of room beneath this.
    private static let speechProbability: Float = 0.5

    /// One chunk is 256ms of audio. A single chunk over the threshold is
    /// enough, because the shortest useful dictation is a single word and
    /// asking for two would discard it.
    private static let chunkSamples = VadManager.chunkSize

    // MARK: - The model on disk

    nonisolated private static var baseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
    }

    /// Where the package puts it, asked of the package rather than spelled
    /// out here, so a rename upstream cannot leave us looking in the wrong
    /// place and silently deciding the detector is missing.
    nonisolated static var modelURL: URL {
        baseDirectory
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(Repo.vad.folderName, isDirectory: true)
            .appendingPathComponent(ModelNames.VAD.sileroVadFile, isDirectory: true)
    }

    nonisolated static var isModelAvailable: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    /// Fetches the model and loads it once.
    ///
    /// Called from setup, never from a dictation. Loading is part of the job
    /// rather than an afterthought: Core ML compiles for this particular Mac
    /// on first load, and doing that while somebody is talking is exactly
    /// what preparing ahead of time exists to avoid.
    static func prepare() async throws {
        _ = try await VadManager(config: configuration)
    }


    private static var configuration: VadConfig {
        VadConfig(defaultThreshold: speechProbability, computeUnits: .cpuAndNeuralEngine)
    }

    // MARK: - One take

    private let lock = NSLock()
    private var voiceHeard = false
    /// True once anything has gone wrong, and the answer becomes yes for the
    /// rest of the take. See the note on failing open above.
    private var undecidable = false

    private let audio: AsyncStream<AVAudioPCMBuffer>
    private var intake: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var worker: Task<Void, Never>?

    init() {
        var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        audio = AsyncStream { continuation = $0 }
        intake = continuation
    }

    /// Whether the take may be transcribed and previewed.
    ///
    /// Answers yes the moment a voice is heard and never goes back: a person
    /// who speaks and then pauses has still spoken.
    var heardVoice: Bool {
        lock.lock()
        defer { lock.unlock() }
        return voiceHeard || undecidable
    }

    func start() {
        guard Self.isModelAvailable else {
            // Nothing to do and nothing to wait for. Marked undecidable so
            // the take behaves exactly as it did before this class existed.
            lock.lock()
            undecidable = true
            lock.unlock()
            return
        }
        worker = Task(priority: .userInitiated) { [weak self] in
            await self?.listen()
        }
    }

    /// Called on the audio thread, which must not be kept waiting. The buffer
    /// is copied because the engine reuses its own, and a reference handed
    /// onward would be overwritten by later audio before it was read.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copied(buffer) else { return }
        intake?.yield(copy)
    }

    /// Closes the intake and waits for the audio already handed over to be
    /// judged, then answers.
    ///
    /// Waiting matters for exactly the case that would hurt most. A one word
    /// dictation is over in a few hundred milliseconds, and the last chunk of
    /// it may still be in the model when the key is released; answering
    /// straight away would call that silence and throw away something that
    /// was said. Everything else has been decided long before the user stops.
    func finish() async -> Bool {
        intake?.finish()
        if let worker {
            // The completion of the work is the event waited on. The timeout
            // beside it is a fallback and nothing else: it is far longer than
            // judging a few hundred milliseconds of audio can take, and it
            // exists only so a model that never returns cannot hold a
            // dictation open. Reaching it fails open, like every other way
            // this class can fail.
            let finished = await withTaskGroup(of: Bool.self) { group in
                group.addTask { await worker.value; return true }
                group.addTask {
                    try? await Task.sleep(for: Self.judgementLimit)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if !finished {
                Self.logger.notice("voice detector did not finish in time; transcribing anyway")
                lock.lock()
                undecidable = true
                lock.unlock()
            }
        }
        worker = nil
        return heardVoice
    }

    private static let judgementLimit: Duration = .seconds(2)

    func stop() {
        intake?.finish()
        worker?.cancel()
        worker = nil
    }

    // MARK: - Listening

    private func listen() async {
        let manager: VadManager
        do {
            manager = try await VadManager(config: Self.configuration)
        } catch {
            Self.logger.notice(
                "voice detector unavailable, transcribing everything: \(error.localizedDescription, privacy: .public)"
            )
            lock.lock()
            undecidable = true
            lock.unlock()
            return
        }

        var converter: AVAudioConverter?
        var pending: [Float] = []
        var state = await manager.makeStreamState()

        for await buffer in audio {
            guard !Task.isCancelled else { return }
            // Once the answer is yes there is nothing left to decide, and
            // running the model for the rest of a long dictation would be
            // heat for its own sake.
            if heardVoice { return }

            let samples: [Float]
            do {
                samples = try Self.samples(from: buffer, using: &converter)
            } catch {
                Self.logger.notice(
                    "voice detector could not read the audio: \(error.localizedDescription, privacy: .public)"
                )
                lock.lock()
                undecidable = true
                lock.unlock()
                return
            }

            pending.append(contentsOf: samples)
            while pending.count >= Self.chunkSamples {
                let chunk = Array(pending.prefix(Self.chunkSamples))
                pending.removeFirst(Self.chunkSamples)
                do {
                    let result = try await manager.processStreamingChunk(chunk, state: state)
                    state = result.state
                    if result.probability >= Self.speechProbability {
                        lock.lock()
                        voiceHeard = true
                        lock.unlock()
                        return
                    }
                } catch {
                    Self.logger.notice(
                        "voice detector stopped: \(error.localizedDescription, privacy: .public)"
                    )
                    lock.lock()
                    undecidable = true
                    lock.unlock()
                    return
                }
            }
        }
    }

    // MARK: - Audio plumbing

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    private static func samples(
        from buffer: AVAudioPCMBuffer,
        using converter: inout AVAudioConverter?
    ) throws -> [Float] {
        if converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter, buffer.format == converter.inputFormat else {
            throw VoiceActivityError.unreadableAudio
        }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw VoiceActivityError.unreadableAudio
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
        guard status != .error, let channel = output.floatChannelData?[0] else {
            throw VoiceActivityError.unreadableAudio
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    private static func copied(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format, frameCapacity: buffer.frameLength
        ) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0 ..< min(source.count, destination.count) {
            guard let from = source[index].mData, let to = destination[index].mData else { continue }
            memcpy(to, from, Int(source[index].mDataByteSize))
            destination[index].mDataByteSize = source[index].mDataByteSize
        }
        return copy
    }
}

enum VoiceActivityError: Error {
    case unreadableAudio
}


/// Whether the detector's model is here, and the business of getting it.
///
/// Its own type because fetching it is not a one-shot: the file comes from a
/// third party's servers, which are sometimes down, and a failed attempt at
/// launch must not mean the check is dead until the app is next restarted.
/// Observable so Settings can say what is going on rather than leaving a
/// switch that is on and quietly doing nothing.
@MainActor
final class VoiceActivityModel: ObservableObject {
    static let shared = VoiceActivityModel()

    enum State: Equatable {
        /// On disk and usable.
        case ready
        /// Not here, and not being fetched right now.
        case absent
        case fetching
        /// The last attempt failed. Another one is already scheduled unless
        /// the attempts have run out; the button offers one either way.
        case failed(String)
    }

    @Published private(set) var state: State

    /// Attempts are spaced further apart each time. A download this small
    /// fails for one of two reasons, a host that is down or a network that is
    /// not there, and both are usually over within minutes. After these the
    /// app stops asking until it is next launched or somebody presses the
    /// button, because retrying forever would be a background process nobody
    /// asked for.
    private static let retryDelays: [Duration] = [.seconds(30), .seconds(180), .seconds(900)]

    private var work: Task<Void, Never>?
    private var attempt = 0

    private init() {
        state = VoiceActivityDetector.isModelAvailable ? .ready : .absent
    }

    /// Fetches it if it is wanted and not here yet.
    ///
    /// Called at launch and when the switch is turned on, so somebody
    /// upgrading into this version gets it without being asked about a one
    /// megabyte file they have no basis for an opinion about.
    ///
    /// `insisting` is the user pressing the button: it starts again from the
    /// first attempt even if the automatic ones have been exhausted.
    func ensureReady(insisting: Bool = false) {
        if VoiceActivityDetector.isModelAvailable {
            state = .ready
            return
        }
        if insisting {
            work?.cancel()
            attempt = 0
        } else if work != nil {
            return
        }
        work = Task { [weak self] in
            await self?.fetchWithRetries()
        }
    }

    private func fetchWithRetries() async {
        while !Task.isCancelled {
            state = .fetching
            do {
                try await VoiceActivityDetector.prepare()
                guard !Task.isCancelled else { return }
                state = .ready
                attempt = 0
                work = nil
                VoiceActivityDetector.logger.info("voice detector ready")
                return
            } catch {
                guard !Task.isCancelled else { return }
                let reason = error.localizedDescription
                VoiceActivityDetector.logger.notice(
                    "voice detector could not be fetched: \(reason, privacy: .public)"
                )
                state = .failed(reason)
                guard attempt < Self.retryDelays.count else {
                    work = nil
                    return
                }
                let delay = Self.retryDelays[attempt]
                attempt += 1
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
        }
    }
}
