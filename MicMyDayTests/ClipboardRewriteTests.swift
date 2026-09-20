import XCTest
@testable import MicMyDay

/// The clipboard rewrite is the one tool that both reads and writes the
/// user's clipboard, so every test here runs against a private pasteboard:
/// a test that reached the real one would rewrite whatever the developer had
/// copied while it ran.
@MainActor
final class ClipboardRewriteTests: XCTestCase {
    /// Stands in for the rewrite model. Hangs until released, so a test can
    /// act while a rewrite is still in flight.
    private final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        func wait() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    self.semaphore.wait()
                    continuation.resume()
                }
            }
        }
        func release() { semaphore.signal() }
    }

    private var suiteName = ""
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: .init("ClipboardRewriteTests.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        if !suiteName.isEmpty {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    private func makeState(gate: Gate? = nil) -> AppState {
        suiteName = "ClipboardRewriteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(
            defaults: defaults,
            keychain: KeychainStore(service: "ClipboardRewriteTests.\(UUID().uuidString)")
        )
        // A self-hosted endpoint needs only a URL and a model, so the rewrite
        // counts as configured without a key going anywhere near a keychain.
        settings.rewriteProvider = .custom
        settings.enhancementBaseURL = "http://127.0.0.1:1/v1"
        settings.enhancementModel = "test-model"

        var work = AppState.Work()
        work.enhance = { text, configuration, _ in
            if let gate { await gate.wait() }
            return "[\(configuration.profileID)] \(text.uppercased())"
        }
        return AppState(
            settings: settings,
            work: work,
            textInjector: TextInjector(accessibilityTrusted: { false }, pasteboard: pasteboard)
        )
    }

    private func settle(_ turns: Int = 8) async {
        for _ in 0 ..< turns {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(12))
        }
    }

    func testRewrittenTextReplacesTheClipboard() async {
        let state = makeState()
        pasteboard.clearContents()
        pasteboard.setString("some copied text", forType: .string)

        state.rewriteClipboardText(profileID: "cleanup")
        await settle()

        XCTAssertEqual(pasteboard.string(forType: .string), "[cleanup] SOME COPIED TEXT")
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.lastTranscript, "[cleanup] SOME COPIED TEXT")
    }

    /// The profile named in the menu is the one that runs, whatever dictation
    /// happens to be set to.
    func testTheNamedProfileRunsRatherThanTheDictationProfile() async {
        let state = makeState()
        pasteboard.clearContents()
        pasteboard.setString("text", forType: .string)

        state.rewriteClipboardText(profileID: "email")
        await settle()

        XCTAssertEqual(pasteboard.string(forType: .string), "[email] TEXT")
    }

    /// Choosing a profile for one passage must not change what the next
    /// dictation will do.
    func testRewritingDoesNotChangeTheDictationProfile() async {
        let state = makeState()
        let before = state.settings.rewriteProfileID
        pasteboard.clearContents()
        pasteboard.setString("text", forType: .string)

        state.rewriteClipboardText(profileID: "agentPrompt")
        await settle()

        XCTAssertEqual(state.settings.rewriteProfileID, before)
    }

    func testAnEmptyClipboardIsRefusedAndLeftAlone() async {
        let state = makeState()
        pasteboard.clearContents()
        pasteboard.setString("   \n  ", forType: .string)

        state.rewriteClipboardText(profileID: "cleanup")
        await settle()

        XCTAssertEqual(pasteboard.string(forType: .string), "   \n  ")
        guard case .failed = state.phase else {
            return XCTFail("expected a failure, got \(state.phase)")
        }
    }

    /// Somebody copying while the rewrite runs is waiting to paste that, not
    /// this, so the result is discarded rather than written over it.
    func testACopyDuringTheRewriteKeepsTheNewClipboard() async {
        let gate = Gate()
        let state = makeState(gate: gate)
        pasteboard.clearContents()
        pasteboard.setString("the original", forType: .string)

        state.rewriteClipboardText(profileID: "cleanup")
        await settle(2)
        pasteboard.clearContents()
        pasteboard.setString("something else entirely", forType: .string)
        gate.release()
        await settle()

        XCTAssertEqual(pasteboard.string(forType: .string), "something else entirely")
    }

    func testCancellingDuringTheRewriteWritesNothing() async {
        let gate = Gate()
        let state = makeState(gate: gate)
        pasteboard.clearContents()
        pasteboard.setString("the original", forType: .string)

        state.rewriteClipboardText(profileID: "cleanup")
        await settle(2)
        state.cancelRecording()
        gate.release()
        await settle()

        XCTAssertEqual(pasteboard.string(forType: .string), "the original")
    }

    /// The rewrite is paid for either way, so a clipboard the user changed
    /// under it must not also cost them the text: it stays in the panel.
    func testAStolenClipboardStillLeavesTheRewriteInThePanel() async {
        let gate = Gate()
        let state = makeState(gate: gate)
        pasteboard.clearContents()
        pasteboard.setString("the original", forType: .string)

        state.rewriteClipboardText(profileID: "cleanup")
        await settle(2)
        pasteboard.clearContents()
        pasteboard.setString("something else entirely", forType: .string)
        gate.release()
        await settle()

        XCTAssertEqual(pasteboard.string(forType: .string), "something else entirely")
        XCTAssertEqual(state.lastTranscript, "[cleanup] THE ORIGINAL")
        XCTAssertNil(state.lastDelivery, "nothing was delivered, so nothing may claim it was")
    }

    /// A provider that raises a cancellation of its own, rather than one the
    /// user asked for, must still end the step: the app sat in .enhancing
    /// until a watchdog noticed, with every tool and dictation blocked.
    func testAProviderCancellationDoesNotStrandTheApp() async {
        suiteName = "ClipboardRewriteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(
            defaults: defaults,
            keychain: KeychainStore(service: "ClipboardRewriteTests.\(UUID().uuidString)")
        )
        settings.rewriteProvider = .custom
        settings.enhancementBaseURL = "http://127.0.0.1:1/v1"
        settings.enhancementModel = "test-model"
        var work = AppState.Work()
        work.enhance = { _, _, _ in throw CancellationError() }
        let state = AppState(
            settings: settings,
            work: work,
            textInjector: TextInjector(accessibilityTrusted: { false }, pasteboard: pasteboard)
        )
        pasteboard.clearContents()
        pasteboard.setString("the original", forType: .string)

        state.rewriteClipboardText(profileID: "cleanup")
        await settle()

        XCTAssertEqual(pasteboard.string(forType: .string), "the original")
        guard case .failed = state.phase else {
            return XCTFail("the app stayed busy after a provider cancellation: \(state.phase)")
        }
        XCTAssertTrue(state.canRunTool, "another tool must be startable afterwards")
    }

    /// A second tool started while one is running would claim the session out
    /// from under it.
    func testASecondRewriteIsRefusedWhileOneIsRunning() async {
        let gate = Gate()
        let state = makeState(gate: gate)
        pasteboard.clearContents()
        pasteboard.setString("the original", forType: .string)

        state.rewriteClipboardText(profileID: "cleanup")
        await settle(2)
        XCTAssertFalse(state.canRunTool)
        state.rewriteClipboardText(profileID: "email")
        gate.release()
        await settle()

        XCTAssertEqual(pasteboard.string(forType: .string), "[cleanup] THE ORIGINAL")
    }
}
