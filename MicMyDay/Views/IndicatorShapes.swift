import AppKit
import SwiftUI

/// Everything an indicator needs to draw itself, whichever shape it is.
///
/// One value rather than a dozen parameters repeated across four views: the
/// shapes differ in what they show and where, not in what they know, and a
/// shared shape for the inputs is what lets a new one be added without
/// touching the code that assembles them.
@MainActor
struct IndicatorState {
    let content: OverlayContent
    let level: Double
    let elapsed: String
    let profileName: String?
    let profileSymbol: String
    /// The words so far, settled or not, already chosen by the caller.
    let words: String
    /// Which dictation this is. Shapes that accumulate something across a
    /// take, such as the Dock's height, use it to know when to start over;
    /// watching the words empty instead is a guess, and a wrong one, because
    /// the last take's words are deliberately held on screen into the next
    /// one's opening moments.
    var take: Int = 0
    /// Whether the indicator hangs from the top of the screen, in which case
    /// it has to grow downward to stay put.
    var growsDownward: Bool = false
    /// A word the indicator has to say for a moment, such as the switch to
    /// hands-free. Nil the rest of the time, which is almost always.
    var note: String? = nil
    let firm: Bool
    let showsWords: Bool
    /// How far through the maximum recording length, 0 to 1, or nil when
    /// there is no limit set.
    var progress: Double? = nil
    /// How much the shape shows, for the shapes that vary with it.
    var size: OverlaySize = .wide
    /// Which surface the Dock wears. The pill has one look and ignores it.
    var dockStyle: DockStyle = .theme
    let onStop: (() -> Void)?
    /// The armed profile is the one thing on the indicator you cannot work
    /// out from anything else on screen, and the one that changes what lands
    /// in your app, so every shape lets you change it mid-take rather than
    /// only reporting it.
    var profiles: [OverlayProfileItem] = []
    var onSelectProfile: ((String) -> Void)? = nil
    /// Moves the indicator while a take is running; nil when it cannot be
    /// moved, which is any moment it is not accepting clicks anyway.
    var onDrag: ((CGSize) -> Void)? = nil

    var isRecording: Bool { content == .recording }

    /// Record while listening, accent once the words are being worked on.
    /// The same two colours the pill uses, so switching shape never changes
    /// what a colour means.
    var tint: Color {
        switch content {
        case .recording, .starting: return .mfRecord
        case .busy, .profileToast: return .mfAccent
        }
    }

    /// What stands where the stop button was once there is nothing to stop:
    /// the wand while a rewrite runs, a tick once the words have landed.
    var markSymbol: String {
        switch content {
        case let .busy(phase): return phase == .enhancing ? "wand.and.stars" : "checkmark"
        default: return "mic.fill"
        }
    }

    /// Sentence case, like every other piece of text in the app.
    ///
    /// This was set as a spaced monospaced label and uppercased on top, which
    /// is a treatment for a heading rather than for a word that appears for
    /// half a second beside a meter and a clock. Ordinary type in ordinary
    /// case simply reads, which is all this has to do.
    var kicker: String {
        switch content {
        case .starting: return "Starting"
        case .recording: return "Listening"
        case let .busy(phase): return phase.title
        case .profileToast: return "Profile"
        }
    }
}

/// The amplitude trace the designs specify, and not a generic level bar.
///
/// Thirteen bars, symmetrical about the middle: each is scaled down by its
/// distance from the centre, so the trace reads as a cluster rather than a
/// strip, and each carries its own jitter, so it looks like sound arriving
/// rather than one block rising and falling together. Heights run 4pt to
/// 18pt, and the whole thing dims to a fifth when the microphone is closed.
struct IndicatorMeter: View {
    let level: Double
    let tint: Color
    /// The top of a vertical gradient running down to `tint`, for the one
    /// style whose meter is two colours. Nil is the flat fill everywhere else.
    var topTint: Color? = nil
    var listening: Bool = true
    var bars: Int = 13
    var barWidth: CGFloat = 2.5
    /// Nil is the capsule the Dock has always drawn; a style that wants square
    /// or barely-rounded bars says so.
    var barRadius: CGFloat? = nil
    /// Redrawn on every level change, so each frame gets fresh jitter. Held
    /// in state rather than computed inline because a view body must not
    /// depend on a random number: SwiftUI may run it more than once for the
    /// same value, and the bars would flicker between two shapes.
    @State private var heights: [Double] = []

