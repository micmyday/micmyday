import XCTest
@testable import MicMyDay

final class PermissionReturnFlowTests: XCTestCase {
    func testNativePromptRestoresSamePageOnceForEitherPermissionResult() {
        // The permission decision is deliberately not an input: both Allow
        // and Don't Allow must return the person to their original page.
        for page in ["settings.permissions", "settings.voice", "onboarding.access"] {
            var flow = PermissionReturnFlow<String>()
            let id = flow.begin(page)
            XCTAssertNil(flow.appBecameActive(), "Activation while the prompt is open must not restore early")
            XCTAssertEqual(flow.promptFinished(id), page)
            XCTAssertNil(flow.promptFinished(id))
            XCTAssertNil(flow.destination)
        }
    }

    func testSystemSettingsKeepsFocusUntilUserReturns() {
        var flow = PermissionReturnFlow<String>()
        let id = flow.begin("settings.voice")
        flow.openedSystemSettings()
        XCTAssertNil(flow.promptFinished(id))
        XCTAssertNil(flow.appBecameActive(), "Don't restore before System Settings actually opens")
        flow.externalAppActivated(bundleID: "com.apple.finder")
        XCTAssertNil(flow.appBecameActive())
        flow.externalAppActivated(bundleID: "com.apple.systempreferences")
        XCTAssertNil(flow.promptFinished(id), "Finishing the native request must not steal focus")
        XCTAssertEqual(flow.appBecameActive(), "settings.voice")
        XCTAssertNil(flow.appBecameActive())
    }

    func testExplicitClosePreventsWindowFromReopening() {
        var flow = PermissionReturnFlow<String>()
        let id = flow.begin("settings.permissions")
        flow.openedSystemSettings()
        flow.externalAppActivated(bundleID: "com.apple.systempreferences")
        flow.cancel()
        XCTAssertNil(flow.promptFinished(id))
        XCTAssertNil(flow.appBecameActive())
        XCTAssertNil(flow.destination)
    }

    func testOlderCallbackCannotRestoreANewerPermissionRequest() {
        var flow = PermissionReturnFlow<String>()
        let old = flow.begin("settings.permissions")
        let current = flow.begin("settings.voice")
        XCTAssertNil(flow.promptFinished(old))
        XCTAssertEqual(flow.promptFinished(current), "settings.voice")
    }

    func testPermissionRequestWithoutOriginDoesNotCreateWindow() {
        var flow = PermissionReturnFlow<String>()
        flow.openedSystemSettings()
        flow.externalAppActivated(bundleID: "com.apple.systempreferences")
        XCTAssertNil(flow.promptFinished(nil))
        XCTAssertNil(flow.appBecameActive())
    }
}
