import SwiftUI

// MARK: - Text atoms

/// 10pt mono, uppercase, wide tracking. Labels a value rather than being one.
struct Eyebrow: View {
    let text: String
    var color: Color = DS.textSecondary

    init(_ text: String, color: Color = DS.textSecondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(DSFont.mono(10, .medium))
            .tracking(0.8)
            .foregroundStyle(color)
    }
}

/// Explanatory line that sits directly under the control it explains.
struct DSCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(DSFont.ui(11))
            .lineSpacing(2)
            .foregroundStyle(DS.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The shortcut, rendered as the machine-owned string it is.
struct KeyCombo: View {
    let combo: String
    var inverse = false

    var body: some View {
        Text(combo)
            .font(DSFont.mono(12, .medium))
            .foregroundStyle(inverse ? Color.mfFill(0.85) : DS.textSecondary)
    }
}

enum StatusTone {
    case ok, warn, danger, neutral

    var color: Color {
        switch self {
        case .ok: return DS.statusOKText
        case .warn: return DS.statusWarnText
        case .danger: return DS.record
        case .neutral: return DS.textSecondary
        }
    }
}

struct StatusLabel: View {
    let text: String
    var tone: StatusTone = .neutral
    var symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10))
            }
            Text(text)
                .font(DSFont.ui(11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tone.color)
    }
}

// MARK: - Surfaces

/// Cards are flat: a tinted fill, no border, no shadow, no coloured edge.
struct DSCard<Content: View>: View {
    var padding: CGFloat = 10
    var spacing: CGFloat = 7
    var radius: CGFloat = DS.Radius.card
    var fill: Color = DS.surfaceCard
    var borderColor: Color?
    var borderWidth: CGFloat = 1
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing, content: content)
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if let borderColor {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: borderWidth)
                }
            }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(DS.borderHairline)
            .frame(height: 1)
    }
}

// MARK: - Meters

/// Four-dot capability meter (speed / privacy / accuracy). A dash when the
/// value is unknowable, as it is for a server the user hosts themselves.
struct DotsMeter: View {
    let filled: Int
    var total = 4
    var color: Color = DS.accent

    var body: some View {
        if filled <= 0 {
            Text("—")
                .font(DSFont.mono(11))
                .foregroundStyle(DS.textTertiary)
        } else {
            HStack(spacing: 3) {
                ForEach(0 ..< total, id: \.self) { index in
                    Circle()
                        .fill(index < filled ? color : DS.surfaceFillStrong)
                        .frame(width: 6, height: 6)
                }
            }
        }
    }
}

/// Centre-weighted level meter. The per-bar texture is deterministic so the
/// meter reads as a waveform rather than noise, and only its amplitude moves.
struct LevelMeter: View {
    let level: Float
    var segments = 48
    var height: CGFloat = 40
    var tint: Color = DS.record

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = 2
            let width = max(1, (geometry.size.width - gap * CGFloat(segments - 1)) / CGFloat(segments))
            HStack(alignment: .center, spacing: gap) {
                ForEach(0 ..< segments, id: \.self) { index in
                    Capsule()
                        .fill(tint)
                        .frame(width: width, height: barHeight(index))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }
        .frame(height: height)
        .dsAnimation(.linear(duration: 0.11), value: level)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let center = Double(segments - 1) / 2
        let distance = center == 0 ? 0 : abs(Double(index) - center) / center
        let weight = pow(cos(distance * .pi / 2), 0.7)
        let texture = 0.55 + 0.45 * Self.noise(index)
        let amplitude = Double(min(max(level, 0), 1)) * weight * texture
        return max(2, height * CGFloat(amplitude))
    }

    /// Stable pseudo-random value in 0...1 for a bar index.
    private static func noise(_ index: Int) -> Double {
        let x = sin(Double(index) * 12.9898) * 43758.5453
        return x - x.rounded(.down)
    }
}

struct DSProgressBar: View {
    let value: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.surfaceFillStrong)
                Capsule()
                    .fill(DS.accent)
                    .frame(width: geometry.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
        .dsAnimation(DS.progress, value: value)
    }
}

// MARK: - Indicators

/// A 22pt ring that fills with the accent and draws a check when granted.
struct CheckCircle: View {
    let isOn: Bool
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(DS.borderStrong, lineWidth: 1.5)
                .opacity(isOn ? 0 : 1)
            Circle()
                .fill(DS.accent)
                .opacity(isOn ? 1 : 0)
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(.white)
                .opacity(isOn ? 1 : 0)
                .scaleEffect(isOn ? 1 : 0.6)
        }
        .frame(width: size, height: size)
        .dsAnimation(.timingCurve(0.2, 0, 0, 1, duration: 0.45), value: isOn)
    }
}

/// A radio dot that thickens its inset ring when selected, matching the
/// prototype's `inset 0 0 0 4px` treatment.
struct RadioDot: View {
    let isOn: Bool
    var size: CGFloat = 13

    var body: some View {
        Circle()
            .strokeBorder(isOn ? DS.accent : DS.borderStrong,
                          lineWidth: isOn ? size / 2 : 1.5)
            .frame(width: size, height: size)
            .dsAnimation(DS.control, value: isOn)
    }
}

struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< count, id: \.self) { dot in
                Circle()
                    .fill(dot == index ? DS.accent : DS.textSecondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
        .dsAnimation(DS.control, value: index)
    }
}

// MARK: - Form building blocks (Settings panes)

struct FormSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(DSFont.ui(13, .semibold))
                .foregroundStyle(DS.textPrimary)
            VStack(alignment: .leading, spacing: 10, content: content)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.surfaceFormWindow,
                            in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .strokeBorder(DS.borderHairline, lineWidth: 1)
                }
        }
    }
}

/// A label on the left, its control on the right, both vertically centred.
struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(DSFont.ui(13))
                .foregroundStyle(DS.textPrimary)
            Spacer(minLength: 8)
            content()
        }
    }
}

/// A capability badge: an eyebrow label above its value.
struct CapabilityBadge: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow(label, color: DS.textTertiary)
            Text(value)
                .font(DSFont.ui(11, .medium))
                .foregroundStyle(DS.textPrimary)
        }
    }
}

extension View {
    /// One look for every drop-down menu in Settings: regular control size and
    /// a fixed width, so pickers read as one family regardless of the pane.
    func dsMenuPicker(width: CGFloat, alignment: Alignment = .trailing) -> some View {
        labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.regular)
            .frame(width: width, alignment: alignment)
    }
}
