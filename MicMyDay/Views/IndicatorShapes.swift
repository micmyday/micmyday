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
    var listening: Bool = true
    var bars: Int = 13
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
                Capsule()
                    .fill(tint)
                    .frame(width: 2.5, height: Self.floorHeight + value * Self.reach)
                    .opacity(listening ? 0.45 + value * 0.55 : 0.2)
            }
        }
        .frame(height: Self.floorHeight + Self.reach)
        .animation(.linear(duration: 0.1), value: heights)
        .onAppear { heights = Self.sample(level: level, bars: bars) }
        .onChange(of: level) { _, new in heights = Self.sample(level: new, bars: bars) }
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
    let diameter: CGFloat
    let onStop: () -> Void

    var body: some View {
        Button(action: onStop) {
            ZStack {
                Circle().fill(tint)
                Image(systemName: "stop.fill")
                    .font(.system(size: diameter * 0.35, weight: .bold))
                    .foregroundStyle(Color.mfOnRecord)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
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

    private func face(_ name: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: state.profileSymbol).font(.system(size: 9))
            if !compact {
                Text(name).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            // A quiet chevron, so it reads as something you can open rather
            // than a label that happens to be next to the time.
            if state.onSelectProfile != nil, !state.profiles.isEmpty {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .opacity(0.55)
            }
        }
        .foregroundStyle(Color.mfAccent)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.mfAccent.opacity(0.12), in: Capsule())
        .contentShape(Capsule())
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

    /// The tallest the words have needed so far in this take.
    ///
    /// The panel opens as the form without a preview and grows a line at a
    /// time as the words fill it, up to four, and there it stays.
    ///
    /// A high-water mark rather than the current measurement, which is the
    /// whole difference between this and the version that was rejected
    /// before. Following the text exactly made the panel pump throughout a
    /// dictation: tall when a phrase landed, short again in the gap before
    /// the next one, short once more while the transcript cleared for the
    /// rewrite. Growth that never reverses has no pump in it, because within
    /// one take the panel only ever settles into a size it has already
    /// earned.
    @State private var grown = GrownWords()

    /// The tallest the words have needed, and which take that was.
    ///
    /// The take is stored beside the height rather than cleared by a separate
    /// change handler, because a handler runs after the body it would have
    /// corrected. The panel is drawn once at the previous take's height
    /// before the reset arrives, which reads as the indicator appearing too
    /// tall and then settling: exactly one frame of the wrong answer, which
    /// is enough to see. Carrying the take inside the value means the body
    /// can never read a height that belongs to a different dictation.
    private struct GrownWords: Equatable {
        var take = -1
        var height: CGFloat = 0
    }

    private var grownTo: CGFloat { grown.take == state.take ? grown.height : 0 }

    /// A compact baseline for the controls, with extra reading room when
    /// live text is enabled. Controls keep their natural width when needed.
    private var width: CGFloat { state.showsWords ? 365 : 330 }

    private var height: CGFloat? {
        guard state.showsWords else { return 44 }
        return 44 + wordsHeight
    }

    /// Clamped to whole lines so the panel arrives at a resting place rather
    /// than tracking the text's height continuously, which would creep by a
    /// point or two as a line filled up.
    private var wordsHeight: CGFloat {
        guard grownTo > 0 else { return 0 }
        let lines = min(Self.maximumLines, max(1, (grownTo / Self.lineHeight).rounded(.up)))
        return Self.wordsPadding + lines * Self.lineHeight
    }

    /// Font 13 at the four point line spacing set below.
    private static let lineHeight: CGFloat = 19.6
    private static let maximumLines: CGFloat = 4
    private static let wordsPadding: CGFloat = 12
    /// The full word area, which is what four lines come to. Kept as a
    /// constant because the mask below is expressed as a fraction of it.
    private static let fullWordsHeight: CGFloat = wordsPadding + maximumLines * lineHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Present but empty until the first words arrive, so the panel
            // starts at the same height as the form without a preview.
            if state.showsWords {
                Text(state.words)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(Color.mfTextPrimary.opacity(state.firm ? 0.95 : 0.5))
                    // Its full natural height, however many lines that is.
                    // Without this the text is fitted to the box instead and
                    // ends in an ellipsis, which puts the truncation at the
                    // end: the words being spoken right now are the ones cut
                    // off, and the panel shows the opening of a sentence
                    // finished long ago.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    // Anchored at the bottom, so a take that outgrows the
                    // panel scrolls off the top and the newest line always
                    // sits just above the controls. A short phrase still
                    // starts where reading starts, because until the text
                    // fills the box the two anchors put it in the same place.
                    // What the words actually need, reported rather than
                    // guessed at: a line count computed here would have to
                    // repeat the wrapping the text has already done, and
                    // would be wrong at any accessibility text size.
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: WordsHeightKey.self,
                                value: geometry.size.height
                            )
                        }
                    )
                    .frame(height: wordsHeight, alignment: .bottomLeading)
                    .clipped()
                    // A line cut in half by the top edge reads as damage.
                    // Fading the last few points turns it into text passing
                    // out of view, which is what it is.
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 16 / Self.fullWordsHeight),
                                .init(color: .black, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
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
            maxWidth: state.showsWords ? width : nil,
            minHeight: height,
            maxHeight: height,
            alignment: .bottom
        )
        .background(RecordingOverlay.fill, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(alignment: .bottomLeading) { elapsedLine }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.mfFill(0.07), lineWidth: 1)
        }
        .indicatorDraggable(state.onDrag)
        // Inside the window's 34pt transparent margin. The design's 24pt
        // radius at a 20pt drop reaches 44pt below the panel, past the edge
        // of the window drawing it, and the part that did not fit was sliced
        // off square.
        .shadow(color: .black.opacity(0.62), radius: 16, y: 10)
        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
        .animation(.easeOut(duration: 0.4), value: width)
        .animation(.easeOut(duration: 0.4), value: height)
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
            height: state.showsWords ? 44 + Self.fullWordsHeight : nil,
            alignment: state.growsDownward ? .top : .bottom
        )
        .onPreferenceChange(WordsHeightKey.self) { measured in
            // Upward only, and only within one take. The reset below is what
            // makes "within one take" true.
            //
            // An empty string is not a measurement worth keeping: it still
            // lays out as one empty line, so accepting it would open every
            // take one line tall instead of at the small form.
            guard !state.words.isEmpty else { return }
            if grown.take != state.take {
                grown = GrownWords(take: state.take, height: measured)
            } else if measured > grown.height {
                grown.height = measured
            }
        }

    }

    /// The design's own periwinkle, rather than whichever accent the theme
    /// happens to carry.
    ///
    /// The mock was drawn on the Indigo palette, where the accent is this
    /// colour, and the line reads as a cool measure running under a warm
    /// recording light. Taking the theme's accent instead made it yellow on
    /// yellow under Sunrise, where it stops being a second thing and becomes
    /// a brighter part of the first.
    /// Sixteen rather than the design's twenty: at 44pt tall the corner was
    /// taking nearly half the height, which reads as a lozenge rather than a
    /// panel, and the shape now opens at that height on every take.
    static let cornerRadius: CGFloat = 16

    /// Where the elapsed line begins, measured from the panel's left edge.
    private static let elapsedStart: CGFloat = 15

    private static let elapsedTint = Color(red: 0.647, green: 0.682, blue: 1)

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
                        colors: [Self.elapsedTint.opacity(0.35), Self.elapsedTint],
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
                IndicatorStopButton(tint: state.tint, diameter: 26, onStop: onStop)
            } else {
                Image(systemName: state.markSymbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(state.tint)
                    .frame(width: 26)
            }

            if let note = state.note {
                // In the slot the phase name uses, not over the whole panel.
                // The Dock is large enough that covering it to say two words
                // would read as the app interrupting itself; the row already
                // carries words when it has any to say.
                Text(note)
                    .font(DSFont.ui(12, .semibold))
                    .foregroundStyle(state.tint)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            } else if state.isRecording {
                IndicatorMeter(level: state.level, tint: state.tint)
            } else {
                Text(state.kicker)
                    .font(DSFont.ui(12, .medium))
                    // Held back from the full tint. At full strength the word
                    // was the brightest thing in the row, which put it ahead
                    // of the stop button and the clock; it is a caption for
                    // the state, not the state itself.
                    .foregroundStyle(state.tint.opacity(0.7))
                    // Never broken across lines: the row is one line tall, so
                    // a second one is drawn outside it.
                    .lineLimit(1)
                    .fixedSize()
            }

            Spacer(minLength: 6)

            IndicatorProfile(state: state)

            Text(state.elapsed)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
                // Its natural width, always. Squeezed by a long phase label
                // beside the armed profile, the clock collapsed to an
                // ellipsis, which is the one thing it can say that is worse
                // than saying nothing.
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .animation(.easeOut(duration: 0.25), value: state.note)
    }
}


/// The height the words come to once wrapped, reported by the text itself.
private struct WordsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
