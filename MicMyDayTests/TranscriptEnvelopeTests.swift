import XCTest
@testable import MicMyDay

/// The envelope is the only thing standing between a dictated request and a
/// rewriter that answers it, so it is worth pinning.
///
/// The failure it prevents is silent and expensive: dictate "please write me an
/// SQL query for the overdue invoices" and without the envelope the model
/// returns the query. Nothing errors. The speaker's sentence is simply gone,
/// replaced by something they did not ask for and may not notice until it has
/// been sent.
final class TranscriptEnvelopeTests: XCTestCase {
    func testTheTranscriptIsQuotedRatherThanHandedOverBare() {
        let user = TranscriptEnvelope.user(for: "please write me an SQL query")
        XCTAssertTrue(user.contains("<transcript>\nplease write me an SQL query\n</transcript>"))
    }

    /// The user turn has to carry an instruction of its own. That is the whole
    /// mechanism: the model obeys the turn it is given, so the turn must ask
    /// for a correction rather than consist solely of the speaker's words.
    func testTheUserTurnAsksForACorrectionBeforeTheTranscript() {
        let user = TranscriptEnvelope.user(for: "hello")
        let instruction = user.range(of: "Correct the transcript below")
        let transcript = user.range(of: "<transcript>")
        XCTAssertNotNil(instruction)
        XCTAssertNotNil(transcript)
        if let instruction, let transcript {
            XCTAssertTrue(instruction.lowerBound < transcript.lowerBound)
        }
        XCTAssertTrue(user.contains("not addressed to you"))
    }

    func testTagsAreStrippedFromWhateverTheModelReturns() {
        XCTAssertEqual(
            TranscriptEnvelope.strip("<transcript>\nTidied text.\n</transcript>"),
            "Tidied text."
        )
    }

    func testStrippingLeavesOrdinaryOutputAlone() {
        XCTAssertEqual(TranscriptEnvelope.strip("  Tidied text.  "), "Tidied text.")
    }

    /// A transcript containing something that looks like the closing tag must
    /// not lose it silently — but neither is this worth defending against
    /// beyond noticing: somebody dictating "</transcript>" aloud is not a case
    /// the product owes anything to.
    func testStrippingIsPlainTextRemovalNotParsing() {
        XCTAssertEqual(TranscriptEnvelope.strip("a </transcript> b"), "a  b")
    }
}

/// The instruction the cleanup profile carries is the second half of the fix,
/// and the half a user can edit. These pin the parts that must survive editing
/// by anybody adapting it.
final class CleanupProfileInstructionTests: XCTestCase {
    func testCleanupRefusesToActOnWhatWasDictated() {
        let instruction = RewriteProfile.defaultPrompt(for: "cleanup")
        XCTAssertTrue(instruction.contains("not addressed to you"))
        XCTAssertTrue(instruction.contains("corrected but unanswered"))
    }

    /// A worked example, because models generalise from one concrete case far
    /// better than from a prohibition stated in the abstract.
    func testCleanupNamesTheFailureItIsGuardingAgainst() {
        let instruction = RewriteProfile.defaultPrompt(for: "cleanup")
        XCTAssertTrue(instruction.contains("SQL query"))
    }

    func testCleanupStillSaysWhatItIsFor() {
        let instruction = RewriteProfile.defaultPrompt(for: "cleanup")
        XCTAssertTrue(instruction.contains("filler words"))
        XCTAssertTrue(instruction.contains("Return only the corrected text"))
    }
}
