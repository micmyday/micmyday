import AVFoundation
import Foundation

/// On-device transcription: decodes the recorded WAV to 16 kHz mono float
/// samples and runs them through the cached whisper.cpp context.
final class WhisperCppTranscriber {
    static let requiredSampleRate: Double = 16_000

    /// `probe`, when given, receives what this run consumed. Nil by default, so
    /// a caller that is not counting causes no extra work anywhere below.
    func transcribe(
        fileURL: URL,
        configuration: TranscriptionConfiguration,
        probe: UsageProbe? = nil
    ) async throws -> String {
        guard let modelURL = configuration.localModelURL else {
            throw TranscriptionError.invalidConfiguration("Select a Whisper model in Settings → Engine.")
        }
        let samples = try Self.monoSamples16kHz(from: fileURL)
        guard !samples.isEmpty else { throw TranscriptionError.emptyResponse }
        let engine = WhisperModelCatalog.model(withID: configuration.model)?.engine ?? .whisper
        let result = try await WhisperCppEngine.shared.transcribe(
            samples: samples,
            modelPath: modelURL.path,
            engine: engine,
            language: configuration.language,
            prompt: configuration.prompt
        )
        // Local models fall into repetition loops on awkward audio; see
        // TranscriptCleaner. Hosted engines do not pass through here.
        let cleanedText = TranscriptCleaner.collapsingRepetitionLoops(result.text)
        // Recorded after the transcript exists, so nothing here stands between
        // the recording and the text.
        probe?.add(UsageMeasurement(
            job: .transcribe,
            modelID: configuration.model,
            displayName: WhisperModelCatalog.model(withID: configuration.model)?.displayName
                ?? configuration.model,
            location: "This Mac",
            tokensOut: result.tokens,
            wordsOut: UsageMeasurement.words(in: cleanedText),
            audioSeconds: result.audioSeconds,
            processingSeconds: result.processingSeconds
        ))
        return cleanedText
    }

    static func monoSamples16kHz(from fileURL: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: fileURL)
        let sourceFormat = file.processingFormat
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: requiredSampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else {
            throw TranscriptionError.localInferenceFailed("The recording could not be converted for local transcription.")
        }

        let chunkFrames: AVAudioFrameCount = 16_384
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * requiredSampleRate / sourceFormat.sampleRate) + 1)
        var reachedEnd = false
        var conversionError: NSError?

        while true {
            // A cancelled caller stops mid-file instead of resampling all of
            // it; every caller treats CancellationError as "say nothing".
            try Task.checkCancellation()
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: chunkFrames) else {
                throw TranscriptionError.localInferenceFailed("The audio conversion buffer could not be allocated.")
            }

            let status = converter.convert(to: outputBuffer, error: &conversionError) { packetCount, inputStatus in
                if reachedEnd {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: packetCount) else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                do {
                    try file.read(into: inputBuffer)
                } catch {
                    inputStatus.pointee = .endOfStream
                    reachedEnd = true
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }

            if let conversionError {
                throw TranscriptionError.localInferenceFailed(
                    "The recording could not be resampled: \(conversionError.localizedDescription)"
                )
            }

            if outputBuffer.frameLength > 0, let channelData = outputBuffer.floatChannelData {
                samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
            }

            if status == .endOfStream || (status == .inputRanDry && reachedEnd) || outputBuffer.frameLength == 0 {
                break
            }
        }

        return samples
    }
}
