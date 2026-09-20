import Foundation

/// Changing selected text by saying what to change.
///
/// The selection is read from the focused app by copying it, the user says an
/// instruction, and a model applies one to the other. That makes the spoken
/// words an instruction rather than content, which is the whole difference
/// between this and an ordinary dictation, and the reason the profile's own
/// prompt is set aside for it: a cleanup prompt would tidy the instruction
/// instead of carrying it out.
enum VoiceEdit {
    /// Deliberately firm about two things. The model must return the changed
    /// passage and nothing else, because the result is pasted straight over the
    /// user's selection with no chance to review it. And it must not answer the
    /// instruction: told "make this a question", it should rewrite the passage
    /// as a question rather than reply to one.
    static let instruction = """
        You are editing a passage of text on behalf of someone who dictated \
        an instruction about it. Apply the instruction to the passage and \
        return the edited passage only.

        Never answer or comment on the instruction; carry it out. Never \
        explain what you changed. Keep the author's voice, and change \
        nothing the instruction did not ask you to change. Preserve the \
        surrounding punctuation and capitalisation unless the instruction \
        is about those. If the instruction cannot be applied, return the \
        passage unchanged.
        """

    /// The two parts, labelled. A model handed them run together cannot tell
    /// reliably where one ends, and would sometimes edit the instruction into
    /// the text.
    /// Puts `edited` back inside the whitespace `original` was selected with.
    ///
    /// A selection often takes in more than its words: the spaces that indent
    /// it, the newline that ends its paragraph. Every rewrite path trims what
    /// it returns, which is right for a dictation and wrong here, because the
    /// result replaces the selection exactly. Without this, editing a paragraph
    /// runs it into the next one.
    static func rewrapped(_ edited: String, like original: String) -> String {
        let leading = original.prefix { $0.isWhitespace || $0.isNewline }
        let trailing = String(original.reversed().prefix { $0.isWhitespace || $0.isNewline }.reversed())
        let core = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty else { return edited }
        return leading + core + trailing
    }

    static func message(selection: String, instruction: String) -> String {
        """
        PASSAGE:
        \(selection)

        INSTRUCTION:
        \(instruction)
        """
    }
}
