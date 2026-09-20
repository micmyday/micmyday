import AppKit
import XCTest
@testable import MicMyDay

/// The overlay's window is built before the first dictation needs it. Creating
/// the panel and laying its hosting view out for the first time costs two
/// orders of magnitude more than every later show, and that bill used to land
/// on the first take of the session, after the shortcut was pressed and the
/// user had started talking.
@MainActor
final class OverlayPreparationTests: XCTestCase {
    func testPreparingBuildsTheWindowBeforeAnythingIsShown() {
        let controller = OverlayController()
        XCTAssertNil(controller.window, "nothing should exist before preparing")

        controller.prepare()

        XCTAssertNotNil(controller.window, "the panel should exist after preparing")
        XCTAssertFalse(controller.isVisible, "preparing must not put anything on screen")
    }

    /// Called on every launch and every time the menu-bar panel opens, so it
    /// has to be free after the first time.
    func testPreparingTwiceKeepsTheSameWindow() {
        let controller = OverlayController()
        controller.prepare()
        let first = controller.window
        controller.prepare()

        XCTAssertTrue(first === controller.window)
        XCTAssertFalse(controller.isVisible)
    }
}
