import SwiftUI

/// 06 Profiles — what a profile changes, and how to reach a different one.
///
/// Split out of Rewrite, which was answering two questions at once: whether a
/// transcript should be rewritten at all, and which set of instructions should
/// do it. The second only matters once the first is settled, and it is the one
/// people actually use day to day, so it earns its own page.
struct ProfilesChapter: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ChapterHeading(
                title: "Profiles",
                lede: "Save rewrite instructions as profiles and switch between them for different tasks."
            )

            if settings.enhancementEnabled {
                RewriteProfilesSection()
            } else {
                StatusLabel(
                    text: "Turn on rewriting in the previous step or in Settings → Rewrite to use profiles.",
                    tone: .neutral,
                    symbol: "info.circle"
                )
            }

            switching
        }
    }

    /// Every way to change the armed profile, in the order somebody is likely
    /// to reach for them.
    private var switching: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SWITCH PROFILES")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Color.mfTextPrimary.opacity(0.35))

            VStack(alignment: .leading, spacing: 10) {
                row(
                    symbol: "arrow.left.arrow.right",
                    text: "Switch profiles without starting a recording. Change these shortcuts in Settings → Rewrite.",
                    keys: [
                        (label: "Next profile", shortcut: settings.cycleProfilesShortcut),
                        (label: "Previous profile", shortcut: settings.previousProfileShortcut),
                    ]
                )
                row(
                    symbol: "command",
                    text: "Start recording with a specific profile using its own shortcut. Assign shortcuts in Settings → Rewrite.",
                    keys: settings.rewriteProfiles.compactMap { profile in
                        guard let shortcut = settings.profileShortcuts[profile.id] else { return nil }
                        return (label: profile.name, shortcut: shortcut)
                    }
                )
                row(
                    symbol: "waveform",
                    text: "Choose a profile from the recording overlay. The profile selected when you stop is applied to the whole transcript.",
                    keys: []
                )
            }
        }
    }

    private func row(symbol: String, text: String, keys: [(label: String, shortcut: KeyboardShortcut?)]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Color.mfAccent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                if !keys.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(keys.enumerated()), id: \.offset) { _, item in
                            HStack(spacing: 8) {
                                Text(item.label)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.mfTextPrimary.opacity(0.62))
                                Text(item.shortcut?.displayString ?? "Not set")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.mfTextPrimary.opacity(0.8))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(Color.mfFill(0.08))
                                    )
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }
}
