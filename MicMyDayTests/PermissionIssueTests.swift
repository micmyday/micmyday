import XCTest
@testable import MicMyDay

final class PermissionIssueTests: XCTestCase {
    func testMicrophoneIsRequiredForEveryEngine() {
        for provider in TranscriptionProviderKind.allCases {
            let issues = PermissionIssue.missing(microphone: false, speech: true, accessibility: true, inputMonitoring: true, provider: provider, modifierOnlyShortcut: false, automaticPaste: true)
            XCTAssertEqual(issues, [.microphone])
            XCTAssertTrue(issues[0].blocksRecording)
        }
    }

    func testSpeechRecognitionWarningOnlyAppliesToAppleSpeech() {
        for provider in TranscriptionProviderKind.allCases {
            let issues = PermissionIssue.missing(microphone: true, speech: false, accessibility: true, inputMonitoring: true, provider: provider, modifierOnlyShortcut: false, automaticPaste: true)
            XCTAssertEqual(issues, provider == .appleSpeech ? [.speechRecognition] : [])
        }
    }

    func testInputMonitoringWarningOnlyAppliesToModifierOnlyShortcuts() {
        for modifierOnly in [false, true] {
            let issues = PermissionIssue.missing(microphone: true, speech: true, accessibility: true, inputMonitoring: false, provider: .whisper, modifierOnlyShortcut: modifierOnly, automaticPaste: true)
            XCTAssertEqual(issues, modifierOnly ? [.inputMonitoring] : [])
            XCTAssertFalse(issues.contains { $0.blocksRecording }, "The panel's recording button remains usable")
        }
    }

    func testAccessibilityIsOnlyAskedForWhenAutomaticPastingIsOn() {
        // Off by default, and the permission exists solely to paste: asking for
        // it then would be nagging about a feature the user declined.
        let declined = PermissionIssue.missing(
            microphone: true, speech: true, accessibility: false, inputMonitoring: true,
            provider: .whisper, modifierOnlyShortcut: false, automaticPaste: false
        )
        XCTAssertEqual(declined, [])
    }

    func testMissingAccessibilityAllowsClipboardDictation() {
        let issues = PermissionIssue.missing(microphone: true, speech: true, accessibility: false, inputMonitoring: true, provider: .whisper, modifierOnlyShortcut: false, automaticPaste: true)
        XCTAssertEqual(issues, [.accessibility])
        XCTAssertFalse(issues[0].blocksRecording)
        XCTAssertTrue(issues[0].detail.contains("⌘V"))
    }

    func testMultipleMissingPermissionsAreOrderedByImpact() {
        let issues = PermissionIssue.missing(microphone: false, speech: false, accessibility: false, inputMonitoring: false, provider: .appleSpeech, modifierOnlyShortcut: true, automaticPaste: true)
        XCTAssertEqual(issues, [.microphone, .speechRecognition, .inputMonitoring, .accessibility])
    }

    func testGrantingRequiredPermissionsClearsWarnings() {
        XCTAssertTrue(PermissionIssue.missing(microphone: true, speech: true, accessibility: true, inputMonitoring: true, provider: .appleSpeech, modifierOnlyShortcut: true, automaticPaste: true).isEmpty)
    }

    func testPermissionFailuresCarryResolvableIssue() {
        XCTAssertEqual(RecoveryAdvice.advice(for: AudioRecorderError.microphoneDenied).permissionIssue, .microphone)
        XCTAssertEqual(RecoveryAdvice.advice(for: TranscriptionError.speechPermissionDenied).permissionIssue, .speechRecognition)
        XCTAssertEqual(RecoveryAdvice.accessibility.permissionIssue, .accessibility)
        XCTAssertNil(RecoveryAdvice.advice(for: TranscriptionError.emptyResponse).permissionIssue)
    }
}
