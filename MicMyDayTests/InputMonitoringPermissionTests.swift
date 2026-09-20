import XCTest
@testable import MicMyDay

final class InputMonitoringPermissionTests: XCTestCase {
    func testRequestsAccessWhenNotYetGranted() {
        var granted = false
        var requests = 0
        let permission = InputMonitoringPermission(preflight: { granted }, requestAccess: {
            requests += 1
            granted = true
            return true
        })
        XCTAssertTrue(permission.request())
        XCTAssertEqual(requests, 1)
    }

    func testDoesNotRequestRedundantPermissionWhenListeningAlreadyWorks() {
        let permission = InputMonitoringPermission(preflight: { true }, requestAccess: {
            XCTFail("Already allowed; do not ask for an additional permission")
            return false
        })
        XCTAssertTrue(permission.request())
    }

    func testRequestResultDoesNotReplaceActualPermissionCheck() {
        let permission = InputMonitoringPermission(preflight: { false }, requestAccess: { true })
        XCTAssertFalse(permission.request())
        XCTAssertFalse(permission.isGranted)
    }

    func testDetectsSubsequentGrantAndRevocation() {
        var granted = false
        let permission = InputMonitoringPermission(preflight: { granted }, requestAccess: { false })
        XCTAssertFalse(permission.request())
        granted = true
        XCTAssertTrue(permission.isGranted)
        granted = false
        XCTAssertFalse(permission.isGranted)
    }
}
