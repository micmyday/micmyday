import SwiftUI

// The Beacon visual language, from Assets/Design/export.
//
// Three colour roles and nothing more: accent for anything interactive,
// record for a live microphone (never decorative), ready/warn for status.
// Surfaces are ink; cards carry a flat tinted fill with no border and no
// shadow, which is what separates this from the previous macOS-native look.

/// A flat card. No border, no shadow — the fill alone carries the grouping.
struct BeaconCard<Content: View>: View {
    var tint: Color = .mfSurfaceCard
    var selected = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(MFMetric.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: MFMetric.radiusCard, style: .continuous))
            .overlay {
                // The only stroke in the system: the selection ring.
                if selected {
                    RoundedRectangle(cornerRadius: MFMetric.radiusCard, style: .continuous)
                        .strokeBorder(Color.mfAccent, lineWidth: 2)
                }
            }
    }
}

/// The one prominent action per screen.
struct BeaconButtonStyle: ButtonStyle {
    var prominent = true
    var large = false
    var plain = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, plain ? 0 : (large ? 22 : 18))
            .padding(.vertical, plain ? 0 : (large ? 11 : 9))
            .background(plain ? Color.clear : background(pressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: MFMetric.radiusControl, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var foreground: Color {
        if plain { return .mfTextPrimary.opacity(hovering ? 0.7 : 0.45) }
        // Not white: the amber accent in Sunrise and Ember needs dark text on
        // it, and the palette carries the right one per theme.
        return prominent ? .mfOnAccent : .mfTextPrimary
    }

    private func background(pressed: Bool) -> Color {
        guard prominent else { return Color.mfFill(hovering ? 0.10 : 0.06) }
        if pressed { return .mfAccentPress }
        return hovering ? .mfAccentHover : .mfAccent
    }
}

extension ButtonStyle where Self == BeaconButtonStyle {
    static var beacon: BeaconButtonStyle { BeaconButtonStyle(prominent: true) }
    static var beaconQuiet: BeaconButtonStyle { BeaconButtonStyle(prominent: false) }
    /// The single footer action: larger, and the only prominent control on screen.
    static var beaconLarge: BeaconButtonStyle { BeaconButtonStyle(prominent: true, large: true) }
    /// Text-only, for "Skip, use defaults".
    static var beaconPlain: BeaconButtonStyle { BeaconButtonStyle(prominent: false, plain: true) }
}

/// Status tone. `record` is reserved for a live microphone.
enum BeaconTone {
    case ready, warn, record, idle

    // Reads the active theme's palette, which lives on the main actor.
    @MainActor
    var color: Color {
        switch self {
        case .ready: return .mfReady
        case .warn: return .mfWarn
        case .record: return .mfRecord
        case .idle: return .mfTextPrimary.opacity(0.45)
        }
    }
}

/// A pill carrying one piece of state: granted, needs attention, live.
struct BeaconChip: View {
    let text: String
    var symbol: String?
    var tone: BeaconTone = .idle

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tone.color.opacity(0.14), in: Capsule())
    }
}

/// Sidebar row. The step list is the progress indicator in this design, which
/// is why there is no progress bar.
struct BeaconStepRow: View {
    let index: Int
    let title: String
    let symbol: String
    let state: StepState
    let action: () -> Void

    enum StepState { case done, current, upcoming }

    init(index: Int, title: String, symbol: String, state: StepState, action: @escaping () -> Void) {
        self.index = index
        self.title = title
        self.symbol = symbol
        self.state = state
        self.action = action
    }

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                marker
                Text(title)
                    .font(.system(size: 13, weight: state == .current ? .semibold : .regular))
                    .foregroundStyle(titleColor)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(rowFill, in: RoundedRectangle(cornerRadius: MFMetric.radiusControl, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state == .upcoming)
        .onHover { hovering = $0 }
    }

    private var marker: some View {
        ZStack {
            Circle()
                .fill(state == .current ? Color.mfAccent : Color.mfFill(0.08))
                .frame(width: 22, height: 22)
            switch state {
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.mfReady)
            case .current:
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            case .upcoming:
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.35))
            }
        }
    }

    private var titleColor: Color {
        switch state {
        case .current: return .mfTextPrimary
        case .done: return .mfTextPrimary.opacity(0.75)
        case .upcoming: return .mfTextPrimary.opacity(0.35)
        }
    }

    private var rowFill: Color {
        if state == .current { return .white.opacity(0.06) }
        return hovering && state == .done ? .white.opacity(0.04) : .clear
    }
}

/// Section heading inside a step.
struct BeaconSectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.mfSectionTitle)
            .foregroundStyle(Color.mfTextPrimary)
    }
}

/// Secondary prose. Never pure white — the ramp is carried by opacity.
struct BeaconBody: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.mfBody)
            .lineSpacing(4)
            .foregroundStyle(Color.mfTextPrimary.opacity(0.62))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Anything the machine owns: shortcuts, timers, URLs, model identifiers.
struct BeaconMono: View {
    let text: String
    var tone: Color = .mfTextPrimary
    var body: some View {
        Text(text)
            .font(.mfMono)
            .foregroundStyle(tone.opacity(0.85))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.mfFill(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// The audio scope, built to `Assets/Design/export2/AudioScope.md`.
///
/// Explicitly NOT a waveform: no history, no scrolling, no mirroring about a
/// baseline. The level never scales the bars — it decides how many are *lit*,
/// left to right, over a fixed centre-weighted height envelope. An unlit bar
/// keeps its shape at 34% height, so the row always reads as a form rather
/// than an empty container.
///
/// One component, three sizes: chapter 01 uses 72 segments at 56pt, the
/// chapter 05 try-out 56 at 44pt, and the menu-bar panel 24 at 24pt.
struct BeaconLevelMeter: View {
    var level: Double
    var segments: Int = 56
    var height: CGFloat = 44
    var isRecording: Bool = true

    private var lit: Int {
        Int((min(max(level, 0), 1) * Double(segments)).rounded())
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                Capsule()
                    .fill(index < lit
                          ? (isRecording ? Color.mfRecord : Color.mfAccent)
                          : Color.mfFill(0.10))
                    .frame(height: barHeight(index))
            }
        }
        .frame(height: height)
        // The 120 ms ease-out is what makes it read as an instrument rather
        // than a strobe. Nothing else here animates.
        .animation(.easeOut(duration: 0.12), value: level)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let count = Double(segments)
        let mid = (count - 1) / 2
        let centre = mid == 0 ? 1 : 1 - abs(Double(index) - mid) / mid
        let envelope = 0.28 + 0.72 * centre
        let dim: Double = index < lit ? 1.0 : 0.34
        return max(3, height * envelope * dim)
    }
}
