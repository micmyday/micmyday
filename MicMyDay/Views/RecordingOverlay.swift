import AppKit
import SwiftUI

/// What the overlay is currently saying. Strict priority: recording beats busy
/// beats toast, so a take in progress can never be hidden by a notification.
enum OverlayContent: Equatable {
    /// Pressed, but the microphone is not open yet.
    ///
    /// Opening a wireless headset takes a few hundred milliseconds, because it
    /// carries no microphone in the profile it plays audio over and the link
    /// has to be renegotiated. Showing the recording pill through that gap
    /// invited the user to start talking into an input that was not listening;
    /// this state says "heard you, not yet".
    case starting
    case recording
    case busy(AppPhase)
    case profileToast(String)
}

/// One row of the overlay's profile menu, flattened to what the menu shows.
struct OverlayProfileItem: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String
    let shortcut: String?
    let isActive: Bool
}

/// The floating status pill.
///
/// Mostly a status light, but no longer only that: while something is running
/// the badge is a stop control, the profile indicator is a picker, and the
/// optional live-preview panel floats beside it. The window is click-through
/// whenever none of those are on offer.
struct RecordingOverlay: View {
    /// The pill's own fill, shared with the mini badge's cut-out so the two
    /// read as one surface. Follows the theme, so the overlay does not stay a
    /// dark slab floating over the light one.
    @MainActor
    static var fill: Color { .mfPopover }

    /// Mini's corner badge, from the design's constants.
    private static let profileBadge: CGFloat = 16
    private static let profileBadgeGlyph: CGFloat = 10
    private static let profileBadgeOffset: CGFloat = 5
    /// The design says 2.5, but that reads heavier in AppKit than in the
    /// browser mock-up — the badge is small enough that the separating band
    /// competes with the icon itself.
    private static let profileBadgeRing: CGFloat = 1.5

    /// The height the preview panel holds open before a word has been said:
    /// four lines of its own 13pt type, plus the 3pt set between them.
    ///
    /// Four because that is what the Dock reserves, and an indicator should
    /// not change size when you change its shape. Written as the sum it is
    /// rather than the total it comes to, so that changing the type or the
    /// spacing above carries through instead of quietly going wrong.
    private static let previewLineHeight: CGFloat = 15.6
    private static let previewLineSpacing: CGFloat = 3
    private static let previewReservedLines: CGFloat = 4
    private static var reservedPreviewHeight: CGFloat {
        previewReservedLines * previewLineHeight
            + (previewReservedLines - 1) * previewLineSpacing
    }

    let content: OverlayContent
    /// Which shape to draw. The pill's own arrangement is below; the others
    /// are separate views taking the same facts.
    var style: OverlayStyle = .pill
    /// Which surface the Dock draws itself on. Ignored by the pill, which has
    /// one look and takes it from the theme.
    var dockStyle: DockStyle = .obsidian
    let size: OverlaySize
    let level: Double
    let elapsed: String
    let profileName: String?
    let profileShortcut: String?
    let profileSymbol: String
    let engineName: String
    /// A short-lived note shown in the armed profile's slot: "Hands-free"
    /// after a held shortcut is upgraded mid-take.
    /// How far through the maximum recording length this take has run, or
    /// nil when there is no limit to measure against.
    var progress: Double? = nil
    var noteText: String? = nil
    /// The transcript so far when streaming is on; empty otherwise. Shown in
    /// place of "Transcribing…" so the wait has something to read.
    var streamingText: String = ""
    /// The live-preview panel: the words to show, whether they are settled,
    /// and where the panel sits relative to the pill.
    var livePreviewEnabled: Bool = false
    /// While recording these end in words the engine may still revise; when
    /// `livePreviewFirm` they are the settled (possibly rewritten) text.
    var livePreviewText: String = ""
    var livePreviewFirm: Bool = false
    /// How many leading words of `livePreviewText` matched the previous
    /// decode pass. Everything past them is a fresh revision and renders
    /// dimmed, so a change never mutates text that looked settled.
    var livePreviewFirmWords: Int? = nil
    /// Below the pill when the overlay sits at the top of the screen, above
    /// it everywhere else, so the panel grows away from the screen edge.
    var previewBelow: Bool = false
    /// Which dictation is on screen. Only used to tell one take from the
    /// next, so its value carries no meaning beyond changing.
    var take: Int = 0
    var previewAlignment: HorizontalAlignment = .center
    /// The profile picker's rows; empty hides the menu entirely.
    var profiles: [OverlayProfileItem] = []
    var onSelectProfile: ((String) -> Void)? = nil
    /// Ends the dictation the same way Escape does, whatever phase it is in.
    /// Nil renders the badge as the plain status light it used to be.
    var onStop: (() -> Void)? = nil
    /// Moves the indicator out of the way for the rest of this take.
    var onDrag: ((CGSize) -> Void)? = nil