    var body: some View {
        // Grown from the middle outward rather than up from a baseline.
        // The design anchors these at the bottom, which is right in a strip
        // where the meter sits on an edge; here it is centred in a 44pt row,
        // so bars rising from a fixed floor made the whole cluster look as
        // though it jumped upward whenever somebody spoke. Expanding both
        // ways keeps its middle still and only its size changes.
        HStack(alignment: .center, spacing: 2) {
            ForEach(0 ..< bars, id: \.self) { index in
                let value = index < heights.count ? heights[index] : 0.12
                RoundedRectangle(cornerRadius: barRadius ?? barWidth / 2, style: .continuous)
                    .fill(fill)
                    .frame(width: barWidth, height: Self.floorHeight + value * Self.reach)
                    .opacity(listening ? 0.45 + value * 0.55 : 0.2)
            }
        }
        .frame(height: Self.floorHeight + Self.reach)
        .animation(.linear(duration: 0.1), value: heights)
        .onAppear { heights = Self.sample(level: level, bars: bars) }
        .onChange(of: level) { _, new in heights = Self.sample(level: new, bars: bars) }
    }

    /// Flat unless the style asks for two colours, in which case the bars are
    /// one gradient cut into thirteen pieces rather than thirteen gradients:
    /// each bar is a different height, so filling them separately would put
    /// the colour change at a different place in every one.
    private var fill: LinearGradient {
        LinearGradient(
            colors: topTint.map { [$0, tint] } ?? [tint, tint],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// The shortest a bar ever is, so a closed microphone still shows a trace
    /// rather than nothing.
    private static let floorHeight: CGFloat = 4
    /// How far the middle can rise above that floor.
    ///
    /// Twenty-two in total, against the stop button's twenty-six. The meter
    /// reads as the loudest thing in the row when it peaks, and it should,
    /// but it must stay under the one control in the row that is a control:
    /// a trace taller than the button makes the button look like part of it.
    private static let reach: CGFloat = 18

    /// How much of the level reaches a bar, by its distance from the middle.
    ///
    /// Curved rather than straight. A straight taper left the outermost bars
    /// at nearly half the middle's height, which reads as a strip with a bump
    /// in it; falling away faster gathers the movement into the centre and
    /// leaves the ends as a quiet fringe. They never reach zero, because a
    /// trace that ends in nothing looks clipped rather than tapered.
    static func taper(distance: Double) -> Double {
        0.15 + 0.85 * pow(1 - distance, 1.6)
    }

    private static func sample(level: Double, bars: Int) -> [Double] {
        let middle = Double(bars - 1) / 2
        return (0 ..< bars).map { index in
            let distance = abs(Double(index) - middle) / middle
            let jitter = 0.6 + Double.random(in: 0 ... 0.6)
            return max(0.12, min(1, level * taper(distance: distance) * jitter))
        }
    }
}

/// The stop button every shape carries, and the most prominent control in all
/// of them: ending a dictation must never mean finding the menu bar.
struct IndicatorStopButton: View {
    let tint: Color
    /// The square inside it. Usually the colour that reads on `tint`; in the
    /// outlined styles the fill is clear and this is the only colour there is.
    var glyph: Color = .white
    let diameter: CGFloat
    /// Half the diameter or more is a circle; less is a rounded square.
    var cornerRadius: CGFloat? = nil
    var stroke: DockSurface.Stroke? = nil
    var glow: Color? = nil
    let onStop: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: min(cornerRadius ?? diameter / 2, diameter / 2), style: .continuous)
    }

