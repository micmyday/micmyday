import SwiftUI

/// Settings → Overlay.
///
/// The distinguishing idea: while this pane is open the **real overlay** is on
/// the real screen, in its recording state, at full size and in the exact spot
/// it will occupy. Changing size or position moves the actual thing under your
/// cursor, so there is no thumbnail that can lie about the result.
struct OverlayPane: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        SettingsCard(
            eyebrow: "Overlay",
            caption: "Keep recording status visible above your apps. The Wide pill also shows the active rewrite profile."
        ) {
            SettingsRow(title: "Show the overlay while recording") {
                Toggle("", isOn: $settings.overlayEnabled)
                    .labelsHidden().toggleStyle(.switch).tint(.mfAccent)
            }
        }

        if settings.overlayEnabled {
            SettingsCard(
                eyebrow: "Live preview",
                caption: "Preview words as you speak and see rewrite results before insertion. Works with local transcription models and Apple Speech in local mode with Live text enabled."
            ) {
                SettingsRow(title: "Show live text preview") {
                    Toggle("", isOn: $settings.overlayLivePreview)
                        .labelsHidden().toggleStyle(.switch).tint(.mfAccent)
                }
            }

            SettingsCard(
                eyebrow: "Shape",
                caption: "Choose a compact pill or a dock that combines controls and the text preview."
            ) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                    spacing: 8
                ) {
                    ForEach(OverlayStyle.allCases) { option in
                        StyleCard(option: option, selected: settings.overlayStyle == option) {
                            settings.overlayStyle = option
                        }
                    }
                }
            }

            // Only the pill. Size describes what it adds as it grows, a
            // meter and then a profile; the dock's size is decided by whether
            // it is showing words, so it has nothing to ask here.
            if settings.overlayStyle == .pill {
                SettingsCard(eyebrow: "Size") {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(OverlaySize.allCases) { option in
                            SizeCard(option: option, selected: settings.overlaySize == option) {
                                settings.overlaySize = option
                            }
                        }
                    }
                }
            }

            // Only the Dock has a surface to choose, and the choice is
            // meaningless while the pill is the shape, so it is asked only
            // where it applies.
            if settings.overlayStyle == .dock {
                SettingsCard(
                    eyebrow: "Dock design",
                    caption: "How the dock itself is drawn. Theme follows the app's own colours; the rest are designs of their own, previewed on screen while these settings are open."
                ) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                        spacing: 10
                    ) {
                        ForEach(DockStyle.allCases) { option in
                            DockStyleCard(
                                option: option,
                                selected: settings.overlayDockStyle == option
                            ) {
                                settings.overlayDockStyle = option
                            }
                        }
                    }
                }
            }

            // Only the Dock draws one, so it is only asked about there.
            if settings.overlayStyle == .dock {
                SettingsCard(
                    eyebrow: "Time remaining",
                    caption: "Show a progress line along the bottom of the dock as the recording approaches the time limit set in Recording."
                ) {
                    SettingsRow(title: "Show how much recording time is left") {
                        Toggle("", isOn: $settings.overlayElapsedLine)
                            .labelsHidden().toggleStyle(.switch).tint(.mfAccent)
                    }
                }
            }

            SettingsCard(eyebrow: "Visibility") {
                SettingsRow(title: "Overlay visibility", detail: "Higher values make the overlay more opaque.") {
                    OverlayVisibilityField()
                }
            }

            SettingsCard(
                eyebrow: "Position",
                caption: "Choose where the overlay appears on screen. Changes are previewed while these settings are open."
            ) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                    spacing: 10
                ) {
                    ForEach(OverlayPosition.allCases) { position in
                        PositionCell(position: position, selected: settings.overlayPosition == position) {
                            settings.overlayPosition = position
                        }
                    }
                }
            }
        }
    }
}