    /// Mini has nowhere to put a profile name, so a switch borrows compact
    /// metrics for the toast's 1.7s and returns to a circle afterwards. The
    /// switch is the one moment the overlay has something to say, so it earns
    /// the extra width.
    private var effectiveSize: OverlaySize {
        if case .profileToast = content, size.isMini { return .compact }
        // The note scrim needs room for its word; Mini borrows the compact
        // metrics for the moment it shows, exactly as the profile toast
        // does.
        if noteText != nil, size.isMini { return .compact }
        return size
    }

    var body: some View {
        switch style {
        case .pill: pillArrangement
        // A new view per take, so the panel opens rather than returns.
        //
        // The overlay's window and its view are kept alive between
        // dictations, so without this the panel carries the last take's
        // height into the next one's first frame and SwiftUI animates the
        // difference away: cancel a take that had grown, start another, and
        // it visibly settles from the old height down to the small form
        // before a word has been said. The height itself is already correct;
        // what has to go is the animation's memory of where the panel used
        // to be, and a change of identity is what clears that.
        case .dock: DockIndicator(state: indicatorState).id(indicatorState.take)
        }
    }

    /// What the other shapes need, gathered from the same fields the pill
    /// reads. They show the words inline rather than in a panel of their own,
    /// so the preview's text and its settledness come straight through.
    private var indicatorState: IndicatorState {
        IndicatorState(
            content: content,
            level: level,
            elapsed: elapsed,
            profileName: profileName,
            profileSymbol: profileSymbol,
            words: livePreviewText.isEmpty ? streamingText : livePreviewText,
            take: take,
            growsDownward: previewBelow,
            note: noteText,
            firm: livePreviewFirm,
            showsWords: livePreviewEnabled,
            progress: progress,
            size: size,
            dockStyle: dockStyle,
            onStop: onStop,
            profiles: profiles,
            onSelectProfile: onSelectProfile,
            onDrag: onDrag
        )
    }

    private var pillArrangement: some View {
        pillStack.indicatorDraggable(onDrag)
    }

    private var pillStack: some View {
        // One structure whether or not the panel has words: branching between
        // a bare pill and a stack changed the pill's view identity when the
        // first word arrived, which visibly restarted the badge's pulse
        // mid-cycle.
        VStack(alignment: previewAlignment, spacing: 8) {
            if previewBelow {
                pill
                if let preview = preview { previewPanel(preview.words, firm: preview.firm) }
            } else {
                if let preview = preview { previewPanel(preview.words, firm: preview.firm) }
                pill
            }
        }
    }

    private var pill: some View {
        HStack(spacing: effectiveSize.gap) {
            badge
            detail
        }
        .padding(.leading, effectiveSize.leadingPadding)
        .padding(.trailing, effectiveSize.trailingPadding)
        .frame(height: effectiveSize.height)
        .background {
            Capsule()
                .fill(Self.fill.opacity(0.82))
                .background(.ultraThinMaterial, in: Capsule())
        }
        .overlay {
            Capsule().strokeBorder(tint.opacity(0.55), lineWidth: 1)
        }
        // Outside the capsule's stroke on purpose: as an overlay on the badge
        // it sat *under* the pill's own 1pt border, which then cut across the
        // profile icon. At 34pt there is no room for a name, but there is room
        // for a symbol — so nothing may be drawn over it.
        .overlay(alignment: .bottomTrailing) { miniProfileBadge }
        // A brief announcement over the whole pill, not a chip squeezed into
        // the profile slot: the content dims underneath, the word shows, and
        // the scrim fades away. Only the scrim animates — animating the
        // pill's own layout is what once made it dance.
        .overlay {
            ZStack {
                if let noteText {
                    Capsule()
                        .fill(Self.fill.opacity(0.9))
                        .overlay {
                            Text(noteText)
                                .font(.system(size: effectiveSize.titleSize, weight: .semibold))
                                .foregroundStyle(Color.mfTextPrimary)
                                .lineLimit(1)
                        }
                    Capsule().strokeBorder(tint.opacity(0.55), lineWidth: 1)
                }
            }
            .animation(.easeOut(duration: 0.25), value: noteText)
        }
        .shadow(color: tint.opacity(0.26), radius: 13)
        .fixedSize()
    }

