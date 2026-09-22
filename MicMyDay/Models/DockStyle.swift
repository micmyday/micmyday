import SwiftUI

/// Which surface the Dock indicator wears.
///
/// The Dock's arrangement never changes: words above, controls along the
/// bottom, a hairline for the time remaining. What a style changes is the
/// material it is made of — the fill, the corner, the frame, the colour of the
/// meter and the stop button, how the profile chip is treated.
///
/// It sits beside the app's theme rather than inside it because the two
/// answer different questions. The theme decides what MicMyDay's own windows
/// look like; the overlay floats over somebody else's, at the moment they are
/// looking at their own work, and the surface that belongs there is not
/// necessarily the one that belongs in Settings. Anyone who wants the two to
/// agree keeps `theme`, which is the default and follows the palette.
enum DockStyle: String, CaseIterable, Identifiable, Codable {
    /// What shipped before the others existed: the app's own palette, so the
    /// overlay matches the panel and Settings. The default.
    case theme
    case aurora
    case obsidian
    case vibrancy
    case daylight
    case island
    case tintedGlass
    case outline
    case slate
    case aluminium
    case deepSea
    case charcoalMono
    case slateTray
    case graphiteLight
    case carbon
    case dusk
    case moss
    case iris

    var id: String { rawValue }

    var title: String {
        switch self {
        case .theme: return "Theme"
        case .aurora: return "Aurora"
        case .obsidian: return "Obsidian"
        case .vibrancy: return "Vibrancy"
        case .daylight: return "Daylight"
        case .island: return "Island"
        case .tintedGlass: return "Tinted glass"
        case .outline: return "Outline"
        case .slate: return "Slate"
        case .aluminium: return "Aluminium"
        case .deepSea: return "Deep sea"
        case .charcoalMono: return "Charcoal mono"
        case .slateTray: return "Slate tray"
        case .graphiteLight: return "Graphite light"
        case .carbon: return "Carbon"
        case .dusk: return "Dusk"
        case .moss: return "Moss"
        case .iris: return "Iris"
        }
    }

    /// One line, for the picker's accessibility label. The swatch says this
    /// to anyone who can see it; this says it to anyone who cannot.
    var detail: String {
        switch self {
        case .theme: return "Follows the app's theme."
        case .aurora: return "Dark glass ringed with moving light."
        case .obsidian: return "Near-black. Only the stop button is coloured."
        case .vibrancy: return "A macOS HUD: blurred grey, red stop."
        case .daylight: return "Light frosted glass, for bright rooms."
        case .island: return "Pure black with deep rounded corners."
        case .tintedGlass: return "Blurred indigo glass."
        case .outline: return "Barely there: a white outline over a faint blur."
        case .slate: return "Flat slate, square stop, green meter."
        case .aluminium: return "Brushed light grey with system red."
        case .deepSea: return "Deep navy, warm stop, coral chip."
        case .charcoalMono: return "Charcoal and monospaced throughout."
        case .slateTray: return "Slate with the controls on a raised tray."
        case .graphiteLight: return "Light graphite with the controls on a tray."
        case .carbon: return "Near-black inside a double hairline frame."
        case .dusk: return "Purple into rust, warm cream text."
        case .moss: return "Deep green with a lime stop."
        case .iris: return "Indigo into violet with a pink stop."
        }
    }

    /// Every value the Dock needs to draw itself in this style.
    ///
    /// `tint` is what the indicator's own state says the live colour is —
    /// record while listening, accent once the words are being worked on. Only
    /// `theme` uses it, because only `theme` is defined in terms of the
    /// palette; every other style states its colours outright and ignores it.
    @MainActor
    func surface(tint: Color) -> DockSurface {
        guard self != .theme else { return DockSurface.themed(tint: tint) }
        return DockSurface.catalogue[self] ?? DockSurface.themed(tint: tint)
    }
}

// MARK: - DockSurface

/// One style's drawing, as data.
///
/// Flat values rather than a protocol with eighteen conformances: the styles
/// differ only in what they are made of, never in how they are assembled, so a
/// new one is a row in the catalogue below and nothing else.
struct DockSurface {
    struct Stroke {
        let color: Color
        let width: CGFloat
    }

    struct Shadow {
        let color: Color
        let radius: CGFloat
        var y: CGFloat = 0
    }