    var body: some View {
        Button(action: onStop) {
            ZStack {
                shape.fill(tint)
                if let stroke {
                    shape.strokeBorder(stroke.color, lineWidth: stroke.width)
                }
                Image(systemName: "stop.fill")
                    .font(.system(size: diameter * 0.35, weight: .bold))
                    .foregroundStyle(glyph)
            }
            .frame(width: diameter, height: diameter)
            .shadow(color: glow ?? .clear, radius: glow == nil ? 0 : 10)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Stop and transcribe")
        .accessibilityLabel("Stop and transcribe")
    }
}

/// Drags the indicator out of the way, for this dictation only.
///
/// Attached behind the content rather than over it, so a press that lands on
/// the stop button or the profile menu still belongs to them: only the parts
/// of the container that are not a control pick this up. The move lasts as
/// long as the take, because being in the way is a fact about this paragraph
/// in this window, not a preference worth keeping.
struct IndicatorDragCatcher: ViewModifier {
    /// Called with how far the pointer has moved across the screen since the
    /// last call, in AppKit's coordinates, where y grows upward.
    let onDrag: ((CGSize) -> Void)?

    /// Where the pointer was when we last moved the window.
    ///
    /// Measured against the screen rather than against the view, because the
    /// view is inside the window being moved. A gesture's own translation is
    /// relative to that window, so every move changed the thing the next
    /// measurement was made from and the panel jumped around the pointer
    /// instead of following it.
    @State private var lastMouse: CGPoint?

    func body(content: Content) -> some View {
        if let onDrag {
            // On the container, not behind it: behind meant behind the panel's
            // own opaque background, which swallowed every press. A plain
            // gesture rather than a high-priority one, so the stop button and
            // the profile menu keep the presses that land on them.
            content
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { _ in
                            let now = NSEvent.mouseLocation
                            defer { lastMouse = now }
                            guard let last = lastMouse else { return }
                            onDrag(CGSize(width: now.x - last.x, height: now.y - last.y))
                        }
                        .onEnded { _ in lastMouse = nil }
                )
        } else {
            content
        }
    }
}

extension View {
    /// See `IndicatorDragCatcher`.
    func indicatorDraggable(_ onDrag: ((CGSize) -> Void)?) -> some View {
        modifier(IndicatorDragCatcher(onDrag: onDrag))
    }
}

/// The armed profile, as a menu when there is something to choose.
///
/// The same list and the same action the pill uses, so switching shape never
/// costs you a control: the profile decides what happens to the words after
/// you stop, and finding that out too late means dictating the passage again.
struct IndicatorProfile: View {
    let state: IndicatorState
    /// The chip's treatment, which is one of the things a Dock style changes:
    /// a tinted pill in most, an outline in two, a small rounded rectangle in
    /// the HUD and tray styles.
    let surface: DockSurface
    var compact: Bool = false

    var body: some View {
        if let name = state.profileName {
            if let onSelectProfile = state.onSelectProfile, !state.profiles.isEmpty {
                Menu {
                    ForEach(state.profiles) { profile in
                        Toggle(isOn: Binding(
                            get: { profile.isActive },
                            set: { _ in onSelectProfile(profile.id) }
                        )) {
                            Label(
                                profile.shortcut.map { "\(profile.name)   \($0)" } ?? profile.name,
                                systemImage: profile.symbol
                            )
                        }
                    }
                } label: {
                    face(name)
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                face(name)
            }
        }
    }

    /// The chip is about twenty points tall, so a radius asking for a pill is
    /// clamped to half of that rather than left at the design's 999.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: min(surface.chipRadius, 10), style: .continuous)
    }

    private func face(_ name: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: state.profileSymbol).font(.system(size: 9))
            if !compact {
                Text(name)
                    .font(surface.typeface == .mono
                        ? .system(size: 10, weight: .medium, design: .monospaced)
                        : .system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            // A quiet chevron, so it reads as something you can open rather
            // than a label that happens to be next to the time.
            if state.onSelectProfile != nil, !state.profiles.isEmpty {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .opacity(0.55)
            }
        }
        .foregroundStyle(surface.chipText)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(surface.chipFill, in: shape)
        .overlay {
            if let stroke = surface.chipStroke {
                shape.strokeBorder(stroke.color, lineWidth: stroke.width)
            }
        }
        .contentShape(shape)
    }
}

