import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The status item: the MicMyDay mark as a monochrome template, plus — while
/// recording — a pink tint, a faint record pill and the elapsed time.
///
/// The shape never changes. People find their menu-bar items by silhouette, so
/// swapping between six phase glyphs cost recognisability and told the user
/// little: transcribing, enhancing and typing each last a second or two, which
/// is too brief to read. State is carried by tint and the timer instead, which
/// is the macOS convention and is the part that actually matters — whether the
/// microphone is live.
///
/// It observes MenuBarModel rather than AppState: MenuBarExtra re-rasterizes
/// this view on every observed change, and rasterizing an SF Symbol is far too
/// expensive to do at the rate AppState publishes input levels.
struct MenuBarLabel: View {
    @EnvironmentObject private var model: MenuBarModel

    var body: some View {
        HStack(spacing: 3) {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 17)
            if let elapsed = model.elapsed {
                Text(elapsed).font(.system(size: 9, weight: .medium, design: .monospaced))
            }
        }
        .padding(.horizontal, model.emphasis == .neutral ? 0 : 4)
        .padding(.vertical, model.emphasis == .neutral ? 0 : 1)
        .background(pill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .foregroundStyle(tint)
        .accessibilityLabel(model.accessibilityLabel)
    }

    private var pill: Color {
        switch model.emphasis {
        case .recording: return Color.mfRecord.opacity(0.16)
        case .failed: return Color.mfWarn.opacity(0.14)
        case .neutral: return .clear
        }
    }