    /// A lighter band behind the control row with a hairline above it, which
    /// is what separates the two tray styles from the flat ones.
    struct Tray {
        let fill: Color
        let hairline: Color
    }

    enum Fill {
        case solid(Color)
        case gradient(stops: [Gradient.Stop], start: UnitPoint, end: UnitPoint)
        /// A translucent tint over whatever is behind the window.
        case material(tint: Color, light: Bool)
    }

    enum Typeface {
        /// SF Pro Text 13.
        case system
        /// SF Mono 12, used by Charcoal mono for every string on the panel.
        case mono
    }

    /// Extra drawing a single style asks for. One case today; the point of the
    /// enum is that the shared code has exactly one place to check.
    enum Special {
        case none
        /// A 1.5pt ring around the perimeter: a conic gradient turning once
        /// every five seconds while listening, solid `mark` while rewriting.
        case auroraRing
    }

    var cornerRadius: CGFloat
    var body: Fill
    /// Hairlines drawn inside the edge, outermost first.
    var frame: [Stroke] = []
    /// A lit top edge, which is what keeps the three gradient styles from
    /// looking flat.
    var topHighlight: Stroke? = nil
    var shadow: Shadow
    /// A second, tighter drop under the first. Only the themed surface has
    /// one; it is what gives today's Dock its contact shadow.
    var secondShadow: Shadow? = nil

    var rowHeight: CGFloat = 44
    var paddingX: CGFloat = 14
    var tray: Tray? = nil

    var typeface: Typeface = .system
    /// The words while the engine may still revise them, and once it cannot.
    var tentative: Color
    var settled: Color

    var stopDiameter: CGFloat = 26
    var stopFill: Color
    var stopGlyph: Color
    /// Half the diameter or more is a circle; anything less is a rounded
    /// square of this radius.
    var stopRadius: CGFloat = 13
    var stopStroke: Stroke? = nil
    var stopGlow: Color? = nil

    var meter: Color
    /// The top of a vertical gradient down to `meter`, for the one style whose
    /// meter is two colours.
    var meterTop: Color? = nil
    /// Zero is a square bar; anything at or above half the bar's width is the
    /// capsule every other style uses.
    var meterBarRadius: CGFloat = 2

    var chipFill: Color
    var chipText: Color
    var chipStroke: Stroke? = nil
    var chipRadius: CGFloat = 999

    var elapsed: Color
    /// "Enhancing…" and the wand beside it.
    var kicker: Color
    var mark: Color
    /// The time-remaining line, and the colour it arrives in.
    var progress: Color
    var progressLead: Color? = nil

    var special: Special = .none
}

// MARK: - The themed surface

extension DockSurface {
    /// Today's Dock, expressed in the same terms as the rest.
    ///
    /// Every value here is the one the Dock already drew with before styles
    /// existed, so choosing `theme` is not a style so much as the absence of
    /// one: the palette decides, exactly as it did.
    @MainActor
    static func themed(tint: Color) -> DockSurface {
        let palette = ThemeRuntime.current.palette
        return DockSurface(
            cornerRadius: 16,
            body: .solid(palette.popover),
            frame: [Stroke(color: palette.cardTint.opacity(0.07), width: 1)],
            shadow: Shadow(color: .black.opacity(0.62), radius: 16, y: 10),
            secondShadow: Shadow(color: .black.opacity(0.4), radius: 4, y: 2),
            rowHeight: 44,
            paddingX: 14,
            tentative: palette.textPrimary.opacity(0.5),
            settled: palette.textPrimary.opacity(0.95),
            stopFill: tint,
            stopGlyph: palette.onRecord,
            meter: tint,
            chipFill: palette.accent.opacity(0.12),
            chipText: palette.accent,
            elapsed: palette.textPrimary.opacity(0.45),
            // Held back from the full tint: at full strength the kicker was
            // the brightest thing in the row, ahead of the stop button.
            kicker: tint.opacity(0.7),
            mark: tint,
            // The design's own periwinkle rather than whichever accent the
            // theme carries, so the line stays a cool measure under a warm
            // recording light instead of turning yellow on yellow in Sunrise.
            progress: Color(red: 0.647, green: 0.682, blue: 1)
        )
    }
}

// MARK: - Catalogue

