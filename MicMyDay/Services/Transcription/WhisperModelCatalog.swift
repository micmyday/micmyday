import Foundation

/// Which local inference engine a downloadable model runs on.
enum LocalModelEngine: String {
    case whisper
    case parakeet
    /// The Core ML Nemotron run by the FluidAudio package: the one engine
    /// here that truly transcribes while the user is still speaking, in many
    /// languages. Its download and storage are a directory of Core ML
    /// bundles rather than a single GGML file, so every file-shaped code
    /// path branches on this.
    case nemotron
}

/// A downloadable GGML speech model hosted on Hugging Face.
struct WhisperModel: Identifiable, Equatable {
    let id: String
    let displayName: String
    let approximateSizeMB: Int
    let englishOnly: Bool
    var engine: LocalModelEngine = .whisper
    /// One line of plain-language guidance shown on the model card.
    var note: String = ""
    /// Shown as one of the four cards before "Show all models" is expanded.
    var isRecommended: Bool = false

    var fileName: String { "ggml-\(id).bin" }

    var downloadURL: URL {
        switch engine {
        case .whisper:
            return URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
        case .parakeet:
            return URL(string: "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/\(fileName)")!
        case .nemotron:
            // Never fetched directly; the FluidAudio package downloads its
            // own file set. This is the model's page, for anything that
            // wants a link.
            return URL(string: "https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML")!
        }
    }

    var sizeLabel: String {
        approximateSizeMB >= 1000
            ? String(format: "%.1f GB", Double(approximateSizeMB) / 1000)
            : "\(approximateSizeMB) MB"
    }
}

enum WhisperModelCatalog {
    /// The engine recommended on this particular Mac.
    ///
    /// Parakeet is the better default where it can be used at all: faster,
    /// and accurate enough to stand beside Whisper Turbo. But it knows 25
    /// European languages and nothing else, so recommending it to somebody
    /// whose Mac is set to Japanese recommends an app that cannot transcribe
    /// a word they say. Whisper knows 99 languages and is the honest answer
    /// there.
    ///
    /// Read from the Mac's own language rather than its region, because it is
    /// the language somebody is likely to dictate in. A guess either way is
    /// only a starting point: both engines are in the same list and the
    /// choice is one click.
    static var recommendedEngine: LocalModelEngine {
        let code = Locale.current.language.languageCode?.identifier.lowercased() ?? ""
        return SpokenLanguageCatalog.parakeetLanguageCodes.contains(code) ? .parakeet : .whisper
    }

    static var defaultModelID: String {
        models.first { $0.engine == recommendedEngine && $0.isRecommended }?.id
            ?? "parakeet-tdt-0.6b-v3-q8_0"
    }

    /// Ordered as the model list shows them: the four recommended models
    /// first, then the rest.
    static let models: [WhisperModel] = [
        WhisperModel(
            id: "parakeet-tdt-0.6b-v3-q8_0", displayName: "Parakeet v3 (quantized)",
            approximateSizeMB: 637, englishOnly: false, engine: .parakeet,
            note: "Recommended. Fast, private transcription in 25 languages, with a smaller download than the 16-bit version.", isRecommended: true
        ),
        WhisperModel(
            id: "large-v3-turbo-q5_0", displayName: "Large v3 Turbo (quantized)",
            approximateSizeMB: 574, englishOnly: false,
            note: "100 languages. A good balance of accuracy and download size; recommended for most Whisper users.", isRecommended: true
        ),
        WhisperModel(
            id: "base", displayName: "Base", approximateSizeMB: 148, englishOnly: false,
            note: "99 languages. A small download for everyday dictation; expect more corrections than with Turbo.", isRecommended: true
        ),
        WhisperModel(
            id: "tiny", displayName: "Tiny", approximateSizeMB: 78, englishOnly: false,
            note: "99 languages. The smallest, quickest Whisper option, with the most transcription errors.", isRecommended: true
        ),
        // Two builds of the same model, differing only in how much audio they
        // take at a time. Named for how they feel to dictate into rather than
        // for the number behind them: nobody choosing a dictation setting is
        // thinking in milliseconds of encoder chunk.
        WhisperModel(
            id: NemotronEngine.modelID, displayName: "Live",
            approximateSizeMB: 672, englishOnly: false, engine: .nemotron,
            note: "100+ languages. Preview words about a second after you speak; choose this for quicker live feedback.",
            isRecommended: true
        ),
        WhisperModel(
            id: NemotronEngine.steadyModelID, displayName: "Live, steadier",
            approximateSizeMB: 672, englishOnly: false, engine: .nemotron,
            note: "100+ languages. Preview words about two seconds later. Processes Chinese and Japanese more efficiently, with similar accuracy to Live.",
            isRecommended: true
        ),
        WhisperModel(
            id: "parakeet-tdt-0.6b-v3-f16", displayName: "Parakeet v3",
            approximateSizeMB: 1197, englishOnly: false, engine: .parakeet,
            note: "25 languages. A larger, 16-bit download; a clear accuracy advantage over the smaller version has not been established."
        ),
        WhisperModel(
            id: "large-v3-turbo", displayName: "Large v3 Turbo",
            approximateSizeMB: 1620, englishOnly: false,
            note: "100 languages. The larger, uncompressed Turbo model. Choose the quantized version for a smaller download."
        ),
        WhisperModel(
            id: "medium", displayName: "Medium", approximateSizeMB: 1530, englishOnly: false,
            note: "99 languages. More accurate than Small, but slower and a larger download. Turbo is a better starting point for most Macs."
        ),
        WhisperModel(
            id: "small", displayName: "Small", approximateSizeMB: 488, englishOnly: false,
            note: "99 languages. Fewer errors than Base or Tiny, with a larger download and slower processing."
        ),
        WhisperModel(
            id: "small.en", displayName: "Small (English)", approximateSizeMB: 488, englishOnly: true,
            note: "English only. A mid-sized option with fewer errors than Base or Tiny; choose Turbo for stronger accuracy."
        ),
        WhisperModel(
            id: "base.en", displayName: "Base (English)", approximateSizeMB: 148, englishOnly: true,
            note: "English only. A small download, generally more accurate for English than multilingual Base."
        ),
        WhisperModel(
            id: "tiny.en", displayName: "Tiny (English)", approximateSizeMB: 78, englishOnly: true,
            note: "English only. The smallest download, generally more accurate for English than multilingual Tiny."
        ),
    ]

    static let recommended: [WhisperModel] = models.filter(\.isRecommended)

    static func model(withID id: String) -> WhisperModel? {
        models.first { $0.id == id }
    }
}
