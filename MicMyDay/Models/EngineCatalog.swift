import Foundation

/// Shared descriptions for setup and Settings → Transcription.
struct EngineDescription {
    let provider: TranscriptionProviderKind
    let tag: String
    let line: String
    let privacy: Int
    let cost: String
}

/// Editorial bands, not measurements made by MicMyDay. Zero means unrated.
/// Evidence, limitations and the complete mapping: Documentation/TranscriptionRatings.md.
struct TranscriptionAssessment: Equatable {
    let speed: Int
    let accuracy: Int
    let note: String

    static let unrated = Self(speed: 0, accuracy: 0,
                             note: "No comparable transcription benchmark is available for this model.")
}

enum EngineCatalog {
    static let ratingsHelp = "Based on published benchmarks reviewed September 2026. Accuracy uses broad 1–4 bands. Speed compares local models with local models and cloud models with cloud models; it does not measure live-preview delay. A dash means there is not enough evidence to rate this model."

    static let all: [EngineDescription] = [
        EngineDescription(
            provider: .whisper,
            tag: WhisperModelCatalog.recommendedEngine == .whisper ? "Recommended" : "Multilingual",
            line: "Runs privately on your Mac in up to 100 languages. Choose Turbo for accuracy or a smaller model for a lighter download.",
            privacy: 4, cost: "Free"
        ),
        EngineDescription(
            provider: .parakeet,
            tag: WhisperModelCatalog.recommendedEngine == .parakeet ? "Recommended" : "European",
            line: "Fast, private transcription on your Mac in 25 European languages. Accuracy is broadly comparable to Whisper Turbo.",
            privacy: 4, cost: "Free"
        ),
        EngineDescription(
            provider: .nemotron,
            tag: "Live",
            line: "Preview your transcript while you speak, privately on your Mac, in over 100 languages. Choose it for live feedback; Whisper and Parakeet generally make fewer mistakes.",
            privacy: 4, cost: "Free"
        ),
        EngineDescription(
            provider: .appleSpeech,
            tag: "No setup",
            line: "Uses speech recognition built into macOS, with no model download. Convenient for basic dictation, but generally less accurate than the larger models.",
            privacy: 3, cost: "Free"
        ),
        EngineDescription(
            provider: .openAI,
            tag: "API key",
            line: "Accurate transcription across many languages, processed by OpenAI. Choose a model to balance accuracy, speed and cost.",
            privacy: 1, cost: "Pay per use"
        ),
        EngineDescription(
            provider: .gemini,
            tag: "API key",
            line: "Transcribes your recording on Google's servers. Choose Transcribe for dedicated speech recognition or compare the other Gemini models below.",
            privacy: 1, cost: "Pay per use"
        ),
        EngineDescription(
            provider: .custom,
            tag: "Your server",
            line: "Connect your own transcription server. Accuracy, speed, privacy and cost depend on the model and where you run it.",
            privacy: 0, cost: "Yours"
        ),
    ]

    static func description(for provider: TranscriptionProviderKind) -> EngineDescription? {
        all.first { $0.provider == provider }
    }

    /// Read the actual selection rather than assigning every model its engine's rating.
    @MainActor
    static func assessment(for settings: SettingsStore) -> TranscriptionAssessment {
        let modelID: String?
        switch settings.provider {
        case .whisper, .parakeet, .nemotron: modelID = settings.whisperModelID
        case .openAI: modelID = settings.openAIModel
        case .gemini: modelID = settings.geminiModel
        case .custom: modelID = settings.customModel
        case .appleSpeech: modelID = nil
        }
        return assessment(for: settings.provider, modelID: modelID)
    }

