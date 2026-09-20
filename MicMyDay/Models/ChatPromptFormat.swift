import Foundation

/// How a particular model expects a system instruction and a user message to be
/// laid out before it will answer.
///
/// Written out here rather than taken from the model file, because the C helper
/// that reads a GGUF's template, `llama_chat_apply_template`, does not run the
/// Jinja it finds there. It matches against a fixed list of older formats and
/// returns a failure for anything it does not recognise, which is every model in
/// this catalogue: one of them fails outright, and the other is quietly given a
/// format that is close to, but not, what it was trained on.
///
/// The formats below were read out of each model's own embedded template, so
/// they are what the model was actually trained on, and each one is checked by
/// a test against the strings that template produces.
enum ChatPromptFormat {
    /// `<|im_start|>role` … `<|im_end|>`, used by Qwen among many others.
    ///
    /// The assistant turn is opened with an already-closed thinking block. That
    /// is not a trick: it is what the model's own template emits when thinking
    /// is switched off, and switching it off matters here. These are reasoning
    /// models, and asked to tidy a sentence they will otherwise spend thousands
    /// of tokens deliberating about it, run out of budget, and return nothing.
    case chatML

    /// Gemma 4's turn markers. Note the asymmetry, which is the model's own:
    /// a turn opens with `<|turn>` and closes with `<turn|>`.
    case gemma4

    /// No beginning-of-sequence token is written here. Tokenizing adds whatever
    /// the model's own configuration asks for, so writing one would either
    /// duplicate it or contradict it.
    func prompt(system: String, user: String) -> String {
        let system = system.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .chatML:
            return "<|im_start|>system\n\(system)<|im_end|>\n"
                + "<|im_start|>user\n\(user)<|im_end|>\n"
                + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        case .gemma4:
            return "<|turn>system\n\(system)<turn|>\n"
                + "<|turn>user\n\(user)<turn|>\n"
                + "<|turn>model\n"
        }
    }
}
