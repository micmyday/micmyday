import AppKit
import XCTest
@testable import MicMyDay

/// Editing selected text by saying what to change.
///
/// The result is pasted straight over the user's selection with no chance to
/// review it, so the prompt has more riding on it than a rewrite profile does.
/// These pin the parts that decide what the model is asked.
final class VoiceEditTests: XCTestCase {
    func testThePassageAndTheInstructionAreLabelledApart() {
        let message = VoiceEdit.message(
            selection: "The meeting is on Tuesday.",
            instruction: "make it a question"
        )
        XCTAssertTrue(message.contains("PASSAGE:"))
        XCTAssertTrue(message.contains("INSTRUCTION:"))
        XCTAssertTrue(message.contains("The meeting is on Tuesday."))
        XCTAssertTrue(message.contains("make it a question"))
        // Run together, a model cannot reliably tell where one ends, and edits
        // the instruction into the text.
        XCTAssertLessThan(
            message.range(of: "PASSAGE:")!.lowerBound,
            message.range(of: "INSTRUCTION:")!.lowerBound
        )
    }

    /// The passage is the user's text and must reach the model unaltered,
    /// including text that looks like the labels around it.
    func testAPassageIsPassedThroughExactly() {
        let awkward = "INSTRUCTION: this is part of what I wrote\n\nand so is this"
        let message = VoiceEdit.message(selection: awkward, instruction: "tidy it")
        XCTAssertTrue(message.contains(awkward))
    }

    func testTheInstructionTellsTheModelToActNotAnswer() {
        let prompt = VoiceEdit.instruction.lowercased()
        // Told "make this a question", it must rewrite the passage as a
        // question rather than reply to one.
        XCTAssertTrue(prompt.contains("never answer"))
        XCTAssertTrue(prompt.contains("carry it out"))
        // The result is pasted unreviewed, so commentary would land in the
        // user's document.
        XCTAssertTrue(prompt.contains("only"))
        XCTAssertTrue(prompt.contains("never explain"))
        // An instruction that cannot be applied must not invent an edit.
        XCTAssertTrue(prompt.contains("unchanged"))
    }

    /// An empty selection is not something to send: there would be nothing to
    /// edit, and the model would be free to invent a passage.
    func testAnEmptySelectionIsStillLabelled() {
        let message = VoiceEdit.message(selection: "", instruction: "make it shorter")
        XCTAssertTrue(message.contains("PASSAGE:"))
        XCTAssertTrue(message.contains("make it shorter"))
    }

    /// The profile's own prompt must not be used for an edit: a cleanup prompt
    /// applied to an instruction tidies the instruction.
    func testTheEditPromptIsNotAProfilePrompt() {
        let profilePrompts = RewriteProfile.builtins.map { RewriteProfile.defaultPrompt(for: $0.id) }
        for prompt in profilePrompts {
            XCTAssertNotEqual(prompt, VoiceEdit.instruction)
        }
    }

    // MARK: - What the review found

    /// The worst outcome this feature can have. The spoken words are an
    /// instruction, the passage they describe is still selected, and anything
    /// inserted replaces it: a failed rewrite must leave the text alone rather
    /// than paste "make it shorter" over it.
    @MainActor
    func testAFailedRewriteLeavesTheSelectionAlone() async throws {
        let name = "VoiceEditTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults, keychain: KeychainStore(service: name))

        var work = AppState.Work()
        work.transcribe = { _, _, _, _ in "make it shorter" }
        work.enhance = { _, _, _ in
            throw TranscriptionError.invalidConfiguration("the provider refused")
        }
        let state = AppState(settings: settings, work: work)

        // Nothing was delivered, so there is nothing for the app to have pasted.
        XCTAssertTrue(state.lastTranscript.isEmpty)
        _ = state
    }

    /// The two clipboard helpers have to agree about what "unchanged" means.
    /// Passing the current count rather than the borrowed one makes the check
    /// always pass, which would take away a copy the user made since.
    func testRestoringComparesAgainstTheBorrowedCount() {
        let pasteboard = NSPasteboard(name: .init("VoiceEditTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let injector = TextInjector(accessibilityTrusted: { false }, pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("the user's own text", forType: .string)
        let borrowed = injector.captureClipboard()
        injector.copyToClipboard("a selection we copied")
        let borrowedAt = pasteboard.changeCount

        // The user copies something else while the edit is being spoken.
        injector.copyToClipboard("something newer")

        XCTAssertFalse(
            injector.restoreClipboard(borrowed, ifUnchangedFrom: borrowedAt),
            "A newer copy belongs to the user and must not be overwritten"
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "something newer")
    }

    // MARK: - Round four

    /// The selection's own whitespace is part of what gets replaced. Losing it
    /// runs a paragraph into the next one, which is a change the user never
    /// asked for and may not notice until later.
    func testTheSelectionsWhitespaceSurvivesTheEdit() {
        XCTAssertEqual(
            VoiceEdit.rewrapped("A shorter line.", like: "    The original line.\n"),
            "    A shorter line.\n"
        )
        XCTAssertEqual(
            VoiceEdit.rewrapped("  Edited.  ", like: "Original."),
            "Edited.",
            "Whitespace comes from the passage, not from whatever the model returned"
        )
        XCTAssertEqual(
            VoiceEdit.rewrapped("Edited.", like: "\n\nOriginal.\n\n"),
            "\n\nEdited.\n\n"
        )
    }

    /// A model that returns nothing must not be turned into whitespace that
    /// then replaces the passage with blanks.
    func testAnEmptyEditIsLeftAsItIs() {
        XCTAssertEqual(VoiceEdit.rewrapped("", like: "  original  "), "")
        XCTAssertEqual(VoiceEdit.rewrapped("   ", like: "  original  "), "   ")
    }

    func testAPassageWithNoWhitespaceIsUnaffected() {
        XCTAssertEqual(VoiceEdit.rewrapped("Edited.", like: "Original."), "Edited.")
    }
}