    private var tint: Color {
        switch model.emphasis {
        case .recording: return .mfRecord
        case .failed: return .mfWarn
        case .neutral: return .primary
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore
    @State private var isDropTargeted = false

    /// The panel is a fixed size in every phase. A popover that resizes to its
    /// content re-anchors itself, and a dictation walked it through four
    /// different heights — which read as the window being replaced rather than
    /// updated. Header, action and footer are pinned; everything that varies by
    /// phase lives in one flexible region that absorbs the difference, and
    /// scrolls in the rare case it cannot.
    private static let panelWidth: CGFloat = 320
    private static let panelHeight: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            phaseHeader

            actionButton

            if showsEmptyState {
                // Centred in whatever space is left, rather than pinned under
                // the action button.
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if visiblePermissionIssue != nil {
                            permissionCard
                        }
                        if let recovery = visibleRecovery {
                            recoveryCard(recovery)
                        }
                        phaseDetail
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            // Pinned above the footer rather than scrolling with the phase
            // detail: switching profile is a standing control, not part of
            // whatever the app happens to be doing.
            if settings.enhancementEnabled {
                rewriteRow
            }

            licenceNotice

            Hairline()

            footer
        }
        .padding(16)
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        .background(Color.mfCanvas)
        .preferredColorScheme(.dark)
        .dsAnimation(.timingCurve(0.2, 0, 0, 1, duration: 0.18), value: layoutKey)
        .overlay { if isDropTargeted, appState.canRunTool { dropTarget } }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard appState.canRunTool, let provider = providers.first else { return false }
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in appState.transcribeAudioFile(at: url) }
            }
            return true
        }
        .onAppear {
            appState.activate()
            appState.startPermissionPolling()
        }
        .onDisappear { appState.stopPermissionPolling() }
    }

    /// Shown while a file hangs over the panel, over everything else, so
    /// there is exactly one message about what releasing it will do.
    private var dropTarget: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.mfCanvas.opacity(0.92))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.mfAccent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            VStack(spacing: 8) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.mfAccent)
                Text("Drop to transcribe")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mfTextPrimary)
            }
        }
        .padding(10)
    }

    /// Everything that depends on the phase, in the design's order. With a
    /// fixed panel the design's own rule — no transcript card while recording
    /// or transcribing — costs nothing, so it is back.
    @ViewBuilder
    private var phaseDetail: some View {
        if case let .recording(startedAt) = appState.phase {
            recordingDetail(startedAt: startedAt)
        } else if appState.phase.isBusy {
            busyDetail
        }

        if !appState.lastTranscript.isEmpty, !isRecording, !appState.phase.isBusy {
            lastTranscriptCard
        }

    }

    /// A fixed-height panel needs something to say when there is nothing to
    /// show, or a fresh install is mostly empty space.
    private var showsEmptyState: Bool {
        appState.lastTranscript.isEmpty && appState.phase == .idle
            && appState.recovery == nil && appState.permissionIssues.isEmpty
    }

    private var visiblePermissionIssue: PermissionIssue? {
        guard !isRecording, !appState.phase.isBusy else { return nil }
        // One card at a time: a failure's tailored advice (with its Dismiss
        // button, the only way out of the failed phase) beats the generic
        // permission hint.
        guard visibleRecovery == nil else { return nil }
        return appState.permissionIssues.first
    }

    private var recordingPermissionIssue: PermissionIssue? {
        guard !isRecording, !appState.phase.isBusy else { return nil }
        return appState.permissionIssues.first { $0.blocksRecording }
    }

    private var visibleRecovery: RecoveryAdvice? {
        appState.recovery
    }

    /// Block 7 — how the profile gets changed mid-flow without opening a
    /// window. Shown only when rewriting is on.
    private var rewriteRow: some View {
        HStack(spacing: 8) {
            Image(systemName: settings.icon(forProfile: settings.rewriteProfileID).symbol)
                .font(.system(size: 12))
                .foregroundStyle(Color.mfAccent)
            Text("Rewrite with")
                .font(.system(size: 11))
                .foregroundStyle(appState.activeProfileNote == nil
                                 ? Color.mfTextPrimary.opacity(0.62)
                                 : Color.mfAccent)
                .fixedSize()
            ProfilePopUp(
                profiles: settings.rewriteProfiles,
                selection: $settings.rewriteProfileID
            )
            .frame(maxWidth: .infinity)

            // The same action the cycle shortcut fires.
            Button {
                if let profile = settings.cycleRewriteProfile() {
                    appState.announceProfile(profile.name)
                }
            } label: {
                Image(systemName: "chevron.right.2")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Next profile")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mfFill(0.04), in: RoundedRectangle(cornerRadius: MFMetric.radiusControl, style: .continuous))
    }

    private var currentProfileName: String {
        settings.currentRewriteProfile?.name ?? "Choose a profile"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 22))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
            Text("Press \(settings.shortcut.displayString) anywhere to dictate.")
                .font(DSFont.ui(12))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.62))
            Text("Your transcript appears here.")
                .font(DSFont.ui(11))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    /// Changes exactly when the panel's content changes, so the cross-fade is
    /// not restarted by the elapsed-time tick or the level meter.
    private var layoutKey: String {
        switch appState.phase {
        case .recording: return "recording"
        case .failed: return "failed"
        case .idle: return "idle"
        default: return "busy"
        }
    }

    // MARK: - 1. Phase header

    private var phaseHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                if isRecording {
                    RecordPulse()
                }
                Image(systemName: visiblePermissionIssue != nil ? "exclamationmark.triangle" : appState.phase.symbolName)
                    .font(.system(size: 27))
                    .foregroundStyle(phaseColor)
            }
            .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(DSFont.ui(13, .semibold))
                    .foregroundStyle(Color.mfTextPrimary)
                Text(headerSubtitle)
                    .font(DSFont.ui(10))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if appState.phase.isBusy {
                ProgressView().controlSize(.small)
            }

            Button {
                NSApp.keyWindow?.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.35))
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Close")
        }
    }

    private var headerTitle: String {
        if appState.phase == .idle, appState.voiceActivationArmed {
            return "Listening for speech…"
        }
        if appState.phase == .idle, visiblePermissionIssue != nil { return "Permissions needed" }
        return appState.phase.title
    }

    private var headerSubtitle: String {
        switch appState.phase {
        case .recording:
            return appState.activeInputDeviceName ?? "Microphone"
        case .failed:
            return "See the message below"
        default:
            if visiblePermissionIssue != nil { return "Review permissions below" }
            return "Shortcut: \(settings.shortcut.displayString)"
        }
    }

    // MARK: - 2. Recovery card

    private var permissionCard: some View {
        DSCard(padding: 10, spacing: 8, fill: Color.mfWarn.opacity(0.12)) {
            Text("MicMyDay is missing some permissions, so parts of it may not work yet.")
                .font(DSFont.ui(12))
                .lineSpacing(3)
                .foregroundStyle(Color.mfTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            // The action button above is the hint when a blocking permission
            // is missing; only one "Review permissions" control at a time.
            if recordingPermissionIssue == nil {
                Button("Review permissions") { appState.showSettings(selecting: .permissions) }
                    .buttonStyle(.link)
            }
        }
    }

    private func recoveryCard(_ advice: RecoveryAdvice) -> some View {
        DSCard(padding: 10, spacing: 8, fill: Color.mfRecord.opacity(0.12)) {
            Text(advice.message)
                .font(DSFont.ui(12))
                .lineSpacing(3)
                .foregroundStyle(Color.mfTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                if advice.offersAccessibility, recordingPermissionIssue == nil {
                    Button("Review permissions") {
                        appState.showSettings(selecting: .permissions)
                    }
                    .buttonStyle(.link)
                }
                Button("Dismiss") { appState.clearError() }
                    .buttonStyle(.link)
            }
        }
    }

    // MARK: - 3. Primary action

    private var actionButton: some View {
        Button {
            if recordingPermissionIssue != nil {
                appState.showSettings(selecting: .permissions)
            } else {
                appState.toggleRecording()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isRecording ? "stop.fill" : recordingPermissionIssue != nil ? "exclamationmark.triangle" : "mic.fill")
                Text(actionTitle)
                Spacer(minLength: 8)
                if appState.hotKeyRegistered && recordingPermissionIssue == nil {
                    KeyCombo(combo: settings.shortcut.displayString, inverse: true)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(appState.phase.isBusy)
        .tint(isRecording ? Color.mfRecord : Color.mfAccent)
    }

    private var actionTitle: String {
        if recordingPermissionIssue != nil { return "Review permissions" }
        switch appState.phase {
        case .recording: return "Stop & transcribe"
        case .requestingPermission: return "Checking permissions"
        case .transcribing: return "Transcribing"
        case .enhancing: return "Enhancing"
        case .inserting: return "Typing"
        case .idle: return "Start dictation"
        case .failed: return "Try again"
        }
    }

    // MARK: - 4. Recording detail

    private func recordingDetail(startedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            // Panel instance of the audio scope: 24 segments at 24pt.
            BeaconLevelMeter(
                level: Double(appState.inputLevel),
                segments: 24,
                height: 24,
                isRecording: true
            )

            HStack(spacing: 8) {
                Text(appState.activeInputDeviceName ?? "Microphone")
                    .font(DSFont.ui(11))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.62))
                    .lineLimit(1)
                Spacer(minLength: 0)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(elapsedOfMaximum(since: startedAt, now: context.date))
                        .font(DSFont.mono(10))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.62))
                }
            }

            HStack(spacing: 8) {
                Text(stopHint)
                    .font(DSFont.ui(11))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Cancel") { appState.cancelRecording() }
                    .buttonStyle(.plain)
                    .font(DSFont.ui(11))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.62))
            }
        }
    }

    private var stopHint: String {
        if settings.autoStopOnSilence {
            return "Stops after \(formattedSilence) s of silence"
        }
        // In hold-to-record a second press never arrives; releasing is what
        // ends the recording.
        if settings.shortcutMode == .holdToRecord {
            return "Release \(settings.shortcut.displayString) to stop"
        }
        return "Press \(settings.shortcut.displayString) again to stop"
    }

    private var formattedSilence: String {
        String(format: "%g", settings.silenceStopSeconds)
    }

    private func elapsedOfMaximum(since start: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(start)))
        let maximum = settings.maximumRecordingSeconds
        return String(format: "%d:%02d / %d:%02d",
                      elapsed / 60, elapsed % 60, maximum / 60, maximum % 60)
    }

    // MARK: - 5. Busy detail

    /// Says what is happening and what it costs — which machine the audio is
    /// on, and what survives a failure.
    private var busyDetail: some View {
        VStack(alignment: .leading, spacing: 7) {
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
            Text(busyNote)
                .font(DSFont.ui(11))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var busyNote: String {
        switch appState.phase {
        case .transcribing, .requestingPermission:
            return transcriptionNote
        case .enhancing:
            let profile = settings.currentRewriteProfile?.name ?? "Rewrite"
            return "\(profile) · raw transcript is kept if this fails"
        case .inserting:
            return "Returning focus to \(appState.insertionTargetName ?? "your app")"
        default:
            return ""
        }
    }

    private var transcriptionNote: String {
        let name = settings.provider.title
        switch settings.provider {
        case .whisper, .parakeet, .nemotron:
            return "\(name) · audio stays on this Mac"
        case .appleSpeech:
            return "\(name) · on-device when the language supports it"
        case .openAI:
            return "\(name) · audio is uploaded to api.openai.com"
        case .gemini:
            return "\(name) · audio is uploaded to Google"
        case .custom:
            let host = URL(string: settings.customBaseURL)?.host() ?? "your server"
            return "\(name) · audio is uploaded to \(host)"
        }
    }

    // MARK: - 6. Last transcription

    private var lastTranscriptCard: some View {
        DSCard(padding: 10, spacing: 7, fill: Color.secondary.opacity(0.07)) {
            HStack {
                Text("Last transcription")
                    .font(DSFont.ui(10, .semibold))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.62))
                Spacer()
                Button {
                    appState.copyLastTranscript()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.mfTextPrimary.opacity(0.62))
                .help("Copy transcription")
            }

            Text(appState.lastTranscript)
                .font(DSFont.ui(12))
                .lineSpacing(3.5)
                .foregroundStyle(Color.mfTextPrimary)
                .lineLimit(4)
                .textSelection(.enabled)

            switch appState.lastDelivery {
            case let .pasted(appName):
                StatusLabel(
                    text: "Pasted into \(appName ?? "the focused app") · also copied",
                    tone: .neutral,
                    symbol: "clipboard.fill"
                )
            case let .insertedNotCopied(appName):
                StatusLabel(
                    text: "Typed into \(appName ?? "the focused app") · not copied",
                    tone: .warn,
                    symbol: "exclamationmark.triangle"
                )
            case .remainderOnClipboard:
                StatusLabel(
                    text: "Partly typed · press ⌘V for the rest",
                    tone: .warn,
                    symbol: "exclamationmark.triangle"
                )
            case .replacementOnClipboard:
                StatusLabel(
                    text: "Partly typed · ⌘V replaces it with the full text",
                    tone: .warn,
                    symbol: "exclamationmark.triangle"
                )
            case .clipboardOnly:
                // Not a warning when the user has automatic pasting off: this
                // is simply how MicMyDay works then, and flagging it every time
                // would nag about a setting they chose.
                if settings.automaticPasteEnabled {
                    StatusLabel(text: "Clipboard only: press ⌘V", tone: .warn, symbol: "exclamationmark.triangle")
                } else {
                    StatusLabel(text: "Copied · press ⌘V", tone: .neutral, symbol: "doc.on.clipboard")
                }
            case .none:
                EmptyView()
            }

            if let note = appState.lastEnhancementNote {
                StatusLabel(text: note, tone: .warn, symbol: "wand.and.stars")
            }
        }
    }

    // MARK: - 7. Footer

    /// Shown in the panel only when dictation is actually blocked. A trial that
    /// is still running says nothing here: a countdown on a panel opened many
    /// times a day is nagging, and the Ready screen and Settings both carry it
    /// where it belongs.
    @ViewBuilder
    private var licenceNotice: some View {
        if let reason = appState.licence.state.blockedReason {
            Button {
                appState.showSettings(selecting: .licence)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "key")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mfWarn)
                    Text(reason)
                        .font(.system(size: 11.5))
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Color.mfWarn.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
    }

    /// The one-off jobs behind "More": transcribing a file, and rewriting
    /// whatever is on the clipboard. Each carries its own list of profiles rather than
    /// borrowing the one dictation is set to, because the voice wanted for a
    /// single passage is rarely the voice wanted for every dictation after
    /// it, and picking one here must not quietly change that.
    private var toolsMenu: some View {
        Menu {
            Menu("Transcribe File") {
                Button("As spoken") {
                    appState.pickAudioFileForTranscription(rewrite: .asSpoken)
                }
                if !settings.rewriteProfiles.isEmpty {
                    Divider()
                    ForEach(settings.rewriteProfiles) { profile in
                        Button(profile.name) {
                            appState.pickAudioFileForTranscription(rewrite: .profile(profile.id))
                        }
                    }
                }
            }
            Menu("Rewrite Text") {
                ForEach(settings.rewriteProfiles) { profile in
                    Button(profile.name) {
                        appState.rewriteClipboardText(profileID: profile.id)
                    }
                }
            }
            .disabled(settings.rewriteProfiles.isEmpty)
        } label: {
            // Plain, at the row's own size, with no icon sizing of its own:
            // this symbol draws 14 by 14 at 12pt, the clock's exact box, so
            // it sits level with its neighbours without a number holding it
            // there. The tool symbols all needed one and still read wrong,
            // being several dense objects where the rest of the row is one
            // light shape.
            Label("More", systemImage: "ellipsis.circle")
                .font(.system(size: 12))
        }
        // Not .borderlessButton: that style hands the label to AppKit's own
        // control metrics, which size the symbol from the control rather than
        // from the view. The whole thing renders 62 by 18 under it whatever
        // the icon is set to, so every attempt to size this icon was quietly
        // discarded. Under .button with a plain button style it renders 50 by
        // 15, exactly as the Settings and History buttons beside it do.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusEffectDisabled()
        .foregroundStyle(Color.mfTextPrimary.opacity(0.85))
        .disabled(!appState.canRunTool)
        .accessibilityLabel("More actions")
        .help("Transcribe a file, or rewrite the text on the clipboard")
    }

    private var footer: some View {
        // Eight rather than twelve: four icon-and-text actions measure 279pt
        // of the 280pt this row has, and a gap that leaves one point of
        // slack is a label waiting to truncate on the first metrics change.
        HStack(spacing: 8) {
            Button {
                appState.showSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .foregroundStyle(Color.mfTextPrimary.opacity(0.85))

            Button {
                appState.showHistory()
            } label: {
                Label("History", systemImage: "clock")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .foregroundStyle(Color.mfTextPrimary.opacity(0.85))

            toolsMenu

            Spacer(minLength: 8)

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .foregroundStyle(Color.mfTextPrimary.opacity(0.85))
            .accessibilityLabel("Quit MicMyDay")
            .help("Quit MicMyDay")
        }
        // A row of actions, so a label that outgrows the fixed panel width
        // has to shorten rather than wrap the whole footer onto two lines.
        .lineLimit(1)
    }

    private var engineShortName: String {
        guard settings.provider.isLocalModel else { return settings.provider.title }
        return WhisperModelCatalog.model(withID: settings.whisperModelID)?.displayName
            ?? settings.whisperModelID
    }

    // MARK: - Shared

    private var isRecording: Bool {
        if case .recording = appState.phase { return true }
        return false
    }

    private var phaseColor: Color {
        switch appState.phase {
        case .recording: return Color.mfRecord
        case .failed: return Color.mfWarn
        case .transcribing, .enhancing, .inserting, .requestingPermission: return Color.mfAccent
        case .idle: return visiblePermissionIssue == nil ? Color.mfTextPrimary : Color.mfWarn
        }
    }
}

/// The one loop in the panel: a 1400 ms ring behind the phase glyph while the
/// microphone is live.
private struct RecordPulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(Color.mfRecord, lineWidth: 2)
            .frame(width: 26, height: 26)
            .scaleEffect(expanded ? 1.7 : 0.9)
            .opacity(expanded ? 0 : 0.55)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    expanded = true
                }
            }
    }
}

/// The profile popup, as the real AppKit control.
///
/// SwiftUI's menu-style `Picker` cannot be widened: `maxWidth` is ignored
/// entirely, and an explicit `width` only centres the intrinsically-sized
/// control inside the frame, which leaves it floating mid-row. Lowering
/// `NSPopUpButton`'s content-hugging priority is what actually makes it fill
/// the space, so the control is wrapped directly.
private struct ProfilePopUp: NSViewRepresentable {
    let profiles: [RewriteProfile]
    @Binding var selection: String

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.profiles = profiles
        context.coordinator.selection = $selection

        let titles = profiles.map(\.name)
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        if let index = profiles.firstIndex(where: { $0.id == selection }),
           button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(profiles: profiles, selection: $selection)
    }

    final class Coordinator: NSObject {
        var profiles: [RewriteProfile]
        var selection: Binding<String>

        init(profiles: [RewriteProfile], selection: Binding<String>) {
            self.profiles = profiles
            self.selection = selection
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard profiles.indices.contains(index) else { return }
            selection.wrappedValue = profiles[index].id
        }
    }
}
