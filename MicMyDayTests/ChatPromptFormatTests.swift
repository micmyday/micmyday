import XCTest
@testable import MicMyDay

/// The formats are written out by hand, so they are worth pinning down.
///
/// Each expectation below is what the model's own embedded Jinja template
/// produces for a system message, a user message and an empty assistant turn.
/// Getting one of these subtly wrong does not fail loudly: the model answers,
/// just worse, which is the kind of fault nobody reports.
final class ChatPromptFormatTests: XCTestCase {
    func testChatMLMatchesTheTemplateQwenShipsWith() {
        let prompt = ChatPromptFormat.chatML.prompt(system: "Tidy it.", user: "hello there")
        XCTAssertEqual(
            prompt,
            "<|im_start|>system\nTidy it.<|im_end|>\n"
                + "<|im_start|>user\nhello there<|im_end|>\n"
                + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        )
    }

    /// The closed thinking block is the whole reason these models are usable
    /// for this. Without it a reasoning model asked to tidy one sentence
    /// deliberates until the token budget runs out and returns nothing at all.
    func testChatMLClosesTheThinkingBlockItOpens() {
        let prompt = ChatPromptFormat.chatML.prompt(system: "s", user: "u")
        XCTAssertTrue(prompt.hasSuffix("<think>\n\n</think>\n\n"))
        XCTAssertEqual(prompt.components(separatedBy: "<think>").count - 1, 1)
        XCTAssertEqual(prompt.components(separatedBy: "</think>").count - 1, 1)
    }

    func testGemmaUsesItsOwnAsymmetricTurnMarkers() {
        let prompt = ChatPromptFormat.gemma4.prompt(system: "Tidy it.", user: "hello there")
        XCTAssertEqual(
            prompt,
            "<|turn>system\nTidy it.<turn|>\n"
                + "<|turn>user\nhello there<turn|>\n"
                + "<|turn>model\n"
        )
    }

    /// Opening and closing markers are not mirror images in Gemma 4, and
    /// writing the closing one as `<|turn|>` is the obvious slip.
    func testGemmaOpeningAndClosingMarkersAreNotSwapped() {
        let prompt = ChatPromptFormat.gemma4.prompt(system: "s", user: "u")
        XCTAssertEqual(prompt.components(separatedBy: "<|turn>").count - 1, 3)
        XCTAssertEqual(prompt.components(separatedBy: "<turn|>").count - 1, 2)
        XCTAssertFalse(prompt.contains("<|turn|>"))
    }

    /// Tokenizing adds whatever beginning-of-sequence token the model's own
    /// configuration calls for. Writing one here would duplicate it.
    func testNoFormatWritesABeginningOfSequenceToken() {
        for format in [ChatPromptFormat.chatML, .gemma4] {
            let prompt = format.prompt(system: "s", user: "u")
            XCTAssertFalse(prompt.contains("<bos>"), "\(format)")
            XCTAssertFalse(prompt.contains("<|begin_of_text|>"), "\(format)")
            XCTAssertFalse(prompt.hasPrefix("<s>"), "\(format)")
        }
    }

    /// A dictation is the user's words and must reach the model unaltered.
    /// Only the instruction, which we wrote, is tidied.
    func testTheTranscriptIsPassedThroughExactly() {
        let spoken = "  he said \"don't\" ... and <then> left  "
        for format in [ChatPromptFormat.chatML, .gemma4] {
            XCTAssertTrue(
                format.prompt(system: "  padded  ", user: spoken).contains(spoken),
                "\(format) altered the transcript"
            )
            XCTAssertFalse(format.prompt(system: "  padded  ", user: spoken).contains("  padded  "))
        }
    }

    /// Every model offered has to have a format that was actually checked
    /// against its template, so adding one cannot quietly inherit another's.
    func testEveryDownloadableModelDeclaresAFormat() {
        for model in RewriteModelCatalog.downloadable {
            guard let download = model.download else { continue }
            switch download.format {
            case .chatML:
                XCTAssertTrue(model.id.hasPrefix("qwen"), "\(model.id) claims ChatML")
            case .gemma4:
                XCTAssertTrue(model.id.hasPrefix("gemma4"), "\(model.id) claims the Gemma 4 format")
            }
        }
    }
}