    // MARK: - Live preview

    /// The words the panel shows, or nil when there is no panel: the preview
    /// is off, the phase has no words, or none have arrived yet.
    ///
    /// Until the first word the pill stands alone, exactly as it does with the
    /// preview turned off. The word is what opens the panel, and it opens at
    /// its full four rows rather than growing into them.
    private var preview: (words: [String], firm: Int)? {
        guard livePreviewEnabled else { return nil }
        switch content {
        case .recording, .busy: break
        case .starting, .profileToast: return nil
        }
        let all = livePreviewText
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !all.isEmpty else { return nil }
        let words = Array(all.suffix(160))
        guard !words.isEmpty else { return nil }
        if livePreviewFirm || !isRecording {
            return (words, words.count)
        }
        // The agreement count was measured on the whole text; translate it
        // into the cropped tail. The newest two words stay tentative even
        // inside an agreed prefix — the engine has heard the least about
        // them, whatever the previous pass said.
        let dropped = all.count - words.count
        let agreed = livePreviewFirmWords.map { max(0, $0 - dropped) } ?? max(0, words.count - 2)
        return (words, min(agreed, max(0, words.count - 2)))
    }

    /// No status chrome in here — no kicker, no dot, no spinner. The pill
    /// already carries phase; this panel is only ever about the words.
    ///
    private func previewPanel(_ words: [String], firm: Int) -> some View {
        previewText(words, firm: firm)
            .font(.system(size: 13))
            .lineSpacing(Self.previewLineSpacing)
            .multilineTextAlignment(.leading)
            // A fixed width, not a cap: the design calls for a 420pt panel,
            // and the flexible version (maxWidth plus a vertical fixedSize)
            // fed the hosting view constraints it answered with a
            // three-thousand-point minimum height, throwing the pill off the
            // screen.
            .frame(width: 392, alignment: .leading)
            // Four rows the moment the panel exists, the same count the Dock
            // opens to, so the two shapes agree on how much of what you said
            // is worth keeping on screen. A minimum rather than a fixed
            // height: unlike the Dock this panel is not clipped, so a long
            // take still grows past it rather than losing the tail.
            //
            // Anchored at the top, so the words start where reading starts and
            // stay put as the rest arrive underneath.
            .frame(minHeight: Self.reservedPreviewHeight, alignment: .topLeading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Self.fill.opacity(0.82))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            }
            // Deliberately not animated at all. Animating the panel's size
            // made its first appearance visibly shove the pill out of place
            // and slide it back — the window takes its final frame at once,
            // and the panel's height animated into it underneath.
    }

    /// Words the engine has stood by render at full opacity; everything it
    /// just revised hangs back at 0.82, the newest word furthest at 0.62,
    /// and the whole draft firms once the words are settled. Showing a fresh
    /// revision at full confidence would be a lie, and it was also what read
    /// as flicker: settled-looking text kept changing.
    private func previewText(_ words: [String], firm: Int) -> Text {
        let ink = Color.mfTextPrimary
        guard firm < words.count else {
            return Text(words.joined(separator: " ")).foregroundColor(ink)
        }
        var text = Text("")
        let firmPart = words.prefix(firm).joined(separator: " ")
        if !firmPart.isEmpty {
            text = Text(firmPart).foregroundColor(ink) + Text(" ")
        }
        let tail = Array(words.dropFirst(firm))
        if tail.count > 1 {
            text = text
                + Text(tail.dropLast().joined(separator: " "))
                    .foregroundColor(ink.opacity(0.82))
                + Text(" ")
        }
        if let newest = tail.last {
            text = text + Text(newest).foregroundColor(ink.opacity(0.62))
        }
        return text
    }

    // MARK: - Badge

    /// The badge, as a stop control whenever a dictation can be ended. It acts
    /// exactly like Escape — abandons whatever is running, at any phase —
    /// because two stop gestures with different meanings would be worse than
    /// one.
    @ViewBuilder
    private var badge: some View {
        if let onStop {
            Button(action: onStop) { badgeFace }
                .buttonStyle(.plain)
                .help("Stop and discard, the same as Esc")
        } else {
            badgeFace
        }
    }

    private var badgeFace: some View {
        let metrics = effectiveSize
        return ZStack {
            if isRecording {
                // The system's one loop, at the same 1400 ms rhythm as the panel.
                OverlayPulse(size: metrics.badgeSize, tint: tint)
            }
            if isStarting {
                // Bigger on mini, where the ring is the only thing that can
                // carry "not ready yet": there is no room for a word, and the
                // dot alone looks identical to a recording that has started.
                OverlayStartingRing(
                    size: metrics.badgeSize + (metrics.isMini ? 12 : 6),
                    tint: tint
                )
            }
            Circle()
                .fill(tint)
                .frame(width: metrics.badgeSize, height: metrics.badgeSize)

            // Mini has no meter, so the level breathes as a ring 3pt outside
            // the badge — the right amount of information for a 34pt circle.
            if metrics.isMini, isRecording {
                Circle()
                    .strokeBorder(Color.mfRecord, lineWidth: 2)
                    .frame(width: metrics.badgeSize + 6, height: metrics.badgeSize + 6)
                    .scaleEffect(1 + 0.34 * min(max(level, 0), 1))
                    .opacity(0.25 + 0.7 * min(max(level, 0), 1))
                    .animation(.easeOut(duration: 0.12), value: level)
            }

            Image(systemName: badgeSymbol)
                .font(.system(size: metrics.badgeGlyph, weight: .semibold))
                // Both badge fills need their own ink: the accent is yellow
                // in two themes, and Indigo's record colour is yellow too, so
                // neither can assume white on top.
                .foregroundStyle(tint == .mfAccent ? Color.mfOnAccent : Color.mfOnRecord)
        }
        .frame(width: metrics.badgeSize, height: metrics.badgeSize)
    }

    /// The profile indicator as a picker: the same menu on the wide pill, the
    /// compact glyph and the mini badge, so the profile can be changed
    /// mid-recording without reaching for the cycle shortcut. Picking fires
    /// the same toast as that shortcut, so both give identical feedback.
    @ViewBuilder
    private func profilePicker<Face: View>(@ViewBuilder label: () -> Face) -> some View {
        if let onSelectProfile, !profiles.isEmpty {
            Menu {
                ForEach(profiles) { profile in
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
                label()
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            label()
        }
    }

    @ViewBuilder
    private var miniProfileBadge: some View {
        if effectiveSize.isMini, isRecording, profileName != nil {
            profilePickerMiniLabel
        }
    }

    private var profilePickerMiniLabel: some View {
        profilePicker {
            Image(systemName: profileSymbol)
                .font(.system(size: Self.profileBadgeGlyph, weight: .semibold))
                .foregroundStyle(Color.mfOnAccent)
                .frame(width: Self.profileBadge, height: Self.profileBadge)
                .background(Circle().fill(Color.mfAccent))
                // A true cut-out: a filled disc in the overlay's own fill,
                // 2.5pt wider on every side. Drawn as a stroke it left a gap
                // the level ring showed through as it scaled past.
                .background(
                    Circle()
                        .fill(Self.fill)
                        .frame(
                            width: Self.profileBadge + Self.profileBadgeRing * 2,
                            height: Self.profileBadge + Self.profileBadgeRing * 2
                        )
                )
                // Offset past both edges so the badge sits mostly outside the
                // circle and cannot cover the microphone.
                .offset(x: Self.profileBadgeOffset, y: Self.profileBadgeOffset)
        }
    }

    private var badgeSymbol: String {
        switch content {
        case .starting, .recording: return onStop == nil ? "mic.fill" : "stop.fill"
        case .busy(let phase): return phase.symbolName
        case .profileToast: return profileSymbol
        }
    }

    private var isRecording: Bool {
        if case .recording = content { return true }
        return false
    }

    private var isStarting: Bool {
        if case .starting = content { return true }
        return false
    }

    /// Starting keeps the record colour rather than the accent: it is the same
    /// pill a moment early, not a different kind of event, and switching hue
    /// halfway through reads as two things happening.
    private var tint: Color { isRecording || isStarting ? .mfRecord : .mfAccent }

    // MARK: - Detail

    /// The meter, the clock and the armed profile, as one row.
    ///
    /// Shared with the starting state, which draws it hidden purely to claim
    /// the same width, so the pill does not resize the instant recording
    /// actually begins.
    private func recordingDetail(_ metrics: OverlaySize) -> some View {
        HStack(spacing: metrics.gap) {
            BeaconLevelMeter(
                level: level,
                segments: metrics.meterSegments,
                height: metrics.meterHeight,
                isRecording: true
            )
            .frame(width: metrics.meterWidth)

            Text(elapsed)
                .font(.system(size: metrics.elapsedSize, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.mfTextPrimary.opacity(0.9))

            // Words arriving while the user is still speaking. Only Apple's
            // recogniser produces these; every other engine has nothing to show
            // until the recording ends, and this stays empty for them. When
            // the preview panel is on it carries the words instead, and the
            // profile chip keeps its place — the first partial used to evict
            // the picker for the rest of the take.
            if let tail = streamingTail, !livePreviewEnabled {
                Text(tail)
                    .font(.system(size: metrics.elapsedSize, weight: .regular))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(width: metrics == .wide ? 170 : 104, alignment: .leading)
                    .animation(.easeOut(duration: 0.12), value: tail)
            } else if let profileName {
                armedProfile(profileName)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        let metrics = effectiveSize
        switch content {
        case .starting where metrics.isMini:
            EmptyView()
        case .starting:
            // The recording layout, drawn invisibly, so the pill is already the
            // width it will be a moment later. Sized from the real views rather
            // than a guessed constant: the meter, the clock and the armed
            // profile all vary with size and content, and the overlay visibly
            // grew mid-press when "Starting…" was measured on its own.
            ZStack {
                recordingDetail(metrics).hidden()
                Text("Starting\u{2026}")
                    .font(.system(size: metrics.elapsedSize, weight: .medium))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.7))
            }
        case .recording where metrics.isMini:
            EmptyView()
        case .busy where metrics.isMini:
            EmptyView()
        case .recording:
            recordingDetail(metrics)

        case .busy(let phase):
            VStack(alignment: .leading, spacing: 1) {
                if metrics.showsKicker {
                    Text(kicker(for: phase).uppercased())
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .tracking(1.3)
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
                }
                if let tail = streamingTail, !livePreviewEnabled {
                    // The pill is a fixed width, so the text scrolls: the most
                    // recent words matter, the earlier ones are already said.
                    // When the preview panel is on it carries the words, and
                    // showing them here too doubled every word on screen.
                    Text(tail)
                        .font(.system(size: metrics.titleSize, weight: .regular))
                        .foregroundStyle(Color.mfTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(width: metrics == .wide ? 190 : 120, alignment: .leading)
                        .animation(.easeOut(duration: 0.12), value: tail)
                } else {
                    Text(busyTitle(for: phase))
                        .font(.system(size: metrics.titleSize, weight: .semibold))
                        .foregroundStyle(Color.mfTextPrimary)
                        .fixedSize()
                }
            }

            // Rewriting can take a few seconds with a slow model, and a static
            // pill reads as hung. The spinner is the only thing on the overlay
            // saying "still working" during the busy states.
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .scaleEffect(metrics == .wide ? 0.7 : 0.6)
                .frame(width: metrics == .wide ? 16 : 12)
                .tint(Color.mfTextPrimary.opacity(0.7))

        case .profileToast(let name):
            VStack(alignment: .leading, spacing: 1) {
                Text("REWRITING WITH")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .tracking(1.3)
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
                Text(name)
                    .font(.system(size: metrics.titleSize, weight: .semibold))
                    .foregroundStyle(Color.mfTextPrimary)
            }
            .fixedSize()
        }
    }

    /// Compact keeps only the wand: the name is the widest thing on the pill,
    /// and mid-sentence you need the meter and the timer more.
    @ViewBuilder
    private func armedProfile(_ name: String) -> some View {
        if effectiveSize.showsProfileName {
            profilePicker {
                HStack(spacing: 5) {
                    Image(systemName: profileSymbol).font(.system(size: 10))
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if let profileShortcut {
                        Text(profileShortcut)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
                    }
                    // The affordance that says this is a picker, not a label.
                    if onSelectProfile != nil, !profiles.isEmpty {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Color.mfAccent.opacity(0.7))
                    }
                }
                .foregroundStyle(Color.mfAccent)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.mfAccent.opacity(0.16), in: Capsule())
            }
        } else {
            profilePicker {
                Image(systemName: profileSymbol)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mfAccent)
                    .help(name)
            }
        }
    }

    /// The words to show while a transcript streams in, or nil when there is
    /// nothing yet or no room. Mini is a circle with no text at all.
    private var streamingTail: String? {
        let text = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !effectiveSize.isMini else { return nil }
        return text
    }

    private func kicker(for phase: AppPhase) -> String {
        switch phase {
        case .enhancing: return "Rewriting"
        case .inserting: return "Typing"
        default: return engineName
        }
    }

    private func busyTitle(for phase: AppPhase) -> String {
        switch phase {
        case .enhancing: return profileName ?? "Rewriting"
        case .inserting: return "Back to your app"
        default: return "Transcribing"
        }
    }
}

