import Foundation
import Security
import XCTest
@testable import MicMyDay

final class PermissionConfigurationTests: XCTestCase {
    func testPrivacyAndLicenseResourcesAreBundled() throws {
        XCTAssertNotNil(Bundle.main.url(forResource: "LICENSE", withExtension: "txt"))
        for name in ["Privacy", "ThirdPartyNotices"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "txt"))
            XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).isEmpty)
        }
    }

    func testPrivacyManifestIsBundledAndDeclaresRequiredReasons() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        let types = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let reasons = types.flatMap { $0["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [] }
        XCTAssertTrue(reasons.contains("CA92.1"))
        XCTAssertTrue(reasons.contains("35F9.1"))
    }

    func testTransportSecurityAllowsLocalServersWithoutBroadHTTPException() throws {
        let ats = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
        XCTAssertNotEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
    }

    func testHostAppContainsRequiredPrivacyUsageDescriptions() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)

        let microphoneDescription = try XCTUnwrap(info["NSMicrophoneUsageDescription"] as? String)
        XCTAssertFalse(microphoneDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let localNetworkDescription = try XCTUnwrap(info["NSLocalNetworkUsageDescription"] as? String)
        XCTAssertFalse(localNetworkDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let speechDescription = try XCTUnwrap(info["NSSpeechRecognitionUsageDescription"] as? String)
        XCTAssertFalse(speechDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testHostAppAllowsAudioInputUnderHardenedRuntime() throws {
        let task = try XCTUnwrap(SecTaskCreateFromSelf(nil))
        let entitlement = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.device.audio-input" as CFString,
            nil
        ) as? Bool

        XCTAssertEqual(entitlement, true)
    }

    func testHostAppHasRequiredSandboxEntitlements() throws {
        let task = try XCTUnwrap(SecTaskCreateFromSelf(nil))
        for key in [
            "com.apple.security.app-sandbox",
            "com.apple.security.device.microphone",
            "com.apple.security.network.client"
        ] {
            let entitlement = SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? Bool
            XCTAssertEqual(entitlement, true, "Missing required entitlement: \(key)")
        }
    }
}
