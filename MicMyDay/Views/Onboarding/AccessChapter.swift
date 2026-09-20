import AppKit
import SwiftUI

/// 02 Access — the three macOS permissions.
///
/// All three are required before setup can go on. A half-granted install
/// fails much later and far from its cause: a dictation that lands on the
/// clipboard instead of in the document, or an engine that will not start.
///
/// Microphone and Speech Recognition are noticed the moment macOS grants them,
/// by the poll that runs while this window is open. Accessibility is not:
/// post-event access is resolved once per process, so a grant made while
/// MicMyDay is running stays invisible to the thing that needs it however
/// often it is checked. The trust database does change though, so the row can
/// still tell that the user has done their part and say that only a restart
/// is left, rather than claiming the permission is missing.
struct AccessChapter: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ChapterHeading(
                title: "Set up permissions",
                lede: "Allow microphone, Speech Recognition and Accessibility access to continue."
            )

            VStack(spacing: 10) {
                PermissionRow(
                    title: "Microphone",
                    explanation: "Required to record your voice.",
                    doneText: "Microphone access is enabled.",
                    grantedLabel: "Allowed",
                    actionTitle: appState.microphoneDenied ? "Try again" : "Allow",
                    prominent: true,
                    optional: false,
                    isGranted: appState.microphoneGranted,
                    warning: appState.microphoneDenied
                        ? "MicMyDay can't hear you without the microphone. Allow it here, or later in System Settings \u{2192} Privacy & Security \u{2192} Microphone."
                        : nil,
                    action: { appState.requestMicrophonePermission() }
                )

                PermissionRow(
                    title: "Speech Recognition",
                    explanation: "Required for Apple Speech. Audio may be sent to Apple’s cloud unless “Transcribe on this Mac only” is enabled.",
                    doneText: "Speech recognition is available.",
                    grantedLabel: "Allowed",
                    actionTitle: "Allow",
                    prominent: false,
                    optional: false,
                    isGranted: appState.speechGranted,
                    warning: nil,
                    action: { appState.requestSpeechPermission() }
                )

                PermissionRow(
                    title: "Accessibility",
                    explanation: "Allow automatic pasting into other apps. Without this permission, paste with ⌘V.",
                    doneText: "MicMyDay can paste where your cursor is.",
                    grantedLabel: "Allowed",
                    actionTitle: "Open System Settings",
                    prominent: false,
                    optional: false,
                    isGranted: appState.accessibilityGranted,
                    warning: nil,
                    action: { appState.requestAccessibilityPermission() },
                    allowedButUnusable: appState.accessibilityAllowedPendingRestart,
                    restart: { appState.relaunch() },
                    relaunchFailed: appState.relaunchFailed
                )
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let explanation: String
    let doneText: String
    let grantedLabel: String
    let actionTitle: String
    let prominent: Bool
    let optional: Bool
    let isGranted: Bool
    let warning: String?
    let action: () -> Void
    /// True when the user has allowed it but this process cannot act on it
    /// yet. Only the Accessibility row can be in that state, and saying so is
    /// the difference between "do it again" and "you are done, one restart to
    /// go".
    var allowedButUnusable = false
    /// Supplied only by the Accessibility row, where a grant cannot be seen
    /// until the app restarts.
    var restart: (() -> Void)?
    /// True once a restart attempt failed, so the row can say what to do
    /// instead of leaving a button that appears to do nothing.
    var relaunchFailed = false

    @State private var waiting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                statusCircle

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.mfTextPrimary)
                        if optional {
                            Text("OPTIONAL")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .tracking(1.4)
                                .foregroundStyle(Color.mfTextPrimary.opacity(0.35))
                        }
                    }
                    Text(isGranted ? doneText : explanation)
                        .font(.system(size: 12))
                        .lineSpacing(3)
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.52))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                control
            }

            // Offered once the user has been sent to System Settings: from
            // here the app cannot tell "not granted yet" from "granted, but
            // this process cannot see it", so it says so plainly instead of
            // leaving them staring at an empty circle.
            if let restart, !isGranted, waiting || allowedButUnusable {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(allowedButUnusable
                             ? "Permission granted. Restart MicMyDay to apply it."
                             : "After allowing access in System Settings, restart MicMyDay.")
                            .font(.system(size: 11))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Restart MicMyDay", action: restart)
                            .buttonStyle(.beaconQuiet)
                        if relaunchFailed {
                            Text("Couldn’t restart MicMyDay. Quit it from the menu bar, then open it again.")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.mfWarn)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .foregroundStyle(Color.mfTextPrimary.opacity(0.55))
                .padding(.leading, 38)
            }

            if let warning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                    Text(warning)
                        .font(.system(size: 11))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color.mfWarn)
                .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mfFill(0.04), in: RoundedRectangle(cornerRadius: MFMetric.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MFMetric.radiusCard, style: .continuous)
                .strokeBorder(isGranted ? Color.mfReady : Color.mfFill(0.06), lineWidth: 1)
        }
        .onChange(of: isGranted) { _, granted in
            if granted { waiting = false }
        }
        // A denied prompt never flips isGranted, which left the spinner
        // spinning forever with "Try again" unreachable. Coming back from
        // the prompt or System Settings reactivates the app; if the
        // permission still isn't granted by then, offer the button again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The Accessibility row keeps its waiting state: coming back from
            // System Settings is exactly when the restart offer is needed, and
            // clearing it here would hide the only way forward.
            if !isGranted, restart == nil { waiting = false }
        }
    }

    private var statusCircle: some View {
        ZStack {
            if isGranted {
                Circle().fill(Color.mfReady).frame(width: 24, height: 24)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.mfCanvasDeep)
            } else {
                Circle()
                    .strokeBorder(Color.mfFill(0.18), lineWidth: 1.5)
                    .frame(width: 24, height: 24)
            }
        }
        .frame(width: 24, height: 24)
    }

    @ViewBuilder
    private var control: some View {
        if isGranted {
            BeaconChip(text: grantedLabel, symbol: "checkmark", tone: .ready)
        } else if waiting {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for macOS\u{2026}")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.5))
            }
        } else {
            Button(actionTitle) {
                waiting = true
                action()
            }
            .buttonStyle(prominent ? .beacon : .beaconQuiet)
        }
    }
}

/// The h1 + lede pair that opens every chapter after the first.
struct ChapterHeading: View {
    let title: String
    let lede: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 32, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(Color.mfTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(lede)
                .font(.system(size: 14))
                .lineSpacing(5)
                .foregroundStyle(Color.mfTextPrimary.opacity(0.62))
                .frame(maxWidth: 620, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
