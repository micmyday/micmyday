import SwiftUI

/// 05 Voice — the shortcut, what a press means, and a live try-out.
///
/// Voice activation is deliberately absent: it is not a first-run decision.
struct VoiceChapter: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore
    @Binding var capturing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ChapterHeading(
                title: SettingsPane.voice.title,
                lede: SettingsPane.voice.lede
            )

            shortcutRow

            if settings.shortcut.isModifierOnly && !appState.inputMonitoringGranted {
                Text("Input Monitoring is required for single-modifier shortcuts such as right Shift or Fn.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.7))
                Button("Allow Input Monitoring") { appState.requestInputMonitoringPermission() }
                    .buttonStyle(.beacon)
            }

            HStack(alignment: .top, spacing: 12) {
                ForEach(ShortcutActivationMode.allCases) { mode in
                    BehaviourCard(mode: mode, isSelected: settings.shortcutMode == mode) {
                        settings.shortcutMode = mode
                    }
                }
            }

            TryOutCard()
        }
    }

    private var shortcutRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Shortcut")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mfTextPrimary)
                Text(capturing
                     ? "Press a key combination, a function key or a single modifier such as right Shift. Press Esc to cancel."
                     : "Start and stop recording without switching apps.")
                    .font(.system(size: 11))
                    .lineSpacing(2)
                    .foregroundStyle(capturing ? Color.mfAccent : Color.mfTextPrimary.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ShortcutRecorderView(shortcut: $settings.shortcut) { capturing = $0 }
                .frame(width: 290)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            capturing ? Color.mfAccent.opacity(0.10) : Color.mfFill(0.04),
            in: RoundedRectangle(cornerRadius: MFMetric.radiusCard, style: .continuous)
        )
    }
}

// MARK: - Behaviour

struct BehaviourCard: View {
    let mode: ShortcutActivationMode
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 10) {
                PressDiagram(mode: mode, isSelected: isSelected)
                Text(mode.shortTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mfTextPrimary)
                Text(mode.cardDetail)
                    .font(.system(size: 11))
                    .lineSpacing(2)
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.mfAccent.opacity(0.12) : Color.mfFill(0.04),
                in: RoundedRectangle(cornerRadius: MFMetric.radiusCard, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: MFMetric.radiusCard, style: .continuous)
                    .strokeBorder(isSelected ? Color.mfAccent : Color.clear, lineWidth: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Two tracks: KEY (accent, when the shortcut is held) and MIC (pink, when the
/// microphone is actually live). Their difference is the whole point.
struct PressDiagram: View {
    let mode: ShortcutActivationMode
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            track(label: "KEY", spans: keySpans, color: .mfAccent)
            track(label: "MIC", spans: micSpans, color: .mfRecord)
        }
    }

    private func track(label: String, spans: [(Double, Double)], color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.35))
                .frame(width: 28, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.mfFill(0.06))
                        .frame(height: 8)
                    ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                        Capsule()
                            .fill(color.opacity(isSelected ? 1 : 0.45))
                            .frame(width: max(4, geo.size.width * (span.1 - span.0)), height: 8)
                            .offset(x: geo.size.width * span.0)
                    }
                }
                .frame(height: 8)
            }
            .frame(height: 8)
        }
    }

    /// Spans are (start, end) as fractions of the timeline.
    private var keySpans: [(Double, Double)] {
        switch mode {
        case .tapAndHold: return [(0.06, 0.11), (0.30, 0.35), (0.55, 0.92)]
        case .tapToggle: return [(0.10, 0.15), (0.78, 0.83)]
        case .holdToRecord: return [(0.15, 0.85)]
        }
    }

    private var micSpans: [(Double, Double)] {
        switch mode {
        case .tapAndHold: return [(0.11, 0.30), (0.55, 0.92)]
        case .tapToggle: return [(0.15, 0.78)]
        case .holdToRecord: return [(0.15, 0.85)]
        }
    }
}

// MARK: - Try it

/// A real recording through the chosen engine, with the transcript shown here
/// so the user can review it before finishing setup.
private struct TryOutCard: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                statusIcon
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusColor)
                Spacer(minLength: 0)
            }
            .frame(height: 30)

            body_

            HStack(spacing: 12) {
                Button(buttonTitle) { toggle() }
                    .buttonStyle(.beacon)
                Spacer(minLength: 0)
                if let stats = statsLine {
                    Text(stats)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.42))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mfFill(0.07), in: RoundedRectangle(cornerRadius: MFMetric.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MFMetric.radiusCard, style: .continuous)
                .strokeBorder(Color.mfFill(0.06), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var body_: some View {
        if isRecording {
            // Chapter 05 instance: 56 segments at 44pt.
            BeaconLevelMeter(
                level: Double(appState.inputLevel),
                segments: 56,
                height: 44,
                isRecording: true
            )
            .frame(height: 56)
        } else if !transcript.isEmpty {
            Text(transcript)
                .font(.system(size: 16))
                .foregroundStyle(Color.mfTextPrimary)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
        } else {
            Color.clear.frame(height: 56)
        }
    }

    private var isRecording: Bool {
        if case .recording = appState.phase { return true }
        return false
    }
    private var isTranscribing: Bool { appState.phase == .transcribing }

    private var transcript: String { appState.lastTranscript }

    private var statusText: String {
        if isRecording { return "Listening \u{2014} speak now." }
        if isTranscribing { return "Transcribing with \(engineName)\u{2026}" }
        if !transcript.isEmpty {
            return "Review your transcript or try another recording."
        }
        return "Try dictating a sentence."
    }

    private var statusColor: Color {
        isRecording ? .mfRecord : .mfTextPrimary.opacity(0.6)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isRecording {
            Circle().fill(Color.mfRecord).frame(width: 7, height: 7)
        } else if isTranscribing {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "mic")
                .font(.system(size: 11))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
        }
    }

    private var engineName: String {
        if settings.provider.isLocalModel {
            return WhisperModelCatalog.model(withID: settings.whisperModelID)?.displayName ?? "the local model"
        }
        return settings.provider.title
    }

    private var buttonTitle: String {
        if isRecording { return "Stop recording" }
        return transcript.isEmpty ? "Start recording" : "Try again"
    }

    private var statsLine: String? {
        guard !transcript.isEmpty else { return nil }
        let words = transcript.split(separator: " ").count
        return words == 1 ? "1 word transcribed" : "\(words) words transcribed"
    }

    private func toggle() {
        // Same entry point the global shortcut uses, so the try-out exercises
        // the real path rather than a parallel one — but marked as practice, so
        // the transcript is shown here instead of being pasted into whatever
        // app happened to be open before setup started.
        appState.toggleRecording(practice: true)
    }
}