/// The 1400 ms ring behind the badge while the microphone is live.
private struct OverlayPulse: View {
    let size: CGFloat
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(tint, lineWidth: 2)
            .frame(width: size, height: size)
            .scaleEffect(expanded ? 1.65 : 0.95)
            .opacity(expanded ? 0 : 0.5)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    expanded = true
                }
            }
    }
}

/// The ring that turns while the microphone is being opened.
///
/// A ring rather than a system spinner: the badge is 34pt at its smallest and
/// a `ProgressView` inside it reads as a smudge, where an arc on the badge's
/// own edge stays legible and matches the pulse it replaces.
private struct OverlayStartingRing: View {
    let size: CGFloat
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    @State private var sweeping = false

    /// A comet rather than a dash.
    ///
    /// The arc is stroked with an angular gradient that fades from nothing to
    /// full tint, so it has a bright head and a tail that dissolves, and a
    /// small dot rides the head. On a badge this size a plain rotating mark
    /// reads as a stutter, because there is not enough arc for the eye to
    /// follow; a fading tail gives it something continuous to track.
    ///
    /// The tail also breathes, lengthening and shortening as it turns, which
    /// keeps a wait of a second or two from looking like a loop repeating.
    var body: some View {
        let head = spinning ? 1.0 : 0.0
        return ZStack {
            Circle()
                .trim(from: 0, to: sweeping ? 0.55 : 0.28)
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0), tint.opacity(0.35), tint],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(sweeping ? 198 : 100)
                    ),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )

            // The head, which keeps the leading edge crisp where the gradient
            // alone would look soft.
            //
            // Placed at three o'clock, because that is where a trimmed `Circle`
            // begins, and then turned by the same angle the arc ends at. Sitting
            // it at twelve o'clock instead left it a quarter turn behind, out in
            // the part of the tail that has already faded, where it read as a
            // stray dot rather than as the head of anything.
            Circle()
                .fill(tint)
                .frame(width: 2.6, height: 2.6)
                .offset(x: size / 2)
                .rotationEffect(.degrees(sweeping ? 0.55 * 360 : 0.28 * 360))
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(head * 360))
        .opacity(reduceMotion ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                spinning = true
            }
            // Deliberately not a multiple of the rotation, so the two never
            // line up and the animation does not visibly restart.
            withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                sweeping = true
            }
        }
    }
}

