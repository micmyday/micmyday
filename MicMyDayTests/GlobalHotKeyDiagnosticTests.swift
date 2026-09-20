import AppKit
import Carbon
import XCTest
@testable import MicMyDay

final class GlobalHotKeyDiagnosticTests: XCTestCase {
    func testReceivesShortcutWhileAnotherApplicationIsActive() throws {
        guard ProcessInfo.processInfo.environment["MICMYDAY_RUN_GLOBAL_HOTKEY_TEST"] == "1" else {
            throw XCTSkip("Set MICMYDAY_RUN_GLOBAL_HOTKEY_TEST=1 to run the focus-changing integration test.")
        }

        let originalApplication = NSWorkspace.shared.frontmostApplication
        defer { originalApplication?.activate() }

        let manager = HotKeyManager()
        let received = expectation(description: "Global hotkey received while MicMyDay is inactive")
        manager.onPressed = { received.fulfill() }
        try manager.register(
            KeyboardShortcut(
                keyCode: 6,
                modifiers: UInt32(cmdKey | optionKey | shiftKey),
                keyLabel: "Z"
            )
        )

        guard let finder = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder"
        ).first else {
            throw XCTSkip("Finder is not running.")
        }

        finder.activate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(NSApp.isActive, "The test host must be inactive for this diagnostic.")

        let flags: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift]
        let keyDown = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 6, keyDown: true))
        keyDown.flags = flags
        keyDown.post(tap: .cghidEventTap)
        let keyUp = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 6, keyDown: false))
        keyUp.flags = flags
        keyUp.post(tap: .cghidEventTap)

        wait(for: [received], timeout: 2)
        withExtendedLifetime(manager) {}
    }
}

final class HotKeyAutoRepeatTests: XCTestCase {
    /// Holding the shortcut makes macOS deliver repeated pressed events
    /// (keyboard auto-repeat). Only the first press and the matching release
    /// may reach the app, or hold-to-talk stops itself mid-hold.
    @MainActor
    func testAutoRepeatPressesAreSwallowed() {
        let manager = HotKeyManager()
        var presses = 0
        var releases = 0
        manager.onPressed = { presses += 1 }
        manager.onReleased = { releases += 1 }

        let id = EventHotKeyID(signature: 0x4D_49_43_54, id: 1)
        let pressed = UInt32(kEventHotKeyPressed)
        let released = UInt32(kEventHotKeyReleased)

        manager.receiveHotKey(id, kind: pressed)
        manager.receiveHotKey(id, kind: pressed) // auto-repeat
        manager.receiveHotKey(id, kind: pressed) // auto-repeat
        manager.receiveHotKey(id, kind: released)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(presses, 1)
        XCTAssertEqual(releases, 1)

        manager.receiveHotKey(id, kind: released) // stray release, no press
        manager.receiveHotKey(id, kind: pressed)  // next distinct press
        manager.receiveHotKey(id, kind: pressed)  // auto-repeat
        manager.receiveHotKey(id, kind: released)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(presses, 2)
        XCTAssertEqual(releases, 2)
    }
}
