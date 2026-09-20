import XCTest
@testable import MicMyDay

/// Runs a real rewrite through llama.cpp, on a real model file.
///
/// Skipped unless a model has been downloaded, because a test suite must not
/// fetch gigabytes. When one is present this is the only thing that proves the
/// whole path works: the C shim, the chat template, the token loop and the
/// text that comes back. Everything else about local rewriting can be checked
/// without a model, and is, in LocalRewriteModelTests.
///
/// Safe to run anywhere: inference is local and has no side effect outside this
/// process. Nothing here can paste, type, or reach the network.
final class LlamaRewriteEndToEndTests: XCTestCase {
    /// Every model present on this machine, smallest first. Each prompt format
    /// has to be proved against the model it was written for: a format that is
    /// subtly wrong does not fail, it just answers worse.
    private func installedModels() throws -> [(path: String, format: ChatPromptFormat, name: String)] {
        let found = RewriteModelCatalog.downloadable
            .filter { RewriteModelManager.isInstalled(modelID: $0.id) }
            .sorted { ($0.download?.megabytes ?? 0) < ($1.download?.megabytes ?? 0) }
            .compactMap { model -> (String, ChatPromptFormat, String)? in
                guard let download = model.download,
                      let url = RewriteModelManager.localURL(forModelID: model.id) else { return nil }
                return (url.path, download.format, model.displayName)
            }
        if found.isEmpty { throw XCTSkip("No rewrite model is downloaded on this machine") }
        return found
    }

    /// The smallest, for the tests where one is enough.
    private func installed() throws -> (path: String, format: ChatPromptFormat, name: String) {
        try installedModels()[0]
    }

    func testEveryInstalledModelRewritesATranscriptIntoCleanText() async throws {
        for model in try installedModels() {
            LlamaCppEngine.shared.unloadIfCached(modelPath: model.path)
            let began = Date()
            let rewritten = try await LlamaCppEngine.shared.rewrite(
                transcript: "so um i think we should uh probably ship it on friday if the tests pass",
                systemPrompt: "Clean up this dictated text. Fix grammar and punctuation. Keep the meaning and the speaker's words. Reply with the cleaned text only.",
                modelPath: model.path,
                format: model.format
            )
            print("### \(model.name) [\(String(format: "%.2f", Date().timeIntervalSince(began)))s]: \(rewritten)")

            XCTAssertFalse(rewritten.isEmpty, model.name)
            // Something came back that is still about what was said. Asserting
            // an exact string would be asserting the model's taste, which
            // changes with every release of it.
            XCTAssertTrue(
                rewritten.lowercased().contains("friday"),
                "\(model.name) lost the subject of the sentence: \(rewritten)"
            )
            XCTAssertFalse(rewritten.contains("<think>"), "\(model.name) leaked reasoning: \(rewritten)")
            // The surest sign of a wrong prompt format: the model answers, but
            // starts talking in its own turn markers.
            XCTAssertFalse(rewritten.contains("<|"), "\(model.name) leaked turn markers: \(rewritten)")
            XCTAssertFalse(rewritten.contains("turn|>"), "\(model.name) leaked turn markers: \(rewritten)")
            XCTAssertLessThan(rewritten.count, 600, "\(model.name) produced an essay: \(rewritten)")
        }
    }

    /// A second rewrite must not be coloured by the first. The engine clears
    /// the model's memory between them, and this is what would catch it if it
    /// stopped doing so.
    func testASecondRewriteDoesNotInheritTheFirst() async throws {
        let model = try installed()
        let instruction = "Reply with the cleaned up text only."

        _ = try await LlamaCppEngine.shared.rewrite(
            transcript: "the password for the vault is hunter two",
            systemPrompt: instruction,
            modelPath: model.path,
                format: model.format
        )
        let second = try await LlamaCppEngine.shared.rewrite(
            transcript: "lets meet at the cafe at noon",
            systemPrompt: instruction,
            modelPath: model.path,
                format: model.format
        )
        XCTAssertFalse(
            second.lowercased().contains("hunter"),
            "The previous transcript bled into this one: \(second)"
        )
    }

    /// Cancelling has to stop generation rather than run it to completion and
    /// throw the result away, which is what made this worth testing: the flag
    /// has to cross from Swift concurrency onto a dispatch queue.
    func testCancellingStopsGeneration() async throws {
        let model = try installed()
        // Loaded first, so what is being timed is generation and not a
        // multi-gigabyte read from disk.
        try await LlamaCppEngine.shared.preload(modelPath: model.path)

        let task = Task {
            try await LlamaCppEngine.shared.rewrite(
                transcript: String(repeating: "tell me about the history of the bicycle in detail. ", count: 8),
                systemPrompt: "Expand this at length.",
                modelPath: model.path,
                format: model.format
            )
        }
        // Long enough that generation is genuinely under way.
        try await Task.sleep(for: .milliseconds(400))
        let started = Date()
        task.cancel()

        do {
            _ = try await task.value
            // Finishing legitimately before the cancel landed is possible on a
            // fast machine and is not a failure.
        } catch is CancellationError {
            XCTAssertLessThan(
                Date().timeIntervalSince(started), 5,
                "Cancellation was noticed, but only after generation had run on"
            )
        }
    }

