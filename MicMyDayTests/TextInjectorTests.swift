import AppKit
import XCTest
@testable import MicMyDay

final class TextInjectorTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        // A private named pasteboard keeps these tests off the user's real
        // clipboard and away from Universal Clipboard interference.
        pasteboard = NSPasteboard(name: NSPasteboard.Name("TextInjectorTests.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    private func makeInjector(trusted: Bool = false) -> TextInjector {
        TextInjector(accessibilityTrusted: { trusted }, pasteboard: pasteboard)
    }

    func testEmptyTranscriptThrowsInsteadOfPastingNothing() async {
        let injector = makeInjector()
        do {
            _ = try await injector.insert("   \n  ", targetPID: nil, appendTrailingSpace: true)
            XCTFail("Whitespace-only text must throw, not deliver")
        } catch {
            guard case TranscriptionError.emptyResponse = error else {
                return XCTFail("Expected emptyResponse, got \(error)")
            }
        }
    }

    func testWithoutAccessibilityTheTranscriptStillReachesTheClipboard() async throws {
        let injector = makeInjector()
        let result = try await injector.insert("hello world", targetPID: 12345, appendTrailingSpace: false)
        XCTAssertEqual(result, .copiedOnly)
        XCTAssertEqual(pasteboard.string(forType: .string), "hello world")
    }

    func testTrailingSpaceIsAppendedExactlyOnce() async throws {
        let injector = makeInjector()
        _ = try await injector.insert("hello", targetPID: nil, appendTrailingSpace: true)
        XCTAssertEqual(pasteboard.string(forType: .string), "hello ")

        // Already-trimmed input never gains a second space, and the trim
        // runs before the append, so "hello \n" also ends as "hello ".
        _ = try await injector.insert("hello \n", targetPID: nil, appendTrailingSpace: true)
        XCTAssertEqual(pasteboard.string(forType: .string), "hello ")
    }

    func testMissingTargetFallsBackToClipboardEvenWhenTrusted() async throws {
        let injector = makeInjector(trusted: true)
        let result = try await injector.insert("no target", targetPID: nil, appendTrailingSpace: false)
        XCTAssertEqual(result, .copiedOnly)
    }
}