/// One shape to choose from, drawn rather than only described.
private struct StyleCard: View {
    let option: OverlayStyle
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 7) {
                IndicatorSchematic(style: option, active: selected)
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .strokeBorder(selected ? Color.mfAccent : Color.mfFill(0.22), lineWidth: 1.5)
                            .frame(width: 13, height: 13)
                        if selected { Circle().fill(Color.mfAccent).frame(width: 6, height: 6) }
                    }
                    Text(option.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mfTextPrimary)
                }
                Text(option.detail)
                    .font(.system(size: 11))
                    .lineSpacing(2)
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.mfAccent.opacity(0.12) : Color.mfFill(0.04),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? Color.mfAccent : Color.clear, lineWidth: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

private struct SizeCard: View {
    let option: OverlaySize
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 7) {
                OverlaySizeSchematic(size: option, active: selected)
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .strokeBorder(selected ? Color.mfAccent : Color.mfFill(0.22), lineWidth: 1.5)
                            .frame(width: 13, height: 13)
                        if selected { Circle().fill(Color.mfAccent).frame(width: 6, height: 6) }
                    }
                    Text(option.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mfTextPrimary)
                }
                Text(option.detail)
                    .font(.system(size: 11))
                    .lineSpacing(2)
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.mfAccent.opacity(0.12) : Color.mfFill(0.04),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? Color.mfAccent : Color.clear, lineWidth: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

/// One Dock design to choose from, drawn as a miniature of the real thing.
///
/// A name and a colour chip could not tell these apart: half of what separates
/// them is the corner, the frame, the weight of the fill and whether the
/// controls sit on a tray. So the swatch is the panel itself at half width —
/// two lines of words, a stop button, a meter, the profile chip and the
/// time-remaining line, in the style's own colours.
private struct DockStyleCard: View {
    let option: DockStyle
    let selected: Bool
    let choose: () -> Void

