import AppKit
import SwiftUI

/// The design tokens from the MicMyDay UI handoff.
///
/// The prototype had to hard-code macOS system colours because it ran in a
/// browser; here they are declared once as light/dark pairs so every surface
/// is correct in both appearances. Only three colour roles exist — accent for
/// every interactive affordance, record for a live microphone, and status
/// (green/orange) — plus a text ramp and a set of neutral surfaces.
enum DS {
    // MARK: - Colour roles

    static let accent = Color.accentColor
    static let accentTint = dynamic(light: NSColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 0.12),
                                    dark: NSColor(srgbRed: 0.039, green: 0.518, blue: 1, alpha: 0.16))

    /// Reserved: appears only when the microphone is live, plus the error tint.
    static let record = dynamic(light: hex(0xFF3B30), dark: hex(0xFF453A))
    static let recordTint = dynamic(light: NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 0.12),
                                    dark: NSColor(srgbRed: 1, green: 0.271, blue: 0.227, alpha: 0.16))

    static let statusOK = dynamic(light: hex(0x34C759), dark: hex(0x30D158))
    /// Text-safe green — the fill green fails contrast on light backgrounds.
    static let statusOKText = dynamic(light: hex(0x248A3D), dark: hex(0x30D158))
    static let statusWarn = dynamic(light: hex(0xFF9500), dark: hex(0xFF9F0A))
    static let statusWarnText = dynamic(light: hex(0xB25000), dark: hex(0xFF9F0A))

    // MARK: - Text ramp

    static let textPrimary = dynamic(light: white(0, 0.85), dark: white(1, 0.92))
    static let textSecondary = dynamic(light: white(0, 0.5), dark: white(1, 0.55))
    static let textTertiary = dynamic(light: white(0, 0.26), dark: white(1, 0.28))
    static let textQuaternary = dynamic(light: white(0, 0.14), dark: white(1, 0.16))

    // MARK: - Surfaces

    static let surfaceWindow = dynamic(light: hex(0xECECEC), dark: hex(0x1E1E1E))
    static let surfaceControl = dynamic(light: hex(0xFFFFFF), dark: hex(0x2C2C2E))
    static let surfaceFormWindow = dynamic(light: hex(0xFFFFFF), dark: hex(0x242426))
    static let surfaceField = dynamic(light: hex(0xF2F2F7), dark: hex(0x1A1A1C))
    static let surfaceCard = dynamic(light: white(0, 0.035), dark: white(1, 0.055))
    static let surfaceFill = dynamic(light: white(0, 0.04), dark: white(1, 0.07))
    static let surfaceFillStrong = dynamic(light: white(0, 0.08), dark: white(1, 0.12))
    static let surfaceNoticeDanger = dynamic(light: NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 0.09),
                                             dark: NSColor(srgbRed: 1, green: 0.271, blue: 0.227, alpha: 0.14))
    static let surfaceNoticeWarn = dynamic(light: NSColor(srgbRed: 1, green: 0.584, blue: 0, alpha: 0.10),
                                           dark: NSColor(srgbRed: 1, green: 0.624, blue: 0.039, alpha: 0.14))

    static let borderHairline = dynamic(light: white(0, 0.10), dark: white(1, 0.135))
    static let borderStrong = dynamic(light: white(0, 0.18), dark: white(1, 0.24))

    /// The demo terminal in step 1 is a picture of another app, so it keeps its
    /// own colours in both appearances.
    static let terminalBackground = Color(nsColor: hex(0x0E1013))
    static let terminalPrompt = Color(nsColor: hex(0x30D158))

    // MARK: - Radii

    enum Radius {
        static let badge: CGFloat = 4
        static let field: CGFloat = 5
        static let control: CGFloat = 7
        static let card: CGFloat = 8
        static let window: CGFloat = 10
        static let callout: CGFloat = 12
    }

    // MARK: - Motion
    //
    // Exactly two loops exist in the whole app: the 1400 ms record pulse and
    // the step-1 demo. Everything else is a one-shot fade or move.

    static let move = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.32)
    static let fade = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.25)
    static let control = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.12)
    static let progress = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.35)

    // MARK: - Helpers

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func white(_ level: CGFloat, _ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: level, green: level, blue: level, alpha: alpha)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// Type ramp. Mono is not decoration — it marks what the machine owns:
/// ⌃⌥Space, `0:07 / 2:00`, `http://127.0.0.1:8000/v1`, model ids.
enum DSFont {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// SF Pro Display is selected automatically by macOS above 20pt; below that
    /// the difference is the tighter tracking applied at the call site.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight)
    }
}

extension View {
    /// Honours the system "Reduce motion" setting, which zeroes every
    /// animation in this design.
    func dsAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(ReducedMotionAnimation(animation: animation, value: value))
    }
}

private struct ReducedMotionAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}