// MARK: - Dock

/// One panel instead of two: the controls sit along the bottom and the words
/// grow upward inside the same rounded container.
///
/// The pill's arrangement puts the transcript in a second panel above a
/// capsule, so there are two objects on screen that move independently. Here
/// there is one object that changes height, which is a quieter thing to have
/// over your work.
struct DockIndicator: View {
    let state: IndicatorState

    /// What the words come to when nothing constrains them, which is the only
    /// thing the panel needs to know to tell "it fits" from "it does not".
    /// Not a high-water mark: it may fall as well as rise, because a rewrite
    /// can replace a long draft with a short result.
    @State private var naturalWordsHeight: CGFloat = 0

    /// What the chosen style is made of. Every colour, radius and inset below
    /// comes from here rather than from the palette, which is the whole of the
    /// difference between one style and the next.
    private var surface: DockSurface { state.dockStyle.surface(tint: state.tint) }

    /// The panel's two forms, and the whole of what distinguishes them.
    ///
    /// Closed, it is the indicator somebody with the preview turned off sees,
    /// exactly — same width, same height, same everything. Turning the preview
    /// on changes nothing at all until there is something to preview, and the
    /// first word is what opens it.
    private var wordsOpen: Bool { state.showsWords && !state.words.isEmpty }

    /// A compact baseline for the controls, with extra reading room once the
    /// words are there to need it. Controls keep their natural width regardless.
    private var width: CGFloat { wordsOpen ? 365 : 330 }

    private var height: CGFloat? {
        guard wordsOpen else { return surface.rowHeight }
        return surface.rowHeight + wordsHeight + trayGap
    }

    /// Nothing, or all four lines. There is no size in between.
    ///
    /// The panel used to gain a line at a time as the text filled it, keeping
    /// a high-water mark so it could never shrink mid-take. That removed the
    /// pumping an earlier version had, but it still meant the thing floating
    /// over your work changed size four times while you were talking to it.
    ///
    /// Two sizes and one move between them is quieter than four. It costs a
    /// panel larger than a one-line dictation strictly needs, which is the
    /// trade: a shape that settles once is worth more here than a tight one,
    /// because the panel sits in your peripheral vision and it is movement the
    /// eye catches there, not size.
    private var wordsHeight: CGFloat { wordsOpen ? fullWordsHeight : 0 }

    /// Whether the words have outgrown the four rows, which decides both which
    /// edge they are anchored to and which edge, if any, is faded.
    private var overflowing: Bool { naturalWordsHeight > wordsHeight }

    /// The tray styles put the control row on a raised band, and text sitting
    /// straight on the edge of it reads as though it has fallen in.
    private var trayGap: CGFloat { surface.tray == nil ? 0 : 10 }

    /// The words' own font, at the four point line spacing set below.
    private var wordsFont: Font {
        switch surface.typeface {
        case .system: return .system(size: 13)
        case .mono: return .system(size: 12, design: .monospaced)
        }
    }

    private var lineHeight: CGFloat { surface.typeface == .mono ? 18.4 : 19.6 }

