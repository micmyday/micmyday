import SwiftUI

/// The four looks MicMyDay ships, taken from the design's token overrides.
///
/// They are a deliberate choice rather than a light/dark switch: Sunrise and
/// Ember are both dark, and Daybreak is the light one. Following the system
/// appearance is therefore not the same question as which theme is in use, and
/// the app asks it separately.
enum AppTheme: String, CaseIterable, Identifiable, Codable {
    /// Deep blue night before the sun is up.
    case sunrise
    /// Cool slate, periwinkle interactive. Yellow is demoted here to a single
    /// job: it means the microphone is live. The default.
    case indigo
    /// Full daylight: the light theme.
    case daybreak
    /// Warm near-black, the last of the light.
    case ember

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sunrise: return "Sunrise"
        case .indigo: return "Indigo"
        case .daybreak: return "Daybreak"
        case .ember: return "Ember"
        }
    }

    var detail: String {
        switch self {
        case .sunrise: return "Deep blue, warm yellow."
        case .indigo: return "Cool slate. Yellow means live. The default."
        case .daybreak: return "Light, for bright rooms."
        case .ember: return "Warm near-black, easy at night."
        }
    }

    /// Whether the theme reads as light, which AppKit needs so that system
    /// controls, scroll bars and text cursors match the surfaces around them.
    var isLight: Bool { self == .daybreak }

    var palette: Palette {
        switch self {
        case .sunrise:
            return Palette(
                accent: Color(hex: 0xFFC61F),
                accentHover: Color(hex: 0xFFD75A),
                accentPress: Color(hex: 0xE8A50A),
                onAccent: Color(hex: 0x3B2D22),
                ready: Color(hex: 0x5CD9F5),
                record: Color(hex: 0xFF4D6D),
                onRecord: Color.white,
                warn: Color(hex: 0xFF8FA8),
                canvas: Color(hex: 0x0C1524),
                canvasDeep: Color(hex: 0x0A1220),
                popover: Color(hex: 0x101A2C),
                textPrimary: Color(hex: 0xEEF2F8),
                cardTint: .white,
                cardOpacity: 0.045,
                hairline: .white,
                hairlineOpacity: 0.09
            )
        case .indigo:
            return Palette(
                accent: Color(hex: 0xA5AEFF),
                accentHover: Color(hex: 0xBBC1FF),
                accentPress: Color(hex: 0x8C97F5),
                onAccent: Color(hex: 0x1E2233),
                ready: Color(hex: 0x45D6A0),
                // Yellow, not the pink every other theme uses: in Indigo the
                // warm colour is reserved for the live microphone, which is
                // why the rest of the theme is cool.
                record: Color(hex: 0xFFC61F),
                onRecord: Color(hex: 0x1E2233),
                warn: Color(hex: 0xFFB454),
                canvas: Color(hex: 0x181B27),
                canvasDeep: Color(hex: 0x141621),
                popover: Color(hex: 0x1D2030),
                textPrimary: Color(hex: 0xEDEEF5),
                cardTint: .white,
                cardOpacity: 0.045,
                hairline: .white,
                hairlineOpacity: 0.09
            )
        case .daybreak:
            return Palette(
                accent: Color(hex: 0x2E3765),
                accentHover: Color(hex: 0x252C52),
                accentPress: Color(hex: 0x1C223F),
                onAccent: .white,
                ready: Color(hex: 0x17803D),
                record: Color(hex: 0xD0342C),
                onRecord: Color.white,
                warn: Color(hex: 0xB45309),
                canvas: .white,
                canvasDeep: Color(hex: 0xFAF7F1),
                popover: .white,
                textPrimary: Color(hex: 0x141A24),
                cardTint: Color(hex: 0x141A24),
                cardOpacity: 0.035,
                hairline: Color(hex: 0x141A24),
                hairlineOpacity: 0.10
            )
        case .ember:
            return Palette(
                accent: Color(hex: 0xFFC61F),
                accentHover: Color(hex: 0xFFD75A),
                accentPress: Color(hex: 0xE0A408),
                onAccent: Color(hex: 0x2A1F14),
                ready: Color(hex: 0x9FD356),
                record: Color(hex: 0xFF4A3D),
                onRecord: Color.white,
                warn: Color(hex: 0xFF8A5B),
                canvas: Color(hex: 0x15120C),
                canvasDeep: Color(hex: 0x100E08),
                popover: Color(hex: 0x1C170E),
                textPrimary: Color(hex: 0xF5EFE4),
                cardTint: Color(hex: 0xFFF0DC),
                cardOpacity: 0.045,
                hairline: Color(hex: 0xFFF0DC),
                hairlineOpacity: 0.09
            )
        }
    }

    /// One theme's colours.
    ///
    /// Card and hairline fills are a tint plus an opacity rather than a solid
    /// colour, because they sit over the canvas and have to stay translucent:
    /// in Daybreak the tint is the dark ink, everywhere else it is near-white.
    struct Palette {
        let accent: Color
        let accentHover: Color
        let accentPress: Color
        /// Text and glyphs drawn on top of the accent.
        let onAccent: Color
        let ready: Color
        let record: Color
        /// Glyphs drawn on top of `record`. White in every theme but Indigo,
        /// where `record` is yellow and white would land at 1.6:1.
        let onRecord: Color
        let warn: Color
        let canvas: Color
        let canvasDeep: Color
        let popover: Color
        let textPrimary: Color
        let cardTint: Color
        let cardOpacity: Double
        let hairline: Color
        let hairlineOpacity: Double
    }
}

/// The theme the app is drawing with right now.
///
/// The colour tokens are read from roughly three hundred places as plain static
/// properties such as `Color.mfAccent`, so the active theme lives here rather
/// than being threaded through the view tree. SwiftUI does not observe this, so
/// the windows that use it are rebuilt when the setting changes; see
/// `themeIdentity` in the settings store.
@MainActor
enum ThemeRuntime {
    static var current: AppTheme = .indigo
}

extension Color {
    /// Builds a colour from a hex literal, so the palettes above can be read
    /// against the design tokens without converting each channel by hand.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
