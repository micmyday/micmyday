import SwiftUI

/// 07 Ready — the finish. Centred, and the only chapter with no footer: the
/// single CTA on screen is its own.
struct ReadyChapter: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore
    @Binding var launchAtLogin: Bool
    let start: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)

            VStack(spacing: 12) {
                Text("You’re ready to dictate.")
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.95)
                    .foregroundStyle(Color.mfTextPrimary)

                pressLine
            }
            .frame(maxWidth: 460)
            .background(alignment: .top) {
                // A 340x220 ellipse whose top edge sits 90pt above the block.
                Ellipse()
                    .fill(
                        RadialGradient(
                            stops: [
                                .init(color: Color.mfAccent.opacity(0.3), location: 0),
                                .init(color: Color.mfReady.opacity(0.08), location: 0.45),
                                .init(color: Color.mfAccent.opacity(0), location: 0.72),
                            ],
                            center: .center,
                            startRadius: 0,
                            // farthest-corner of the 340x220 box: √(170²+110²).
                            endRadius: 202.5
                        )
                    )
                    .frame(width: 340, height: 220)
                    .offset(y: -90)
                    .allowsHitTesting(false)
            }

            Button(action: start) {
                Label("Finish setup", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.beaconLarge)
            .frame(maxWidth: 520)
            .keyboardShortcut(.defaultAction)

            trialLine

            Toggle(isOn: $launchAtLogin) {
                Text("Open at login")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.8))
            }
            .toggleStyle(.switch)
            .tint(.mfAccent)
            .fixedSize()

            summaryGrid
                .frame(maxWidth: 520)

            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity)
    }

    /// Says how long the trial runs, at the one moment the user is definitely
    /// looking. Without this the first they learn of it is dictation refusing
    /// to start on day eight, which is a bad way to find out you were on a
    /// clock. Nothing here nags: it states a fact and offers a way in.
    @ViewBuilder
    private var trialLine: some View {
        switch appState.licence.state {
        case let .trial(daysRemaining):
            HStack(spacing: 6) {
                Text(daysRemaining == 1
                     ? "Your trial ends today."
                     : "Your trial has \(daysRemaining) days remaining.")
                Button("I have a licence key") {
                    appState.showSettings(selecting: .licence)
                }
                .buttonStyle(.beaconPlain)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Color.mfTextPrimary.opacity(0.5))
        case .licensed, .expired, .needsRevalidation:
            // Licensed needs no reminder, and the two blocked states are
            // handled where they matter, at the moment a dictation is refused.
            EmptyView()
        }
    }

    private var pressLine: some View {
        VStack(spacing: 6) {
            Text("Click where you want your text,")
            HStack(spacing: 6) {
                Text("then use")
                Text(settings.shortcut.displayString)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.mfFill(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("to start recording.")
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(Color.mfTextPrimary.opacity(0.62))
        .accessibilityElement(children: .combine)
    }

    private var summaryGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            cell("SHORTCUT", "\(settings.shortcut.displayString) \u{2014} \(settings.shortcutMode.shortTitle)")
            cell("ENGINE", engineSummary)
            cell("OUTPUT", appState.accessibilityGranted
                 ? "At your cursor, automatically"
                 : "Clipboard only \u{2014} press \u{2318}V")
            cell("REWRITE", rewriteSummary)
        }
    }

    private var engineSummary: String {
        guard settings.provider.isLocalModel else { return settings.provider.title }
        return WhisperModelCatalog.model(withID: settings.whisperModelID)?.displayName ?? settings.whisperModelID
    }

    private var rewriteSummary: String {
        guard settings.enhancementEnabled else { return "Off \u{2014} no AI rewriting" }
        let profile = settings.currentRewriteProfile
        return "\(profile?.name ?? "On") \u{00B7} \(settings.rewriteProvider.title)"
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .lineSpacing(3)
                .foregroundStyle(Color.mfTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mfFill(0.04), in: RoundedRectangle(cornerRadius: MFMetric.radiusCard, style: .continuous))
    }
}
