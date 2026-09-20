import XCTest
@testable import MicMyDay

final class ShortcutReleaseActionTests: XCTestCase {
    func testTapToggleIgnoresReleaseRegardlessOfHoldTime() {
        XCTAssertEqual(ShortcutReleaseAction.forRelease(mode: .tapToggle, heldDuration: 0.05), .none)
        XCTAssertEqual(ShortcutReleaseAction.forRelease(mode: .tapToggle, heldDuration: 10), .none)
    }

    func testTapAndHoldTreatsShortPressAsToggleAndLongPressAsPushToTalk() {
        XCTAssertEqual(ShortcutReleaseAction.forRelease(mode: .tapAndHold, heldDuration: 0.1), .none)
        // A deliberate chord press of half a second must stay a toggle.
        XCTAssertEqual(ShortcutReleaseAction.forRelease(mode: .tapAndHold, heldDuration: 0.5), .none)
        XCTAssertEqual(
            ShortcutReleaseAction.forRelease(mode: .tapAndHold, heldDuration: ShortcutReleaseAction.pushToTalkThreshold),
            .stop
        )
        XCTAssertEqual(ShortcutReleaseAction.forRelease(mode: .tapAndHold, heldDuration: 3), .stop)
    }

    func testHoldToRecordDiscardsAccidentalTapsAndStopsRealHolds() {
        XCTAssertEqual(ShortcutReleaseAction.forRelease(mode: .holdToRecord, heldDuration: 0.1), .discard)
        XCTAssertEqual(
            ShortcutReleaseAction.forRelease(mode: .holdToRecord, heldDuration: ShortcutReleaseAction.accidentalTapThreshold),
            .stop
        )
        XCTAssertEqual(ShortcutReleaseAction.forRelease(mode: .holdToRecord, heldDuration: 2), .stop)
    }
}
