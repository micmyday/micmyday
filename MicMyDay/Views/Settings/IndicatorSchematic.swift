import SwiftUI

/// A miniature of the screen, with the indicator drawn where it would sit.
///
/// The words on a settings card describe a shape nobody has seen yet, and the
/// difference between these choices is entirely a matter of shape and place:
/// a small capsule with a panel above it, one panel that grows, or a strip of
/// fixed width. A drawing answers in a glance what a sentence has to spend
/// three lines on, which is the same reason the theme swatches show a
/// miniature rather than a list of colour names.
///
/// Schematic on purpose. It is a diagram, not a screenshot: real proportions,
/// no real words, so it cannot go stale when the indicator's own layout moves
/// on.
struct IndicatorSchematic: View {
    let style: OverlayStyle
    /// Drawn in the record colour when this is the chosen one, so the picker
    /// reads at a glance the way the indicator itself does.
    let active: Bool

    private var ink: Color { active ? .mfRecord : Color.mfTextPrimary.opacity(0.55) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.mfCanvasDeep)
            // The window the indicator floats over, so "where does it sit"
            // has something to be relative to.
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.mfFill(0.05))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 20)
            indicator
        }
        .frame(height: 74)
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.mfHairline, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch style {
        case .pill:
            VStack(spacing: 4) {
                Spacer()
                // The preview panel, which is the pill's distinguishing
                // feature: a second object, above the first.
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(ink.opacity(0.25))
                    .frame(width: 46, height: 11)
                Capsule().fill(ink).frame(width: 30, height: 8)
            }
            .padding(.bottom, 9)

        case .dock:
            VStack(spacing: 0) {
                Spacer()
                VStack(alignment: .leading, spacing: 3) {
                    // Words growing upward inside the same container.
                    Capsule().fill(ink.opacity(0.32)).frame(width: 40, height: 3)
                    Capsule().fill(ink.opacity(0.32)).frame(width: 30, height: 3)
                    Capsule().fill(ink).frame(width: 46, height: 6)
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.mfFill(0.16))
                )
            }
            .padding(.bottom, 9)

        }
    }
}

/// The same idea for the three sizes: what each one actually shows.
struct OverlaySizeSchematic: View {
    let size: OverlaySize
    let active: Bool

    private var ink: Color { active ? .mfRecord : Color.mfTextPrimary.opacity(0.55) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.mfCanvasDeep)
            pill
        }
        .frame(height: 38)
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.mfHairline, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var pill: some View {
        switch size {
        case .mini:
            // A circle: the badge is the whole indicator.
            Circle().fill(ink).frame(width: 14, height: 14)
        case .compact:
            HStack(spacing: 4) {
                Circle().fill(ink).frame(width: 7, height: 7)
                meter
                Capsule().fill(ink.opacity(0.4)).frame(width: 12, height: 3)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.mfFill(0.16)))
        case .wide:
            HStack(spacing: 4) {
                Circle().fill(ink).frame(width: 7, height: 7)
                meter
                Capsule().fill(ink.opacity(0.4)).frame(width: 10, height: 3)
                // The armed profile, which is what Wide adds.
                Capsule().fill(ink.opacity(0.28)).frame(width: 18, height: 6)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.mfFill(0.16)))
        }
    }

    private var meter: some View {
        HStack(spacing: 1.5) {
            ForEach([4.0, 7.0, 5.0, 8.0, 6.0], id: \.self) { height in
                Capsule().fill(ink).frame(width: 1.5, height: height)
            }
        }
    }
}