    static func assessment(for provider: TranscriptionProviderKind, modelID: String?) -> TranscriptionAssessment {
        let id = modelID ?? ""
        if let engine = provider.localEngine {
            guard let model = WhisperModelCatalog.model(withID: id), model.engine == engine else {
                return .unrated
            }
            let speed: Int
            let accuracy: Int
            switch id {
            case "parakeet-tdt-0.6b-v3-q8_0", "parakeet-tdt-0.6b-v3-f16":
                (speed, accuracy) = (4, 3)
            case "large-v3-turbo-q5_0", "large-v3-turbo":
                (speed, accuracy) = (3, 3)
            case "medium": (speed, accuracy) = (1, 3)
            case "small", "small.en": (speed, accuracy) = (2, 2)
            case "base", "base.en": (speed, accuracy) = (3, 2)
            case "tiny", "tiny.en": (speed, accuracy) = (4, 2)
            case NemotronEngine.modelID: (speed, accuracy) = (3, 2)
            case NemotronEngine.steadyModelID: (speed, accuracy) = (4, 2)
            default: return .unrated
            }
            return TranscriptionAssessment(speed: speed, accuracy: accuracy, note: model.note)
        }

        // Exact IDs only: a new version must not silently inherit an older model's evidence.
        switch (provider, id) {
        case (.appleSpeech, _):
            return TranscriptionAssessment(speed: 3, accuracy: 1,
                note: "On-device recognition depends on the language installed on your Mac. Allowing server processing may send audio to Apple.")
        case (.openAI, "gpt-transcribe"):
            return TranscriptionAssessment(speed: 3, accuracy: 3,
                note: "A strong all-round choice for multilingual dictation, with fewer errors than OpenAI's older transcription models in recent benchmarks.")
        case (.openAI, "gpt-4o-transcribe"):
            return TranscriptionAssessment(speed: 2, accuracy: 3,
                note: "Good accuracy across languages. Choose Mini for faster, lower-cost transcription, or gpt-transcribe for the newer model.")
        case (.openAI, "gpt-4o-mini-transcribe"):
            return TranscriptionAssessment(speed: 3, accuracy: 3,
                note: "A faster, lower-cost alternative to GPT-4o Transcribe, with a small accuracy trade-off in published benchmarks.")
        case (.openAI, "whisper-1"):
            return TranscriptionAssessment(speed: 2, accuracy: 3,
                note: "OpenAI's hosted Whisper model. Choose gpt-transcribe for stronger accuracy in recent benchmarks.")
        case (.gemini, "gemini-3.5-transcribe"):
            return TranscriptionAssessment(speed: 4, accuracy: 4,
                note: "Supports over 85 languages. The strongest combination of accuracy and speed among the Gemini models compared in recent transcription benchmarks.")
        case (.gemini, "gemini-3.1-pro-preview"):
            return TranscriptionAssessment(speed: 1, accuracy: 4,
                note: "Strong multilingual accuracy, but slower results. Choose Transcribe when turnaround time matters.")
        case (.gemini, "gemini-3-flash-preview"):
            return TranscriptionAssessment(speed: 2, accuracy: 4,
                note: "Strong benchmark accuracy with reasoning enabled, but slower than Transcribe. Results depend on reasoning settings.")
        case (.gemini, "gemini-3.5-flash"):
            return TranscriptionAssessment(speed: 2, accuracy: 3,
                note: "Good multilingual transcription in published tests. Transcribe is the more direct choice for speech recognition.")
        case (.gemini, "gemini-3.1-flash-lite"):
            return TranscriptionAssessment(speed: 3, accuracy: 3,
                note: "A lightweight option for quick results. Ratings use published tests of its preview version.")
        case (.gemini, "gemini-2.5-pro"):
            return TranscriptionAssessment(speed: 1, accuracy: 4,
                note: "Strong English benchmark accuracy, but slow processing and uneven results across languages. Try Transcribe first.")
        case (.gemini, "gemini-2.5-flash"), (.gemini, "gemini-2.5-flash-lite"):
            return TranscriptionAssessment(speed: 3, accuracy: 2,
                note: "Quick processing, with more transcription errors than Transcribe in published comparisons.")
        case (.gemini, "gemini-3.5-flash-lite"), (.gemini, "gemini-3.6-flash"),
             (.gemini, "gemini-3.7-flash"), (.gemini, "gemini-3.8-flash"):
            return TranscriptionAssessment(speed: 0, accuracy: 0,
                note: "No comparable transcription benchmark was found. Choose Transcribe for a model with verified speech-recognition results.")
        case (.custom, _):
            return TranscriptionAssessment(speed: 0, accuracy: 0,
                note: "Ratings depend on your server and model.")
        default:
            return .unrated
        }
    }

    /// A stored selection is surfaced even if it ever leaves `all`, so an
    /// existing configuration can never become a dead end.
    static func selectableProviders(current: TranscriptionProviderKind) -> [TranscriptionProviderKind] {
        var providers = all.map(\.provider)
        if !providers.contains(current) {
            providers.append(current)
        }
        return providers
    }
}
