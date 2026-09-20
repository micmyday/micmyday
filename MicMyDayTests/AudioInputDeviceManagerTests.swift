import XCTest
@testable import MicMyDay

final class AudioInputDeviceManagerTests: XCTestCase {
    func testEnumeratesUsableInputDevicesWithUniqueUIDs() throws {
        let devices = try AudioInputDeviceManager.inputDevices()
        guard !devices.isEmpty else {
            throw XCTSkip("This Mac has no Core Audio input devices.")
        }

        XCTAssertTrue(devices.allSatisfy { !$0.uid.isEmpty && !$0.name.isEmpty })
        XCTAssertEqual(Set(devices.map(\.uid)).count, devices.count)
    }

    func testSystemDefaultResolvesToEnumeratedDefaultInput() throws {
        let devices = try AudioInputDeviceManager.inputDevices()
        guard let expected = devices.first(where: { $0.isDefault }) else {
            throw XCTSkip("This Mac has no default Core Audio input device.")
        }

        XCTAssertEqual(try AudioInputDeviceManager.resolveInputDevice(uid: nil), expected)
        XCTAssertEqual(try AudioInputDeviceManager.resolveInputDevice(uid: ""), expected)
    }

    func testUnavailableSelectionProducesSpecificError() throws {
        XCTAssertThrowsError(
            try AudioInputDeviceManager.resolveInputDevice(uid: "com.micmyday.app.missing-input")
        ) { error in
            guard case AudioInputDeviceError.selectedDeviceUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