extension DockSurface {
    private static func hex(_ value: UInt32, _ alpha: Double = 1) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: alpha
        )
    }

    private static let white = Color.white
    private static let clear = Color.clear
    /// The drop most of the dark styles share.
    private static let drop = Shadow(color: .black.opacity(0.5), radius: 26, y: 10)

    /// Aurora's ring, as the colours it turns through. First and last match so
    /// the sweep has no seam in it.
    static let auroraRing: [Color] = [
        hex(0xFFC61F), hex(0xA5AEFF), hex(0xFFC61F), hex(0xA5AEFF), hex(0xFFC61F),
    ]

    static let catalogue: [DockStyle: DockSurface] = [
        .aurora: DockSurface(
            cornerRadius: 22,
            body: .material(tint: hex(0x10111A, 0.94), light: false),
            shadow: Shadow(color: hex(0xFFC61F, 0.28), radius: 22),
            rowHeight: 48,
            paddingX: 16,
            tentative: white.opacity(0.5),
            settled: white.opacity(0.95),
            stopDiameter: 28,
            stopFill: hex(0xFFC61F, 0.12),
            stopGlyph: hex(0xFFC61F),
            stopRadius: 14,
            stopStroke: Stroke(color: hex(0xFFC61F, 0.7), width: 1),
            meter: hex(0xFFC61F),
            meterTop: hex(0xA5AEFF),
            chipFill: white.opacity(0.08),
            chipText: white,
            elapsed: white.opacity(0.5),
            kicker: white.opacity(0.8),
            mark: hex(0xA5AEFF),
            progress: hex(0xFFC61F),
            progressLead: hex(0xA5AEFF),
            special: .auroraRing
        ),

        .obsidian: DockSurface(
            cornerRadius: 20,
            body: .solid(hex(0x101116)),
            frame: [
                Stroke(color: .black.opacity(0.6), width: 0.5),
                Stroke(color: white.opacity(0.12), width: 0.5),
            ],
            shadow: drop,
            rowHeight: 46,
            paddingX: 16,
            tentative: white.opacity(0.46),
            settled: white.opacity(0.94),
            stopFill: hex(0xFFC61F),
            stopGlyph: hex(0x101116),
            meter: white.opacity(0.85),
            chipFill: clear,
            chipText: white.opacity(0.62),
            elapsed: white.opacity(0.4),
            kicker: white.opacity(0.7),
            mark: white.opacity(0.85),
            progress: white.opacity(0.5)
        ),

        .vibrancy: DockSurface(
            cornerRadius: 14,
            body: .material(tint: hex(0x26262A, 0.72), light: false),
            frame: [
                Stroke(color: .black.opacity(0.55), width: 0.5),
                Stroke(color: white.opacity(0.14), width: 0.5),
            ],
            shadow: Shadow(color: .black.opacity(0.35), radius: 30, y: 10),
            tentative: white.opacity(0.5),
            settled: white.opacity(0.92),
            stopFill: hex(0xFF453A),
            stopGlyph: white,
            meter: white.opacity(0.9),
            meterBarRadius: 1,
            chipFill: white.opacity(0.1),
            chipText: white.opacity(0.85),
            chipStroke: Stroke(color: white.opacity(0.12), width: 0.5),
            chipRadius: 5,
            elapsed: white.opacity(0.55),
            kicker: white.opacity(0.7),
            mark: hex(0x0A84FF),
            progress: hex(0x0A84FF)
        ),

        .daylight: DockSurface(
            cornerRadius: 18,
            body: .material(tint: white.opacity(0.86), light: true),
            frame: [Stroke(color: hex(0x141A24, 0.12), width: 0.5)],
            shadow: Shadow(color: .black.opacity(0.28), radius: 32, y: 12),
            tentative: hex(0x141A24, 0.45),
            settled: hex(0x141A24),
            stopFill: hex(0xD0342C),
            stopGlyph: white,
            meter: hex(0xD0342C),
            chipFill: hex(0x2E3765, 0.08),
            chipText: hex(0x2E3765),
            elapsed: hex(0x141A24, 0.5),
            kicker: hex(0x2E3765),
            mark: hex(0x2E3765),
            progress: hex(0x2E3765)
        ),

        .island: DockSurface(
            cornerRadius: 22,
            body: .solid(.black),
            shadow: Shadow(color: .black.opacity(0.45), radius: 32, y: 12),
            rowHeight: 46,
            paddingX: 16,
            tentative: white.opacity(0.45),
            settled: white,
            stopFill: hex(0xFF9F0A),
            stopGlyph: .black,
            meter: hex(0xFF9F0A),
            chipFill: white.opacity(0.1),
            chipText: white.opacity(0.8),
            elapsed: white.opacity(0.45),
            kicker: white.opacity(0.75),
            mark: hex(0xFF9F0A),
            progress: hex(0xFF9F0A)
        ),

        .tintedGlass: DockSurface(
            cornerRadius: 14,
            body: .material(tint: hex(0x3E447C, 0.62), light: false),
            frame: [
                Stroke(color: .black.opacity(0.4), width: 0.5),
                Stroke(color: white.opacity(0.18), width: 0.5),
            ],
            shadow: Shadow(color: .black.opacity(0.4), radius: 32, y: 12),
            tentative: white.opacity(0.55),
            settled: white,
            stopFill: hex(0xFFC61F),
            stopGlyph: hex(0x1E2233),
            meter: hex(0xFFC61F),
            chipFill: white.opacity(0.14),
            chipText: white,
            chipRadius: 6,
            elapsed: white.opacity(0.6),
            kicker: white.opacity(0.85),
            mark: white,
            progress: white.opacity(0.7)
        ),

        .outline: DockSurface(
            cornerRadius: 16,
            body: .material(tint: hex(0x0E1018, 0.35), light: false),
            frame: [Stroke(color: white.opacity(0.55), width: 1)],
            shadow: Shadow(color: .black.opacity(0.3), radius: 24, y: 8),
            tentative: white.opacity(0.55),
            settled: white,
            stopFill: clear,
            stopGlyph: hex(0xFFC61F),
            stopStroke: Stroke(color: hex(0xFFC61F), width: 1.5),
            meter: hex(0xFFC61F),
            chipFill: clear,
            chipText: white,
            chipStroke: Stroke(color: white.opacity(0.45), width: 1),
            elapsed: white.opacity(0.6),
            kicker: white,
            mark: white,
            progress: hex(0xFFC61F)
        ),

        .slate: DockSurface(
            cornerRadius: 10,
            body: .solid(hex(0x2B2E3A)),
            frame: [
                Stroke(color: .black.opacity(0.5), width: 0.5),
                Stroke(color: white.opacity(0.14), width: 0.5),
            ],
            shadow: Shadow(color: .black.opacity(0.4), radius: 26, y: 10),
            tentative: hex(0xEDEEF5, 0.5),
            settled: hex(0xEDEEF5),
            stopFill: hex(0xFF453A),
            stopGlyph: white,
            stopRadius: 6,
            meter: hex(0x45D6A0),
            meterBarRadius: 1,
            chipFill: white.opacity(0.08),
            chipText: hex(0xEDEEF5, 0.85),
            chipStroke: Stroke(color: white.opacity(0.14), width: 0.5),
            chipRadius: 5,
            elapsed: hex(0xEDEEF5, 0.5),
            kicker: hex(0xEDEEF5, 0.75),
            mark: hex(0x45D6A0),
            progress: hex(0x45D6A0)
        ),

        .aluminium: DockSurface(
            cornerRadius: 12,
            body: .gradient(
                stops: [.init(color: hex(0xF2F2F5), location: 0), .init(color: hex(0xDEDEE3), location: 1)],
                start: .top,
                end: .bottom
            ),
            frame: [Stroke(color: .black.opacity(0.25), width: 0.5)],
            shadow: Shadow(color: .black.opacity(0.3), radius: 26, y: 10),
            tentative: hex(0x1C1C1E, 0.45),
            settled: hex(0x1C1C1E),
            stopFill: hex(0xFF3B30),
            stopGlyph: white,
            meter: hex(0x1C1C1E),
            meterBarRadius: 1,
            chipFill: white.opacity(0.7),
            chipText: hex(0x1C1C1E),
            chipStroke: Stroke(color: .black.opacity(0.18), width: 0.5),
            chipRadius: 5,
            elapsed: hex(0x1C1C1E, 0.55),
            kicker: hex(0x007AFF),
            mark: hex(0x007AFF),
            progress: hex(0x007AFF)
        ),

        .deepSea: DockSurface(
            cornerRadius: 16,
            body: .solid(hex(0x0C1524)),
            frame: [Stroke(color: hex(0xEEF2F8, 0.12), width: 0.5)],
            shadow: Shadow(color: .black.opacity(0.55), radius: 30, y: 12),
            tentative: hex(0xEEF2F8, 0.45),
            settled: hex(0xEEF2F8),
            stopFill: hex(0xFFC61F),
            stopGlyph: hex(0x0C1524),
            meter: hex(0xFFC61F),
            chipFill: hex(0xFF4D6D, 0.16),
            chipText: hex(0xFF8DA3),
            elapsed: hex(0xEEF2F8, 0.5),
            kicker: hex(0xFFC61F),
            mark: hex(0xFFC61F),
            progress: hex(0xFFC61F)
        ),

        .charcoalMono: DockSurface(
            cornerRadius: 8,
            body: .solid(hex(0x1A1A1D)),
            frame: [Stroke(color: white.opacity(0.08), width: 1)],
            shadow: drop,
            rowHeight: 42,
            typeface: .mono,
            tentative: hex(0xEBEBF0, 0.42),
            settled: hex(0xEBEBF0),
            stopFill: hex(0xFFC61F),
            stopGlyph: hex(0x1A1A1D),
            stopRadius: 4,
            meter: hex(0xEBEBF0, 0.75),
            meterBarRadius: 0,
            chipFill: white.opacity(0.06),
            chipText: hex(0xEBEBF0, 0.8),
            chipStroke: Stroke(color: white.opacity(0.12), width: 1),
            chipRadius: 4,
            elapsed: hex(0xEBEBF0, 0.5),
            kicker: hex(0xEBEBF0, 0.7),
            mark: hex(0xEBEBF0, 0.85),
            progress: hex(0xEBEBF0, 0.6)
        ),

        .slateTray: DockSurface(
            cornerRadius: 6,
            body: .solid(hex(0x262933)),
            frame: [
                Stroke(color: .black.opacity(0.5), width: 0.5),
                Stroke(color: white.opacity(0.14), width: 0.5),
            ],
            shadow: Shadow(color: .black.opacity(0.45), radius: 26, y: 10),
            tray: Tray(fill: hex(0x2F3340), hairline: white.opacity(0.1)),
            tentative: hex(0xEDEEF5, 0.5),
            settled: hex(0xEDEEF5),
            stopFill: hex(0xFFC61F),
            stopGlyph: hex(0x1E2233),
            stopRadius: 5,
            meter: hex(0xFFC61F),
            meterBarRadius: 1,
            chipFill: white.opacity(0.08),
            chipText: hex(0xEDEEF5, 0.85),
            chipStroke: Stroke(color: white.opacity(0.14), width: 0.5),
            chipRadius: 4,
            elapsed: hex(0xEDEEF5, 0.5),
            kicker: hex(0xEDEEF5, 0.75),
            mark: hex(0xA5AEFF),
            progress: hex(0xA5AEFF)
        ),

        .graphiteLight: DockSurface(
            cornerRadius: 6,
            body: .solid(hex(0xE9E9EE)),
            frame: [
                Stroke(color: .black.opacity(0.22), width: 0.5),
                Stroke(color: white.opacity(0.9), width: 0.5),
            ],
            shadow: Shadow(color: .black.opacity(0.3), radius: 26, y: 10),
            tray: Tray(fill: hex(0xF4F4F7), hairline: .black.opacity(0.08)),
            tentative: hex(0x1C1C1E, 0.45),
            settled: hex(0x1C1C1E),
            stopFill: hex(0xFF3B30),
            stopGlyph: white,
            stopRadius: 5,
            meter: hex(0x1C1C1E),
            meterBarRadius: 1,
            chipFill: white.opacity(0.85),
            chipText: hex(0x1C1C1E),
            chipStroke: Stroke(color: .black.opacity(0.16), width: 0.5),
            chipRadius: 4,
            elapsed: hex(0x1C1C1E, 0.55),
            kicker: hex(0x007AFF),
            mark: hex(0x007AFF),
            progress: hex(0x007AFF)
        ),

        // A 1pt hairline at the edge, 2pt of body, then a 0.5pt inner hairline.
        .carbon: DockSurface(
            cornerRadius: 3,
            body: .solid(hex(0x15161B)),
            frame: [
                Stroke(color: white.opacity(0.1), width: 1),
                Stroke(color: hex(0x15161B), width: 2),
                Stroke(color: white.opacity(0.07), width: 0.5),
            ],
            shadow: Shadow(color: .black.opacity(0.55), radius: 26, y: 10),
            paddingX: 16,
            tentative: hex(0xEBEBF0, 0.45),
            settled: hex(0xEBEBF0),
            stopFill: hex(0xFFC61F),
            stopGlyph: hex(0x15161B),
            stopRadius: 3,
            meter: hex(0xFFC61F),
            meterBarRadius: 0,
            chipFill: clear,
            chipText: hex(0xEBEBF0, 0.85),
            chipStroke: Stroke(color: white.opacity(0.16), width: 1),
            chipRadius: 3,
            elapsed: hex(0xEBEBF0, 0.5),
            kicker: hex(0xEBEBF0, 0.75),
            mark: hex(0xA5AEFF),
            progress: hex(0xFFC61F)
        ),

        .dusk: DockSurface(
            cornerRadius: 9,
            body: .gradient(
                stops: [
                    .init(color: hex(0x2B1A3D), location: 0),
                    .init(color: hex(0x4A2050), location: 0.48),
                    .init(color: hex(0x8A3A2E), location: 1),
                ],
                start: .topLeading,
                end: .bottomTrailing
            ),
            frame: [Stroke(color: white.opacity(0.1), width: 0.5)],
            topHighlight: Stroke(color: white.opacity(0.18), width: 1),
            shadow: drop,
            tentative: hex(0xFBEFE3, 0.5),
            settled: hex(0xFBEFE3),
            stopFill: white,
            stopGlyph: hex(0x4A2050),
            stopRadius: 7,
            meter: hex(0xFFB86B),
            meterBarRadius: 1.5,
            chipFill: white.opacity(0.14),
            chipText: hex(0xFBEFE3),
            chipRadius: 6,
            elapsed: hex(0xFBEFE3, 0.6),
            kicker: hex(0xFFD9A8),
            mark: hex(0xFFD9A8),
            progress: hex(0xFFB86B)
        ),

        .moss: DockSurface(
            cornerRadius: 10,
            body: .gradient(
                stops: [.init(color: hex(0x11302A), location: 0), .init(color: hex(0x0A1E19), location: 1)],
                start: .top,
                end: .bottom
            ),
            frame: [Stroke(color: hex(0x45D6A0, 0.2), width: 0.5)],
            topHighlight: Stroke(color: hex(0xC8F26B, 0.25), width: 0.5),
            shadow: drop,
            tentative: hex(0xE6F4EE, 0.45),
            settled: hex(0xE6F4EE),
            stopFill: hex(0xC8F26B),
            stopGlyph: hex(0x0A1E19),
            stopRadius: 7,
            meter: hex(0x45D6A0),
            meterBarRadius: 1.5,
            chipFill: hex(0x45D6A0, 0.14),
            chipText: hex(0x8FE9C4),
            chipRadius: 6,
            elapsed: hex(0xE6F4EE, 0.5),
            kicker: hex(0xC8F26B),
            mark: hex(0xC8F26B),
            progress: hex(0x45D6A0)
        ),

        .iris: DockSurface(
            cornerRadius: 8,
            body: .gradient(
                stops: [
                    .init(color: hex(0x1B2145), location: 0),
                    .init(color: hex(0x2E2560), location: 0.55),
                    .init(color: hex(0x3E2A72), location: 1),
                ],
                start: .topLeading,
                end: .bottomTrailing
            ),
            frame: [Stroke(color: hex(0xC6BAFF, 0.18), width: 0.5)],
            topHighlight: Stroke(color: white.opacity(0.16), width: 0.5),
            shadow: drop,
            tentative: hex(0xEEF0FF, 0.48),
            settled: hex(0xEEF0FF),
            stopFill: hex(0xFF5FA2),
            stopGlyph: hex(0x1B2145),
            stopRadius: 6,
            stopGlow: hex(0xFF5FA2, 0.45),
            meter: hex(0xFF5FA2),
            meterBarRadius: 1.5,
            chipFill: hex(0xC6BAFF, 0.16),
            chipText: hex(0xC6BAFF),
            chipRadius: 6,
            elapsed: hex(0xEEF0FF, 0.55),
            kicker: hex(0xC6BAFF),
            mark: hex(0xC6BAFF),
            progress: hex(0xFF5FA2)
        ),
    ]
}