    private var surface: DockSurface { option.surface(tint: .mfRecord) }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: min(surface.cornerRadius, 22), style: .continuous)
    }

    /// Stands in for the desktop, so the translucent styles read as
    /// translucent rather than as whatever colour they happen to resolve to
    /// against the settings window.
    private var wallpaper: some View {
        LinearGradient(
            colors: [Color(hex: 0x4C5673), Color(hex: 0x272D3C)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @ViewBuilder
    private var fill: some View {
        switch surface.body {
        case let .solid(color):
            color
        case let .gradient(stops, start, end):
            LinearGradient(gradient: Gradient(stops: stops), startPoint: start, endPoint: end)
        case let .material(tint, _):
            tint
        }
    }

    private var preview: some View {
        ZStack {
            wallpaper
            fill
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(surface.settled).frame(height: 3)
                    Capsule().fill(surface.tentative).frame(width: 52, height: 3)
                }
                .padding(.horizontal, surface.paddingX * 0.7)
                .padding(.top, 9)

                Spacer(minLength: 6)

                HStack(spacing: 6) {
                    RoundedRectangle(
                        cornerRadius: min(surface.stopRadius * 0.55, 6),
                        style: .continuous
                    )
                    .fill(surface.stopFill)
                    .overlay {
                        if let stroke = surface.stopStroke {
                            RoundedRectangle(cornerRadius: min(surface.stopRadius * 0.55, 6), style: .continuous)
                                .strokeBorder(stroke.color, lineWidth: stroke.width)
                        }
                    }
                    .frame(width: 12, height: 12)

                    HStack(alignment: .center, spacing: 1.5) {
                        ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, value in
                            RoundedRectangle(cornerRadius: surface.meterBarRadius * 0.6, style: .continuous)
                                .fill(surface.meterTop ?? surface.meter)
                                .frame(width: 1.6, height: 3 + value * 7)
                        }
                    }

                    Spacer(minLength: 4)

                    RoundedRectangle(cornerRadius: min(surface.chipRadius, 4), style: .continuous)
                        .fill(surface.chipFill)
                        .overlay {
                            RoundedRectangle(cornerRadius: min(surface.chipRadius, 4), style: .continuous)
                                .strokeBorder(
                                    surface.chipStroke?.color ?? surface.chipText.opacity(0.35),
                                    lineWidth: 0.5
                                )
                        }
                        .frame(width: 26, height: 9)
                }
                .padding(.horizontal, surface.paddingX * 0.7)
                .frame(height: surface.rowHeight * 0.62)
                .background(alignment: .top) {
                    if let tray = surface.tray {
                        ZStack(alignment: .top) {
                            tray.fill
                            Rectangle().fill(tray.hairline).frame(height: 1)
                        }
                    }
                }

                Rectangle()
                    .fill(surface.progress)
                    .frame(width: 44, height: 2)
                    .padding(.leading, 8)
            }
        }
        .frame(height: 62)
        .clipShape(shape)
        .overlay {
            if let highlight = surface.topHighlight {
                Rectangle()
                    .fill(highlight.color)
                    .frame(height: highlight.width)
                    .padding(.horizontal, surface.cornerRadius)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .overlay {
            // Only the outermost hairline: the swatch is too small for
            // Carbon's three to read as anything but a thick edge.
            if let stroke = surface.frame.first {
                shape.strokeBorder(stroke.color, lineWidth: stroke.width)
            }
        }
        .overlay {
            // Still, unlike the real one. Eighteen swatches each turning a
            // gradient would be the busiest thing in Settings.
            if case .auroraRing = surface.special {
                AngularGradient(colors: DockSurface.auroraRing, center: .center)
                    .scaleEffect(2)
                    .mask { shape.strokeBorder(.black, lineWidth: 1.5) }
            }
        }
    }

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 8) {
                preview
                HStack(spacing: 4) {
                    Text(option.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.mfTextPrimary)
                        .lineLimit(1)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.mfAccent)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.mfAccent.opacity(0.16) : Color.mfFill(0.04))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        selected ? Color.mfAccent : Color.mfFill(0.08),
                        lineWidth: selected ? 1.5 : 1
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel("\(option.title). \(option.detail)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// A fixed trace rather than a random one: the swatches sit side by side,
    /// and eighteen different shapes would read as eighteen different meters.
    private static let bars: [CGFloat] = [0.2, 0.45, 0.7, 1, 0.75, 0.4, 0.22]
}

/// A picture of the result rather than a list of names: a miniature screen with
/// the pill parked in the corner that cell represents.
private struct PositionCell: View {
    let position: OverlayPosition
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            ZStack(alignment: alignment) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.mfAccent.opacity(0.14) : Color.mfFill(0.04))
                Capsule()
                    .fill(selected ? Color.mfAccent : Color.mfTextPrimary.opacity(0.3))
                    .frame(width: 22, height: 6)
                    .padding(7)
            }
            .frame(height: 52)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? Color.mfAccent : Color.mfFill(0.08), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(position.title)
    }

    private var alignment: Alignment {
        switch position {
        case .tl: return .topLeading
        case .tc: return .top
        case .tr: return .topTrailing
        case .ml: return .leading
        case .mc: return .center
        case .mr: return .trailing
        case .bl: return .bottomLeading
        case .bc: return .bottom
        case .br: return .bottomTrailing
        }
    }
}

/// A typed percentage with a stepper rather than a fixed menu of steps: the
/// right amount depends on the wallpaper and on the app underneath, so any
/// value in range should be reachable.
///
/// Expressed as visibility rather than transparency, so the number rises as the
/// overlay gets easier to see. It is also what the window layer wants, so
/// nothing is inverted on the way through.
private struct OverlayVisibilityField: View {
    @EnvironmentObject private var settings: SettingsStore

    private var percent: Binding<Int> {
        Binding(
            get: { Int((settings.overlayOpacity * 100).rounded()) },
            set: { settings.overlayOpacity = Double(min(100, max(1, $0))) / 100 }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("", value: percent, format: .number)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.mfTextPrimary)
                .frame(width: 34)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.mfCanvasDeep, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text("%")
                .font(.system(size: 12))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.5))
            Stepper("", value: percent, in: 1...100, step: 5)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}
