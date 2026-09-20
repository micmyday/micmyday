import AVFoundation
import Foundation

/// Routes a recording to whichever engine the configuration names. Shared by
/// live dictation and by the setup assistant's try-out, so both always run the
/// user's real configuration rather than a second, drifting copy of it.
enum TranscriptionService {
    /// Transcribes a recording.
    ///
    /// When `onPartialText` is supplied and the engine can stream, each
    /// fragment is delivered as the provider produces it; the full transcript
    /// is still the return value. Engines that cannot stream ignore the
    /// callback and simply return the finished text.
    static func transcribe(
        audioURL: URL,
        configuration: TranscriptionConfiguration,
        probe: UsageProbe? = nil,
        onPartialText: (@MainActor (String) -> Void)? = nil
    ) async throws -> String {
        if let request = try DataSharingRequest.transcription(configuration) {
            try await DataSharingConsent.shared.requirePermission(for: request)
        }
        // Engines other than the local ones report nothing of their own, so
        // what they did is measured from the outside: the audio that went in,
        // the words that came back, and how long the call took. Tokens stay at
        // zero rather than being guessed, since a speech API does not bill in
        // them and a made-up figure beside real ones would be worse than none.
        let began = ContinuousClock.now
        func measured(_ text: String, model: String, name: String, where location: String) -> String {
            probe?.add(UsageMeasurement(
                job: .transcribe,
                modelID: model,
                displayName: name,
                location: location,
                wordsOut: UsageMeasurement.words(in: text),
                audioSeconds: (try? AVAudioFile(forReading: audioURL))
                    .map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0,
                processingSeconds: began.duration(to: .now).seconds
            ))
            return text
        }

        switch configuration.provider {
        case .appleSpeech:
            return measured(
                try await AppleSpeechTranscriber().transcribe(
                    fileURL: audioURL,
                    language: configuration.language,
                    preferOnDevice: configuration.preferOnDevice,
                    prompt: configuration.prompt
                ),
                model: "apple-speech", name: "Apple Speech", where: "This Mac"
            )
        case .whisper, .parakeet, .nemotron:
            if WhisperModelCatalog.model(withID: configuration.model)?.engine == .nemotron {
                return measured(
                    try await NemotronEngine.batchTranscribe(
                        fileURL: audioURL,
                        language: configuration.language,
                        modelID: configuration.model
                    ),
                    model: configuration.model,
                    name: WhisperModelCatalog.model(withID: configuration.model)?.displayName
                        ?? configuration.model,
                    where: "This Mac"
                )
            }
            return try await WhisperCppTranscriber().transcribe(
                fileURL: audioURL,
                configuration: configuration,
                probe: probe
            )
        case .gemini:
            return measured(
                try await GeminiTranscriber().transcribe(
                    fileURL: audioURL,
                    configuration: configuration
                ),
                model: configuration.model, name: configuration.model, where: "Gemini"
            )
        case .openAI, .custom:
            let place = configuration.provider.title
            if let onPartialText {
                return measured(
                    try await OpenAICompatibleTranscriber().transcribeStreaming(
                        fileURL: audioURL,
                        configuration: configuration,
                        onDelta: onPartialText
                    ),
                    model: configuration.model, name: configuration.model, where: place
                )
            }
            return measured(
                try await OpenAICompatibleTranscriber().transcribe(
                    fileURL: audioURL,
                    configuration: configuration
                ),
                model: configuration.model, name: configuration.model, where: place
            )
        }
    }
}
