import AVFoundation
import FluidAudio
import Foundation
import OSLog

/// The Core ML Nemotron that transcribes many languages while the user is
/// still speaking.
///
/// A different animal from the GGML models next door: Core ML bundles run by
/// the FluidAudio package, the encoder on the Neural Engine, decoding the
/// dictation in 1.12-second chunks as it happens. The same manager also
/// transcribes a finished file, which is the fallback whenever the live
/// session cannot supply a complete result.
enum NemotronEngine {
    private static let logger = Logger(subsystem: "com.micmyday.app", category: "Nemotron")

    /// The catalog id of the middle variant, and the one that shipped first.
    /// Kept as it was so a Mac that already downloaded it still has it.
    static let modelID = "nemotron-streaming-multilingual"
    static let steadyModelID = "nemotron-streaming-2240"

    /// How much audio the encoder takes at a time, baked into the build that
    /// gets downloaded. It decides the trade the user is actually choosing:
    /// a shorter chunk puts words on screen sooner and asks more of the Mac,
    /// a longer one does less work for the same words a moment later.
    /// How much audio the encoder takes at a time, baked into the build that
    /// gets downloaded, and the whole of what these two entries differ by.
    ///
    /// The repository also ships 560ms and 4480ms builds, and neither is
    /// offered. 560 is off the model's trained attention tiling: it costs
    /// accuracy, and the full multilingual vocabulary makes it the most
    /// expensive tier to run rather than the cheapest, so it is slower, worse
    /// and hungrier at once. 4480 is 2240's equal on everything except the
    /// wait, which it doubles.
    static func chunkMs(for modelID: String) -> Int {
        modelID == steadyModelID ? 2240 : 1120
    }

    /// Everything is downloaded under the "auto" language directory, which
    /// carries the full multilingual variant; the spoken language is chosen
    /// at load time, not at download time.
    private static let downloadLanguage = "auto"

    /// The package's own cache root, so its managers and our bookkeeping can
    /// never disagree about where the models live.
    nonisolated private static var modelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    nonisolated static func variantDirectory(for modelID: String) -> URL {
        modelsRoot
            .appendingPathComponent(Repo.nemotronMultilingual.folderName, isDirectory: true)
            .appendingPathComponent(
                StreamingNemotronMultilingualAsrManager.languageDirectory(for: downloadLanguage),
                isDirectory: true
            )
            .appendingPathComponent("\(chunkMs(for: modelID))ms", isDirectory: true)
    }

    /// Written only after the download finished AND the model compiled once.
    /// Files alone do not make it ready: the first Core ML load compiles for
    /// this specific machine, and doing that during a dictation is what the
    /// preparation step exists to prevent. The stamp records the variant, so
    /// a build that changes the chunk length cannot trust a stale marker.
    nonisolated private static func preparedMarker(for modelID: String) -> URL {
        variantDirectory(for: modelID).appendingPathComponent(".micmyday-prepared")
    }

    nonisolated private static func preparedStamp(for modelID: String) -> String {
        "\(downloadLanguage)|\(chunkMs(for: modelID))ms"
    }

    nonisolated static func isReady(_ modelID: String) -> Bool {
        (try? String(contentsOf: preparedMarker(for: modelID), encoding: .utf8)) == preparedStamp(for: modelID)
    }

    /// What the manager's `setLanguage` needs for MicMyDay's language
    /// setting. Empty means automatic; a handful of bare codes are silently
    /// ignored by the model's metadata and only work in their locale form.
    nonisolated static func languageArgument(for code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "auto" else { return "auto" }
        switch trimmed.lowercased() {
        case "zh": return "zh-CN"
        case "ja": return "ja-JP"
        case "he": return "he-IL"
        case "th": return "th-TH"
        case "vi": return "vi-VN"
        case "id": return "id-ID"
        default: return trimmed
        }
    }

    /// Downloads the variant and compiles it once.
    ///
    /// `progress` runs on the main actor. The network occupies 0 to 0.9 —
    /// this downloader reports its fraction in 0...1, unlike the package's
    /// ModelHub which halves it — and the stretch to 1 is the compile pass,
    /// whose length Core ML does not report.
    static func downloadAndPrepare(
        modelID: String,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        // A directory without the marker is a failed or cancelled earlier
        // attempt; it is invisible to the model list, so nothing can delete
        // it from there, and retrying on top of it would trust whatever it
        // holds. Start clean instead.
        if !isReady(modelID), FileManager.default.fileExists(atPath: variantDirectory(for: modelID).path) {
            delete(modelID)
        }
        _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: downloadLanguage,
            chunkMs: chunkMs(for: modelID),
            to: modelsRoot
        ) { snapshot in
            let network = min(1, max(0, snapshot.fractionCompleted))
            Task { @MainActor in progress(network * 0.9) }
        }
        try Task.checkCancellation()
        await MainActor.run { progress(0.93) }

        // One load, discarded immediately: the point is the compile Core ML
        // runs on first load, cached on disk for the dictations to come. The
        // manager is torn down on every exit, success or not, before the
        // error is allowed to travel.
        let manager = StreamingNemotronMultilingualAsrManager()
        var compileFailure: Error?
        do {
            try await manager.loadModels(from: variantDirectory(for: modelID))
        } catch {
            compileFailure = error
        }
        await manager.cleanup()
        if let compileFailure { throw compileFailure }

        // A cancelled preparation must not report a ready model: the marker
        // is the last thing written, and only on an uncancelled run.
        try Task.checkCancellation()
        try Data(preparedStamp(for: modelID).utf8).write(to: preparedMarker(for: modelID))
        await MainActor.run { progress(1) }
        logger.info("Nemotron downloaded and prepared")
    }

    static func delete(_ modelID: String) {
        try? FileManager.default.removeItem(at: variantDirectory(for: modelID))
    }

    /// Transcribes a finished recording, for sessions where the live path
    /// produced nothing: a failed load, an overflow, or a stalled finish.
    /// One second of appended silence, so a recording that stops on the last
    /// word still gets that word and its punctuation decoded: the model needs
    /// to hear the speech end.
    private static let tailSilence = 16_000

    static func batchTranscribe(fileURL: URL, language: String, modelID: String) async throws -> String {
        var samples = try WhisperCppTranscriber.monoSamples16kHz(from: fileURL)
        guard !samples.isEmpty else { throw TranscriptionError.emptyResponse }
        // Appended only while the padded whole still fits the model's
        // single-pass input. Anything longer is decoded in windows, and
        // silence added at the end would shift every window behind it.
        if samples.count <= ASRConstants.maxModelSamples - Self.tailSilence {
            samples += [Float](repeating: 0, count: Self.tailSilence)
        }

        let manager = StreamingNemotronMultilingualAsrManager()
        var text = ""
        var failure: Error?
        do {
            try await manager.loadModels(from: variantDirectory(for: modelID))
            // After loading, not before: setting the language resets the
            // model's prompt id, and a load would put it back.
            await manager.setLanguage(languageArgument(for: language))
            _ = try await manager.process(samples: samples)
            text = try await manager.finish()
        } catch {
            failure = error
        }
        await manager.cleanup()
        if let failure { throw failure }
        return TranscriptCleaner.collapsingRepetitionLoops(
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
