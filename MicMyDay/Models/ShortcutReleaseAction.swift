import Foundation

/// What releasing the dictation shortcut should do, given the activation mode
/// and how long the key was held. Pure, so the timing rules are testable.
enum ShortcutReleaseAction: Equatable {
    case none
    case stop
    case discard

    /// In tap-and-hold mode, presses shorter than this are toggles; holding
    /// past it turns the press into push-to-talk that stops on release.
    /// A deliberate two-key chord press easily lasts half a second, which
    /// used to silently end the recording on release — so the threshold sits
    /// well above any plausible tap.
    static let pushToTalkThreshold: TimeInterval = 1.0
    /// In hold-to-record mode, releases quicker than this are treated as
    /// accidental taps and the recording is discarded.
    static let accidentalTapThreshold: TimeInterval = 0.25

    static func forRelease(
        mode: ShortcutActivationMode,
        heldDuration: TimeInterval
    ) -> ShortcutReleaseAction {
        switch mode {
        case .tapToggle:
            return .none
        case .tapAndHold:
            return heldDuration >= pushToTalkThreshold ? .stop : .none
        case .holdToRecord:
            return heldDuration < accidentalTapThreshold ? .discard : .stop
        }
    }
}