    private static let maximumLines: CGFloat = 4
    private static let wordsPadding: CGFloat = 12
    /// The full word area, which is what four lines come to. The mask below is
    /// expressed as a fraction of it, and the box the panel grows inside is
    /// measured from it.
    private var fullWordsHeight: CGFloat { Self.wordsPadding + Self.maximumLines * lineHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Closed to nothing until the first word, then open at its full
            // four lines. The height carries the animation; the text inside is
            // the same view throughout, so nothing is torn down and rebuilt at
            // the moment the panel opens.
            if state.showsWords {
                Text(state.words)
                    .font(wordsFont)
                    .lineSpacing(4)
                    .foregroundStyle(state.firm ? surface.settled : surface.tentative)
                    // Its full natural height, however many lines that is.
                    // Without this the text is fitted to the box instead and
                    // ends in an ellipsis, which puts the truncation at the
                    // end: the words being spoken right now are the ones cut
                    // off, and the panel shows the opening of a sentence
                    // finished long ago.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, surface.paddingX)
                    // The slack the four rows are measured with, spent above
                    // the text rather than left below it. Top-aligned without
                    // this the first line sits hard against the panel's edge,
                    // which reads as the words having been pushed out of it.
                    // Inside the measurement on purpose: the height compared
                    // against the box has to be the height the box will hold.
                    .padding(.top, Self.wordsPadding)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: WordsHeightKey.self,
                                value: geometry.size.height
                            )
                        }
                    )
                    // Top until the words outgrow the four rows, bottom after.
                    //
                    // Both anchors are the same thing said twice: keep reading
                    // where reading starts, and never let the line being
                    // spoken right now be the one that is cut off. While the
                    // text fits, those agree and the top is where it sits.
                    // Once it does not, holding the top would freeze the panel
                    // on the opening of a sentence finished long ago.
                    .frame(
                        height: wordsHeight,
                        alignment: overflowing ? .bottomLeading : .topLeading
                    )
                    .clipped()
                    // A line cut in half by the top edge reads as damage.
                    // Fading the last few points turns it into text passing
                    // out of view, which is what it is.
                    //
                    // Only while there is something passing out of view. Text
                    // that fits is anchored at the top, and a fade there would
                    // dim the first line of a transcript nothing is scrolling.
                    .mask(
                        LinearGradient(
                            stops: overflowing
                                ? [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black, location: 16 / fullWordsHeight),
                                    .init(color: .black, location: 1),
                                ]
                                : [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: 1),
                                ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .padding(.bottom, wordsOpen ? trayGap : 0)
            }
            controls
        }
        // A floor, not a fixed width, for the form without words. A profile
        // the user named themselves, an hour-long take
        // whose clock reads 1:02:33 rather than 0:07, another language, the
        // Bold Text accessibility setting: any of those need more room than
        // was measured, and a fixed width answers by truncating. The panel
        // grows instead. With words it stays fixed, because there the width
        // decides where the text wraps.
        .frame(
            minWidth: width,
            maxWidth: wordsOpen ? width : nil,
            minHeight: height,
            maxHeight: height,
            alignment: .bottom
        )
        .background { panelFill.clipShape(shape) }
        .overlay(alignment: .bottomLeading) { elapsedLine }
        .clipShape(shape)
        .overlay { topHighlight }
        .overlay { frameStrokes }
        .overlay { auroraRing }
        .indicatorDraggable(state.onDrag)
        // Inside the window's 34pt transparent margin. The design's 24pt
        // radius at a 20pt drop reaches 44pt below the panel, past the edge
        // of the window drawing it, and the part that did not fit was sliced
        // off square.
        .shadow(color: surface.shadow.color, radius: surface.shadow.radius, y: surface.shadow.y)
        .shadow(
            color: surface.secondShadow?.color ?? .clear,
            radius: surface.secondShadow?.radius ?? 0,
            y: surface.secondShadow?.y ?? 0
        )
        .animation(.easeOut(duration: 0.4), value: width)
        .animation(.easeOut(duration: 0.4), value: height)
        .animation(.easeOut(duration: 0.25), value: state.dockStyle)
        .onPreferenceChange(WordsHeightKey.self) { naturalWordsHeight = $0 }
        // Held inside a box the size of the panel's largest form, so the
        // window around it never changes size while the panel grows.
        //
        // This is what makes the growth smooth. The overlay window is resized
        // and repositioned imperatively on every refresh, and a refresh
        // happens about ten times a second while recording. Each one snapped
        // the window straight to the panel's final size and then placed it,
        // while SwiftUI was still animating the panel inside: the two
        // disagreed about where the panel was for the length of every
        // animation. With the box constant there is nothing left for the
        // window to do, and the only thing moving is the panel itself.
        .frame(
            height: state.showsWords ? surface.rowHeight + fullWordsHeight + trayGap : nil,
            alignment: state.growsDownward ? .top : .bottom
        )
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: surface.cornerRadius, style: .continuous)
    }

    /// The panel's own material: a flat colour, a gradient, or a translucent
    /// tint over whatever the window is floating above.
    @ViewBuilder
    private var panelFill: some View {
        switch surface.body {
        case let .solid(color):
            color
        case let .gradient(stops, start, end):
            LinearGradient(gradient: Gradient(stops: stops), startPoint: start, endPoint: end)
        case let .material(tint, light):
            DockBlur(light: light, cornerRadius: surface.cornerRadius).overlay(tint)
        }
    }

    /// Hairlines drawn inside the edge, outermost first, each inset past the
    /// ones before it. Carbon's frame is three of them: a hairline, two points
    /// of body, then a second hairline.
    @ViewBuilder
    private var frameStrokes: some View {
        let widths = surface.frame.map(\.width)
        ForEach(Array(surface.frame.enumerated()), id: \.offset) { index, stroke in
            let inset = widths.prefix(index).reduce(0, +)
            RoundedRectangle(cornerRadius: max(0, surface.cornerRadius - inset), style: .continuous)
                .strokeBorder(stroke.color, lineWidth: stroke.width)
                .padding(inset)
        }
    }

    /// A lit top edge, which is what keeps the gradient styles from reading as
    /// flat rectangles. Inset past the corners, where a straight line drawn
    /// over a curve would show as two bright stubs.
    @ViewBuilder
    private var topHighlight: some View {
        if let highlight = surface.topHighlight {
            Rectangle()
                .fill(highlight.color)
                .frame(height: highlight.width)
                .padding(.horizontal, surface.cornerRadius)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var auroraRing: some View {
        if case .auroraRing = surface.special {
            DockAuroraRing(
                cornerRadius: surface.cornerRadius,
                listening: state.isRecording,
                resting: surface.mark
            )
        }
    }

    /// Where the elapsed line begins, measured from the panel's left edge.
    private static let elapsedStart: CGFloat = 15

    /// How much of the maximum recording length has gone, as a hairline
    /// along the bottom edge.
    ///
    /// Two points tall and lit only at its own end, so at a glance there is
    /// nothing there and it becomes visible only as it fills. A number would
    /// have to be read and would sit in the row competing with the clock;
    /// this is meant to be noticed rather than consulted.
    @ViewBuilder
    private var elapsedLine: some View {
        if let progress = state.progress {
            GeometryReader { geometry in
                // From the container's own left edge, and clipped by the
                // panel's corner, which is what the design does and what
                // gives it its entrance: down in the corner the curve trims
                // the bar to nothing, so it emerges as a sliver, widens as it
                // passes the curve, and only then becomes the full line.
                // Inset past the radius instead and it arrives abruptly,
                // already at full width, somewhere under the stop button.
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 1,
                    topTrailingRadius: 1,
                    style: .continuous
                )
                .fill(
                    LinearGradient(
                        colors: [
                            (surface.progressLead ?? surface.progress).opacity(0.35),
                            surface.progress,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                // Symmetrical: it ends the same distance from the right
                // corner as it starts from the left, so a full take fills the
                // straight part of the edge exactly rather than running into
                // the curve at one end.
                .frame(width: (geometry.size.width - Self.elapsedStart * 2) * progress, height: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                // Started a little in from the edge rather than at it: the
                // curve still trims the first of it, so the entrance is kept,
                // but it begins nearer where the eye expects a measure to
                // begin instead of in the very corner.
                .padding(.leading, Self.elapsedStart)
                .animation(.linear(duration: 0.95), value: progress)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 11) {
            if let onStop = state.onStop {
                IndicatorStopButton(
                    tint: surface.stopFill,
                    glyph: surface.stopGlyph,
                    diameter: surface.stopDiameter,
                    cornerRadius: surface.stopRadius,
                    stroke: surface.stopStroke,
                    glow: surface.stopGlow,
                    onStop: onStop
                )
            } else {
                Image(systemName: state.markSymbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(surface.mark)
                    .frame(width: surface.stopDiameter)
            }

            if let note = state.note {
                // In the slot the phase name uses, not over the whole panel.
                // The Dock is large enough that covering it to say two words
                // would read as the app interrupting itself; the row already
                // carries words when it has any to say.
                Text(note)
                    .font(DSFont.ui(12, .semibold))
                    .foregroundStyle(surface.mark)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            } else if state.isRecording {
                IndicatorMeter(
                    level: state.level,
                    tint: surface.meter,
                    topTint: surface.meterTop,
                    barRadius: surface.meterBarRadius
                )
            } else {
                Text(state.kicker)
                    .font(DSFont.ui(12, .medium))
                    // Held back from the full mark colour. At full strength
                    // the word was the brightest thing in the row, which put
                    // it ahead of the stop button and the clock; it is a
                    // caption for the state, not the state itself.
                    .foregroundStyle(surface.kicker)
                    // Never broken across lines: the row is one line tall, so
                    // a second one is drawn outside it.
                    .lineLimit(1)
                    .fixedSize()
            }

            Spacer(minLength: 6)

            IndicatorProfile(state: state, surface: surface)

            Text(state.elapsed)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(surface.elapsed)
                // Its natural width, always. Squeezed by a long phase label
                // beside the armed profile, the clock collapsed to an
                // ellipsis, which is the one thing it can say that is worse
                // than saying nothing.
                .fixedSize()
        }
        .padding(.horizontal, surface.paddingX)
        .frame(height: surface.rowHeight)
        .background(alignment: .top) { trayBacking }
        .animation(.easeOut(duration: 0.25), value: state.note)
    }

    /// The raised band the two tray styles put the controls on, with the
    /// hairline that separates it from the words above.
    @ViewBuilder
    private var trayBacking: some View {
        if let tray = surface.tray {
            ZStack(alignment: .top) {
                tray.fill
                Rectangle().fill(tray.hairline).frame(height: 1)
            }
        }
    }
}

/// What the glass styles are made of: the desktop behind the panel, blurred.
///
/// SwiftUI's own materials are tied to the appearance of the window they are
/// in, and the overlay's window has no appearance worth speaking of — it is a
/// borderless transparent panel. Going to AppKit directly is what lets a light
/// style stay light while the app is in a dark theme, and the other way round.
/// The height the words come to once wrapped, reported by the text itself
/// rather than computed here: a line count worked out in code would have to
/// repeat the wrapping the text has already done, and would be wrong at any
/// accessibility text size.
private struct WordsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct DockBlur: NSViewRepresentable {
    let light: Bool
    /// Rounded by the view's own layer rather than by the `clipShape` around
    /// it. A SwiftUI clip is a mask on the SwiftUI layer tree, and an AppKit
    /// view hosted inside it is not in that tree: left to the clip, every
    /// glass style would have square corners inside a rounded panel.
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        // Behind the window rather than within it: there is nothing inside
        // this panel to blur, and the point is the desktop underneath.
        view.blendingMode = .behindWindow
        // Active regardless of whether the app is frontmost, which it almost
        // never is while dictating.
        view.state = .active
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        // The same curve SwiftUI's continuous corners draw, so the blur's
        // edge follows the frame drawn over it rather than cutting inside it.
        view.layer?.cornerCurve = .continuous
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        view.layer?.cornerRadius = cornerRadius
    }
}

/// Aurora's edge: a 1.5pt ring turning once every five seconds.
///
/// The gradient starts and ends on the same yellow, so the sweep has no seam
/// in it to catch the eye on each turn. It is scaled up before it is masked
/// because rotating a gradient the size of the panel would swing its corners
/// out of frame; an angular gradient is the same at any radius, so growing it
/// costs nothing and covers every angle.
private struct DockAuroraRing: View {
    let cornerRadius: CGFloat
    /// Turning while the microphone is open; a still periwinkle ring once the
    /// words have gone off to be rewritten.
    let listening: Bool
    let resting: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turned = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        if listening {
            AngularGradient(colors: DockSurface.auroraRing, center: .center)
                .rotationEffect(.degrees(turned ? 360 : 0))
                .scaleEffect(2)
                .mask { shape.strokeBorder(.black, lineWidth: 1.5) }
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.linear(duration: 5).repeatForever(autoreverses: false)) {
                        turned = true
                    }
                }
        } else {
            shape.strokeBorder(resting, lineWidth: 1.5)
        }
    }
}
