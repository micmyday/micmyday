import AppKit
import XCTest
@testable import MicMyDay

/// Giving the clipboard back after a dictation has borrowed it.
///
/// The failure this guards against is quiet: a user copies something, dictates,
/// and finds their copy gone. Nothing reports it, so it has to be tested.
final class ClipboardRestoreTests: XCTestCase {
    /// A pasteboard of this app's own, never the general one: a test must not
    /// reach out and take over the clipboard of whoever is running it.
    private var pasteboard: NSPasteboard!
    private var injector: TextInjector!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: .init("MicMyDayTests.\(UUID().uuidString)"))
        injector = TextInjector(accessibilityTrusted: { false }, pasteboard: pasteboard)
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    func testPlainTextComesBack() {
        pasteboard.clearContents()
        pasteboard.setString("something the user copied", forType: .string)

        let borrowed = injector.captureClipboard()
        injector.copyToClipboard("a transcript")
        let after = pasteboard.changeCount
        XCTAssertEqual(pasteboard.string(forType: .string), "a transcript")

        XCTAssertTrue(injector.restoreClipboard(borrowed, ifUnchangedFrom: after))
        XCTAssertEqual(pasteboard.string(forType: .string), "something the user copied")
    }

    /// A dictation must not turn a copied image into nothing, which is what
    /// capturing only the string representation would do.
    func testNonTextContentComesBackToo() {
        // Arbitrary bytes under a non-string type: the property under test is
        // that a representation which is not a string survives, and an image
        // would only add a dependency on image encoding.
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x10])
        pasteboard.clearContents()
        pasteboard.setData(bytes, forType: .png)

        let borrowed = injector.captureClipboard()
        injector.copyToClipboard("a transcript")
        let after = pasteboard.changeCount

        XCTAssertTrue(injector.restoreClipboard(borrowed, ifUnchangedFrom: after))
        XCTAssertEqual(pasteboard.data(forType: .png), bytes)
        XCTAssertNil(pasteboard.string(forType: .string), "The transcript must not survive alongside it")
    }

    /// Somebody copying during the dictation now owns the clipboard. Putting
    /// our snapshot back would take away the thing they just chose.
    func testAClipboardWrittenSinceIsLeftAlone() {
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let borrowed = injector.captureClipboard()
        injector.copyToClipboard("a transcript")
        let after = pasteboard.changeCount

        injector.copyToClipboard("something the user copied mid-dictation")
        XCTAssertFalse(injector.restoreClipboard(borrowed, ifUnchangedFrom: after))
        XCTAssertEqual(pasteboard.string(forType: .string), "something the user copied mid-dictation")
    }

    /// An empty clipboard is a state worth restoring to. Leaving the transcript
    /// behind would be giving the user something they never had.
    func testAnEmptyClipboardIsRestoredAsEmpty() {
        pasteboard.clearContents()
        let borrowed = injector.captureClipboard()
        XCTAssertTrue(borrowed.isEmpty)

        injector.copyToClipboard("a transcript")
        let after = pasteboard.changeCount
        XCTAssertTrue(injector.restoreClipboard(borrowed, ifUnchangedFrom: after))
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testMultipleItemsAllComeBack() {
        pasteboard.clearContents()
        let first = NSPasteboardItem()
        first.setString("one", forType: .string)
        let second = NSPasteboardItem()
        second.setString("two", forType: .string)
        pasteboard.writeObjects([first, second])

        let borrowed = injector.captureClipboard()
        injector.copyToClipboard("a transcript")
        let after = pasteboard.changeCount

        XCTAssertTrue(injector.restoreClipboard(borrowed, ifUnchangedFrom: after))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2)
    }

    // MARK: - Ownership by identity rather than by counting

    /// The check that decides whether the clipboard is still ours to put back.
    /// A change count answers "has anything happened since", which is a
    /// different question: an app that writes and restores the pasteboard bumps
    /// it twice without changing what is on it.
    func testOurOwnPasteIsRecognised() {
        let text = "a transcript"
        let session = UUID().uuidString
        XCTAssertTrue(injector.writeForPasteForTesting(text, sessionID: session))
        XCTAssertTrue(injector.clipboardStillHoldsOurPasteForTesting(text, sessionID: session))
    }

    func testAnotherWriteIsNotMistakenForOurs() {
        let session = UUID().uuidString
        XCTAssertTrue(injector.writeForPasteForTesting("a transcript", sessionID: session))
        injector.copyToClipboard("something the user copied")
        XCTAssertFalse(injector.clipboardStillHoldsOurPasteForTesting("a transcript", sessionID: session))
    }

    /// The same text from a different dictation is not this dictation's paste.
    /// Text alone would say it was.
    func testTheSameTextFromAnotherSessionIsNotOurs() {
        XCTAssertTrue(injector.writeForPasteForTesting("a transcript", sessionID: "first"))
        XCTAssertFalse(injector.clipboardStillHoldsOurPasteForTesting("a transcript", sessionID: "second"))
    }

    /// Clipboard-history tools honour these, so a transcript is not recorded
    /// into a history that made no promises about it.
    func testAPasteIsMarkedSoHistoryToolsSkipIt() {
        XCTAssertTrue(injector.writeForPasteForTesting("a transcript", sessionID: UUID().uuidString))
        let types = pasteboard.types ?? []
        XCTAssertTrue(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
        XCTAssertTrue(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")))
        XCTAssertEqual(
            pasteboard.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source")),
            Bundle.main.bundleIdentifier
        )
    }

    /// An ordinary copy, which the user is meant to keep, carries none of it.
    func testAnOrdinaryCopyIsNotMarkedTransient() {
        injector.copyToClipboard("the user asked for this")
        let types = pasteboard.types ?? []
        XCTAssertFalse(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
    }
}