    /// Reading a multi-gigabyte model can take twenty seconds from cold, and
    /// used to be uninterruptible: Escape returned the app to idle while the
    /// engine's queue stayed occupied loading a model for a dictation that no
    /// longer existed. llama.cpp is now asked, as it reads, whether to stop.
    func testCancellingDuringAColdLoadStopsTheRead() async throws {
        let model = try installed()
        // Cold on purpose: this is the path being tested.
        LlamaCppEngine.shared.unloadIfCached(modelPath: model.path)

        let started = Date()
        let task = Task {
            try await LlamaCppEngine.shared.rewrite(
                transcript: "a short sentence to tidy",
                systemPrompt: "Reply with the cleaned text only.",
                modelPath: model.path,
                format: model.format
            )
        }
        // Long enough to be inside the read, short enough to be well before
        // the end of it.
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()

        do {
            _ = try await task.value
            // A warm page cache can finish the load and the rewrite inside the
            // window. That is not a failure, only an untested run.
        } catch is CancellationError {
            XCTAssertLessThan(
                Date().timeIntervalSince(started), 12,
                "Cancellation was noticed only after the whole model had been read"
            )
        }

        // Whatever happened, the engine has to be usable afterwards: an
        // abandoned load must not leave a half-built session behind.
        let after = try await LlamaCppEngine.shared.rewrite(
            transcript: "another short sentence to tidy",
            systemPrompt: "Reply with the cleaned text only.",
            modelPath: model.path,
            format: model.format
        )
        XCTAssertFalse(after.isEmpty, "The engine did not recover from a cancelled load")
    }

    /// The token counts are the same numbers a llama.cpp server reports, so
    /// they have to be real rather than plumbed. Checked against the text that
    /// was actually produced: a count that does not move with the output is a
    /// count of nothing.
    func testTokenCountsDescribeTheWorkThatWasDone() async throws {
        let model = try installed()

        var shortIn = 0, shortOut = 0, shortSeconds = 0.0
        let short = try await LlamaCppEngine.shared.rewrite(
            transcript: "fix this",
            systemPrompt: "Reply with the cleaned text only.",
            modelPath: model.path,
            format: model.format,
            counted: { shortIn = $0; shortOut = $1; shortSeconds = $2 }
        )

        var longIn = 0, longOut = 0, longSeconds = 0.0
        _ = try await LlamaCppEngine.shared.rewrite(
            transcript: String(repeating: "this sentence needs tidying up a little. ", count: 20),
            systemPrompt: "Reply with the cleaned text only.",
            modelPath: model.path,
            format: model.format,
            counted: { longIn = $0; longOut = $1; longSeconds = $2 }
        )

        XCTAssertGreaterThan(shortIn, 0, "A prompt was tokenized, so it cannot be zero tokens")
        XCTAssertGreaterThan(shortOut, 0, "Text came back, so something was generated")
        // Tokens are not words, but a prompt twenty times longer cannot be the
        // same size, and this is what catches a count wired to the wrong thing.
        XCTAssertGreaterThan(longIn, shortIn * 2, "A much longer transcript read far more tokens")
        // A rough sanity bound rather than an equality: one token is several
        // characters, never more than the character count.
        XCTAssertLessThan(shortOut, short.count, "More tokens than characters is impossible")
        XCTAssertGreaterThan(shortOut, short.count / 20, "Implausibly few tokens for this much text")

        // Time is measured around the generation, so it must be real and must
        // not include the model load that happened before the first call.
        XCTAssertGreaterThan(shortSeconds, 0, "A rewrite that took no time did not happen")
        XCTAssertLessThan(shortSeconds, 30, "This looks like the model load leaked into the timing")
        XCTAssertGreaterThan(longSeconds, 0)
    }

    /// The voice-edit prompt, run through a real model.
    ///
    /// Asserting the wording of a prompt proves nothing about whether a model
    /// obeys it, and this one's output is pasted straight over the user's
    /// selection. The trap it has to avoid is answering the instruction instead
    /// of carrying it out.
    func testAVoiceEditChangesThePassageRatherThanAnsweringTheInstruction() async throws {
        let model = try installed()
        let edited = try await LlamaCppEngine.shared.rewrite(
            transcript: VoiceEdit.message(
                selection: "The meeting is on Tuesday.",
                instruction: "turn this into a question"
            ),
            systemPrompt: VoiceEdit.instruction,
            modelPath: model.path,
            format: model.format
        )
        print("### edit: \(edited)")

        XCTAssertTrue(
            edited.lowercased().contains("tuesday"),
            "The edit lost the subject of the passage: \(edited)"
        )
        XCTAssertTrue(edited.contains("?"), "Asked for a question, got: \(edited)")
        // Carrying out the instruction, not replying to it.
        XCTAssertFalse(edited.contains("PASSAGE:"), "The scaffolding leaked: \(edited)")
        XCTAssertFalse(edited.contains("INSTRUCTION:"), "The scaffolding leaked: \(edited)")
        XCTAssertLessThan(edited.count, 200, "This should be one sentence, not an explanation: \(edited)")
    }

    /// An instruction it cannot apply must leave the passage alone rather than
    /// invent an edit, because the result replaces what the user selected.
    func testAnImpossibleInstructionLeavesThePassageAlone() async throws {
        let model = try installed()
        let passage = "The meeting is on Tuesday."
        let edited = try await LlamaCppEngine.shared.rewrite(
            transcript: VoiceEdit.message(selection: passage, instruction: "translate it into the colour blue"),
            systemPrompt: VoiceEdit.instruction,
            modelPath: model.path,
            format: model.format
        )
        print("### impossible: \(edited)")
        XCTAssertTrue(
            edited.lowercased().contains("tuesday") || edited.lowercased().contains("meeting"),
            "The passage was replaced by something unrelated: \(edited)"
        )
    }
}
