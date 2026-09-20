import SwiftUI

/// Permissions — status only, and the fix when something is missing.
struct PermissionsPane: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore
    @State private var sharingReset = false
    @State private var localNetworkOpened = false

    /// Local Network only matters for a self-hosted provider on another
    /// machine; macOS prompts by itself on the first connection. For every
    /// other configuration the card would be noise about a permission the
    /// user will never encounter.
    private var showsLocalNetworkCard: Bool {
        settings.provider == .custom
            || (settings.enhancementEnabled && settings.rewriteProvider == .custom)
    }

    var body: some View {
        SettingsCard(eyebrow: "macOS permissions") {
            row(
                title: "Microphone",
                detail: "Required to record your voice.",
                granted: appState.microphoneGranted,
                action: { appState.requestMicrophonePermission() }
            )
            row(
                title: "Accessibility",
                detail: "Allow automatic pasting into other apps. Without this permission, paste with ⌘V.",
                granted: appState.accessibilityGranted,
                action: { appState.requestAccessibilityPermission() }
            )
            row(
                title: "Input Monitoring",
                detail: "Required for single-modifier shortcuts such as right Shift or Fn.",
                granted: appState.inputMonitoringGranted,
                action: { appState.requestInputMonitoringPermission() }
            )
            row(
                title: "Speech Recognition",
                detail: "Required for Apple Speech. Audio may be sent to Apple’s cloud unless “Transcribe on this Mac only” is enabled.",
                granted: appState.speechGranted,
                action: { appState.requestSpeechPermission() }
            )
        }

        if showsLocalNetworkCard {
        SettingsCard(
            eyebrow: "Local servers",
            caption: "Allow Local Network access to use a server on your network. macOS asks on the first connection; access can also be enabled in System Settings."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Button("Open Privacy & Security Settings") {
                    appState.openPrivacySettings(.localNetwork)
                    localNetworkOpened = true
                }
                .buttonStyle(.beaconQuiet)
                // macOS has no deep link to the Local Network list, so the
                // click lands on Privacy & Security; spell out the rest.
                if localNetworkOpened {
                    Text("Open Local Network and enable MicMyDay. It appears after the first connection attempt to a server on your network.")
                        .font(.system(size: 11))
                        .lineSpacing(2)
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        }

        SettingsCard(
            eyebrow: "Provider privacy",
            caption: "MicMyDay asks before sharing audio or text with a provider. Reset these choices to be asked again. Data already shared is not deleted."
        ) {
            Button(sharingReset ? "Sharing choices reset" : "Reset sharing choices") {
                DataSharingConsent.shared.reset()
                sharingReset = true
            }
            .buttonStyle(.beaconQuiet)
        }

        SettingsCard(
            eyebrow: "Refresh permissions",
            caption: "Refresh after changing permissions in System Settings. Restart MicMyDay if Accessibility still appears disabled."
        ) {
            HStack(spacing: 8) {
                Button("Refresh status") { appState.refreshPermissionStatuses() }
                    .buttonStyle(.beaconQuiet)
                if !appState.accessibilityGranted {
                    Button("Restart MicMyDay") { appState.relaunch() }
                        .buttonStyle(.beaconQuiet)
                }
            }
        }
    }

    private func row(title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        SettingsRow(title: title, detail: detail) {
            if granted {
                BeaconChip(text: "Allowed", symbol: "checkmark", tone: .ready)
            } else {
                Button("Open Privacy Settings", action: action)
                    .buttonStyle(.beaconQuiet)
            }
        }
    }
}
