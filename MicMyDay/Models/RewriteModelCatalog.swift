import Foundation

/// A model that can rewrite a transcript without leaving the Mac.
///
/// Two kinds live in one list because that is the choice as the user
/// experiences it: "which model on this Mac cleans up my words". One of them
/// happens to be built into macOS and needs no download, and the rest are GGUF
/// files run by llama.cpp. Splitting them into separate providers would have
/// made the user answer a question about our implementation before they could
/// answer the one they actually have.
struct LocalRewriteModel: Identifiable, Equatable {
    let id: String
    let displayName: String
    /// One line of plain-language guidance shown on the model row.
    let note: String
    /// nil for the model built into macOS, which is never downloaded.
    let download: Download?
    /// Relative guidance for choosing a rewrite model. Zero means unrated.
    var quality: Int = 0
    var speed: Int = 0
    /// The model highlighted as the suggested starting point.
    var isRecommended: Bool = false

    struct Download: Equatable {
        /// Hugging Face repository, as `owner/name`.
        let repository: String
        /// The file within that repository. Also the name on disk, so two
        /// models can never collide.
        let file: String
        /// How this model expects to be prompted. See `ChatPromptFormat`.
        let format: ChatPromptFormat
        /// Measured from the server rather than estimated, because this number
        /// is the one thing the user is agreeing to when they tap Get.
        let megabytes: Int

        var url: URL {
            URL(string: "https://huggingface.co/\(repository)/resolve/main/\(file)")!
        }
    }

    /// True for the model macOS provides.
    var isAppleBuiltIn: Bool { download == nil }

    var sizeLabel: String {
        guard let download else { return "Built into macOS" }
        return download.megabytes >= 1000
            ? String(format: "%.1f GB", Double(download.megabytes) / 1000)
            : "\(download.megabytes) MB"
    }
}

enum RewriteModelCatalog {
    /// The identifier stored in settings for Apple's own model. A name rather
    /// than an empty string so a stored value is always readable.
    static let appleModelID = "apple-built-in"

    /// Used for new setups and unknown saved IDs; existing selections persist.
    static let defaultModelID = "gemma4-e4b"

    static let ratingsHelp = "Relative ratings for transcript rewriting. Quality reflects instruction following and text refinement; speed is an estimate for local use."

    // Quality follows the product's rewrite preference order, not a conversion
    // of general benchmark scores. Speed is an initial estimate based on the
    // models' effective compute sizes, not a measured Mac latency benchmark.
    // https://ai.google.dev/gemma/docs/core/model_card_4
    // https://huggingface.co/Qwen/Qwen3.5-4B
    // https://huggingface.co/Qwen/Qwen3.5-2B
    // Apple's OS-managed model has no directly comparable rewrite rating yet.

    /// Ordered as the list shows them: recommended first, then the rest.
    ///
    /// Every download is a 4-bit quantisation, which is the point on the curve
    /// where a model still writes well and still fits in memory alongside
    /// whatever else the user is running. Sizes were read from Hugging Face
    /// rather than estimated. All four are Apache-2.0, which matters because
    /// this app is sold: a model under a licence with use restrictions would
    /// put a condition on the user that buying the app did not.
    static let models: [LocalRewriteModel] = [
        LocalRewriteModel(
            id: "gemma4-e4b",
            displayName: "Gemma 4 E4B",
            note: "Our top choice for detailed rewrites and following instructions.",
            download: .init(
                repository: "unsloth/gemma-4-E4B-it-qat-GGUF",
                file: "gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf",
                format: .gemma4,
                megabytes: 4215
            ),
            quality: 4,
            speed: 2,
            isRecommended: true
        ),
        LocalRewriteModel(
            id: "qwen3.5-4b",
            displayName: "Qwen3.5 4B",
            note: "A larger Qwen model for more detailed rewrite instructions.",
            download: .init(
                repository: "unsloth/Qwen3.5-4B-GGUF",
                file: "Qwen3.5-4B-Q4_K_M.gguf",
                format: .chatML,
                megabytes: 2740
            ),
            quality: 3,
            speed: 2
        ),
        LocalRewriteModel(
            id: "gemma4-e2b",
            displayName: "Gemma 4 E2B",
            note: "A compact Google model for tone and phrasing.",
            download: .init(
                repository: "unsloth/gemma-4-E2B-it-GGUF",
                file: "gemma-4-E2B-it-Q4_K_M.gguf",
                format: .gemma4,
                megabytes: 3106
            ),
            quality: 2,
            speed: 3
        ),
        LocalRewriteModel(
            id: "qwen3.5-2b",
            displayName: "Qwen3.5 2B",
            note: "The smallest download for everyday transcript cleanup.",
            download: .init(
                repository: "unsloth/Qwen3.5-2B-GGUF",
                file: "Qwen3.5-2B-Q4_K_M.gguf",
                format: .chatML,
                megabytes: 1280
            ),
            quality: 1,
            speed: 4
        ),
        LocalRewriteModel(
            id: appleModelID,
            displayName: "Apple built-in",
            note: "Uses Apple Intelligence on macOS 26 or later.",
            download: nil
        ),
    ]

    static var recommended: [LocalRewriteModel] { models.filter(\.isRecommended) }

    /// Every model except Apple's, which is the set that can be downloaded.
    static var downloadable: [LocalRewriteModel] { models.filter { !$0.isAppleBuiltIn } }

    static func model(withID id: String) -> LocalRewriteModel? {
        models.first { $0.id == id }
    }
}
