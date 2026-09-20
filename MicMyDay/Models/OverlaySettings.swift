import Foundation

/// Which shape the recording indicator takes.
///
/// The size settings below describe how much one indicator says; this is a
/// choice of what kind of thing it is. They are separate because the same
/// question, "how much do I want to see", has a different answer from "where
/// should it live and what should it look like".
enum OverlayStyle: String, CaseIterable, Identifiable, Codable {
    /// A small capsule, with the live preview in a panel of its own above it.
    /// What the app shipped with, and no longer the default.
    case pill
    /// One panel rather than two. The controls sit along the bottom of it and
    /// the transcript grows upward inside the same rounded container, so
    /// there is one object on screen instead of a pill and a bubble.
    case dock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pill: return "Pill"
        case .dock: return "Dock"
        }
    }

    var detail: String {
        switch self {
        case .pill: return "A compact indicator with a separate text preview."
        case .dock: return "Controls and text preview together in one panel."
        }
    }

    /// Whether the words appear inside the indicator itself. The pill keeps
    /// them in a second panel; the others have nowhere else to put them.
    var carriesPreviewInline: Bool { self != .pill }
}

/// How large the recording overlay is.
///
/// Each size *adds* to the one before it rather than restating it, which is
/// what the Settings copy says: just the microphone, then a meter and a timer,
/// then the armed profile and its shortcut.
enum OverlaySize: String, CaseIterable, Identifiable, Codable {
    case mini
    case compact
    case wide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mini: return "Mini"
        case .compact: return "Compact"
        case .wide: return "Wide"
        }
    }

    var detail: String {
        switch self {
        case .mini: return "Just the microphone."
        case .compact: return "Adds a level meter and elapsed time."
        case .wide: return "Adds the active rewrite profile and its shortcut."
        }
    }

    /// Mini is a circle: the phase badge *is* the overlay.
    var isMini: Bool { self == .mini }

    var height: CGFloat {
        switch self {
        case .mini: return 34
        case .compact: return 36
        case .wide: return 56
        }
    }

    var leadingPadding: CGFloat {
        switch self {
        case .mini: return 0
        case .compact: return 11
        case .wide: return 18
        }
    }

    var trailingPadding: CGFloat {
        switch self {
        case .mini: return 0
        case .compact: return 14
        case .wide: return 22
        }
    }

    var gap: CGFloat {
        switch self {
        case .mini: return 0
        case .compact: return 10
        case .wide: return 14
        }
    }

    var badgeSize: CGFloat {
        switch self {
        case .mini: return 34
        case .compact: return 22
        case .wide: return 30
        }
    }

    var badgeGlyph: CGFloat {
        switch self {
        case .mini: return 15
        case .compact: return 10
        case .wide: return 13
        }
    }

    var meterWidth: CGFloat { self == .wide ? 150 : 78 }
    var meterSegments: Int { self == .wide ? 30 : 18 }
    var meterHeight: CGFloat { self == .wide ? 26 : 16 }
    var elapsedSize: CGFloat { self == .wide ? 13 : 11 }
    var titleSize: CGFloat { self == .wide ? 14 : 12 }

    /// Mini shows no meter, no text and no time — the level is a ring.
    var showsMeter: Bool { self != .mini }
    var showsElapsed: Bool { self != .mini }
    var showsBusyText: Bool { self != .mini }
    /// Only Wide has room for the kicker and the profile's name.
    var showsKicker: Bool { self == .wide }
    var showsProfileName: Bool { self == .wide }
}

/// Where the overlay floats. Six spots: top or bottom, times left, centre, right.
enum OverlayPosition: String, CaseIterable, Identifiable, Codable {
    case tl, tc, tr, ml, mc, mr, bl, bc, br

    var id: String { rawValue }

    enum Vertical { case top, middle, bottom }

    var vertical: Vertical {
        switch self {
        case .tl, .tc, .tr: return .top
        case .ml, .mc, .mr: return .middle
        case .bl, .bc, .br: return .bottom
        }
    }

    var title: String {
        switch self {
        case .tl: return "Top left"
        case .tc: return "Top centre"
        case .tr: return "Top right"
        case .ml: return "Middle left"
        case .mc: return "Centre"
        case .mr: return "Middle right"
        case .bl: return "Bottom left"
        case .bc: return "Bottom centre"
        case .br: return "Bottom right"
        }
    }

    /// Clears the menu bar at the top and the Dock at the bottom. The middle
    /// row is centred on the screen, so nothing has to be cleared.
    var verticalInset: CGFloat {
        switch vertical {
        case .top: return 46
        case .middle: return 0
        case .bottom: return 64
        }
    }
    static let horizontalInset: CGFloat = 28

    enum Horizontal { case leading, centre, trailing }

    var horizontal: Horizontal {
        switch self {
        case .tl, .ml, .bl: return .leading
        case .tc, .mc, .bc: return .centre
        case .tr, .mr, .br: return .trailing
        }
    }
}
