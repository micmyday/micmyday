import SwiftUI

/// MicMyDay palette — generated from the onboarding design.
/// Three roles only: accent for anything interactive, record for a live
/// microphone (never decorative), ready/warn for status.
/// The colour roles, resolved from whichever theme is active.
///
/// These stay static properties because the app reads them from hundreds of
/// places; making them computed is what lets the three themes exist without
/// rewriting every call site. Views do not observe them, so the windows using
/// them are rebuilt when the theme changes.
@MainActor
extension Color {
    private static var palette: AppTheme.Palette { ThemeRuntime.current.palette }

    /// Every interactive affordance.
    static var mfAccent: Color { palette.accent }
    /// Prominent button hover.
    static var mfAccentHover: Color { palette.accentHover }
    /// Prominent button pressed.
    static var mfAccentPress: Color { palette.accentPress }
    /// Text and glyphs sitting on top of the accent.
    static var mfOnAccent: Color { palette.onAccent }
    /// Granted / connected states.
    static var mfReady: Color { palette.ready }
    /// Only while the microphone is live; never decorative.
    static var mfRecord: Color { palette.record }
    static var mfOnRecord: Color { palette.onRecord }
    /// Needs attention.
    static var mfWarn: Color { palette.warn }
    /// Window background.
    static var mfCanvas: Color { palette.canvas }
    /// Sidebar background, one step deeper than the canvas.
    static var mfCanvasDeep: Color { palette.canvasDeep }
    /// Flat card fill. Translucent so it takes on whatever is behind it.
    static var mfSurfaceCard: Color { palette.cardTint.opacity(palette.cardOpacity) }
    /// Settings rail.
    static var mfSurfaceFormWindow: Color { palette.canvasDeep }
    /// Solid popover backing.
    static var mfPopover: Color { palette.popover }
    /// Body and titles.
    static var mfTextPrimary: Color { palette.textPrimary }
    /// Separators and control outlines.
    static var mfHairline: Color { palette.hairline.opacity(palette.hairlineOpacity) }

    /// A fill that reads as raised against the current canvas.
    ///
    /// Replaces the hardcoded `Color.white.opacity(…)` fills, which turned into
    /// invisible white-on-white once the light theme existed.
    static func mfFill(_ opacity: Double) -> Color {
        palette.cardTint.opacity(opacity)
    }
}

extension Font {
    static let mfTitle = Font.system(size: 32, weight: .bold, design: .default)
    static let mfSectionTitle = Font.system(size: 16, weight: .semibold)
    static let mfBody = Font.system(size: 14)
    static let mfCaption = Font.system(size: 11)
    /// Machine-owned strings: shortcuts, timers, URLs, model ids.
    static let mfMono = Font.system(size: 11, design: .monospaced)
}

enum MFMetric {
    static let radiusPill: CGFloat = 999
    static let radiusControl: CGFloat = 11
    static let radiusCard: CGFloat = 14
    static let radiusWindow: CGFloat = 16
    static let cardPadding: CGFloat = 18
    static let blockGap: CGFloat = 12
    static let sectionGap: CGFloat = 22
}
