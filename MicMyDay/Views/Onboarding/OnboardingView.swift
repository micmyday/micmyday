import SwiftUI

/// First-run setup, built to `Assets/Design/export/design/OnboardingBeacon.dc.html`.
///
/// Eight chapters in a 288pt rail plus content. The rail doubles as a receipt:
/// every visited chapter shows what was chosen, so the flow can be re-entered
/// anywhere without hunting for what a screen decided.
struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore
    /// Observed so the footer's "Downloading… 62%" label actually refreshes;
    /// reading the shared manager without observing it left the button frozen
    /// at the value it happened to have on first render.
    @ObservedObject private var whisperModels = WhisperModelManager.shared

    @State private var chapter: Chapter = .access
    @State private var furthest = 0
    /// Where setup had got to, remembered across a quit.
    ///
    /// The Accessibility permission can only be picked up by restarting, and
    /// the assistant itself offers to do that. Coming back to the first page
    /// makes the restart feel like a punishment and invites the user to redo
    /// the steps they had already finished.
    @AppStorage("onboardingChapter") private var resumeChapter = 0
    /// Set when the footer started the download, so "Download and continue"
    /// keeps the second half of its promise once the file has landed.
    @State private var advanceAfterDownload = false
    @State private var shortcutCapturing = false
    @State private var launchAtLogin = true

    let finish: () -> Void

    /// Numbered by position, so the rail always reads 01 upward however
    /// many chapters there are.
    enum Chapter: Int, CaseIterable, Identifiable {
        case access, engine, setup, voice, rewrite, profiles, overlay, ready
        var id: Int { rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            content
        }
        .frame(width: 960, height: 750)
        .background(Color.mfCanvas)
        .preferredColorScheme(.dark)
        // Polling is tied to the window lifecycle in AppState: onDisappear
        // never fires inside the retained window, so it cannot balance a
        // start here.
        .onAppear {
            if settings.onboardingCompleted { launchAtLogin = appState.launchAtLoginEnabled }
            restoreChapter()
        }
        .onChange(of: setupSatisfied) { _, satisfied in
            guard satisfied, advanceAfterDownload, chapter == .setup else { return }
            advanceAfterDownload = false
            advance()
        }
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 48pt title-bar strip; the traffic lights are the real ones.
            Spacer().frame(height: 48)

            // The mark and the name, rather than one wide lockup bitmap: the
            // wordmark stays crisp at any size, takes the theme's text colour,
            // and cannot fall out of step with the app's name again.
            HStack(spacing: 10) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                Wordmark(size: 22)
            }
            .padding(.leading, 24)
            .padding(.trailing, 24)
            .padding(.bottom, 24)

            progressBlock

            VStack(spacing: 0) {
                ForEach(Chapter.allCases) { candidate in
                    ChapterRow(
                        number: candidate.rawValue + 1,
                        label: label(for: candidate),
                        summary: summary(for: candidate),
                        state: state(for: candidate)
                    ) {
                        go(to: candidate)
                    }
                }
            }

            Spacer()

            Text("Everything here can be changed later in Settings.")
                .font(.system(size: 11))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.28))
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
        }
        .frame(width: 288, alignment: .leading)
        .background {
            // A 360pt amber circle whose top-left sits at (-90, -130), so its
            // centre lands at (90, 50): behind the logo, not the middle of the
            // rail.
            //
            // The glow must be an OVERLAY on the fill rather than a ZStack
            // sibling: a ZStack sizes to its largest child, so the 360pt circle
            // made the background measure 360 wide and bleed past the rail's
            // 288pt divider. An overlay never affects layout, so the clip below
            // lands on the rail's real width, matching overflow:hidden.
            Color.mfCanvasDeep
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(
                            RadialGradient(
                                stops: [
                                    .init(color: Color.mfAccent.opacity(0.3), location: 0),
                                    .init(color: Color.mfReady.opacity(0.10), location: 0.45),
                                    .init(color: Color.mfAccent.opacity(0), location: 0.72),
                                ],
                                center: .center,
                                startRadius: 0,
                                // CSS radial-gradient defaults to farthest-corner,
                                // so 100% is the corner distance of the 360pt box
                                // (180·√2 ≈ 254.6), not its half-width.
                                endRadius: 180 * 1.41421356
                            )
                        )
                        .frame(width: 360, height: 360)
                        .offset(x: -90, y: -130)
                }
                .clipped()
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.mfFill(0.06))
                .frame(width: 1)
        }
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("FIRST-RUN SETUP")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
                Spacer()
                Text("\(chapter.rawValue + 1) / \(Chapter.allCases.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.mfAccent)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.mfFill(0.08))
                    Capsule()
                        .fill(Color.mfAccent)
                        .frame(width: geo.size.width * Double(chapter.rawValue + 1) / Double(Chapter.allCases.count))
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .animation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.35), value: chapter)
    }

    private func state(for candidate: Chapter) -> ChapterRow.RowState {
        if candidate == chapter { return .current }
        return candidate.rawValue <= furthest ? .visited : .locked
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                chapterBody
                    .padding(.horizontal, 44)
                    .padding(.top, 44)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(chapter)
                    .transition(.beaconRise)
            }
            .animation(.timingCurve(0.2, 0, 0, 1, duration: 0.30), value: chapter)

            // The finish chapter owns its own CTA.
            if chapter != .ready {
                footer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if chapter != .access {
                Button("Back") { back() }
                    .buttonStyle(.beaconQuiet)
            }
            Spacer(minLength: 0)
            Button {
                if needsModelDownload { startSelectedModelDownload() } else { advance() }
            } label: {
                Text(primaryLabel)
            }
            .buttonStyle(.beaconLarge)
            .disabled(!canAdvance && !needsModelDownload)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 44)
        .padding(.top, 18)
        .padding(.bottom, 26)
    }

    // MARK: - Navigation

    private func go(to destination: Chapter) {
        guard destination.rawValue <= furthest || destination == chapter else { return }
        chapter = destination
        furthest = max(furthest, destination.rawValue)
    }

    private func back() {
        guard let previous = Chapter(rawValue: chapter.rawValue - 1) else { return }
        chapter = previous
    }


    private func advance() {
        guard let next = Chapter(rawValue: chapter.rawValue + 1) else { return }
        chapter = next
        furthest = max(furthest, next.rawValue)
        resumeChapter = next.rawValue
    }

    /// Picks up where the last run left off, and never moves backwards past
    /// a chapter that has already been passed.
    private func restoreChapter() {
        // Only while setup is unfinished. Closing the assistant counts as
        // finishing it but leaves the last chapter recorded, so without this
        // somebody opening it again from the menu bar to look through it was
        // dropped back where they had stopped rather than at the beginning.
        guard !settings.onboardingCompleted else { return }
        guard let saved = Chapter(rawValue: resumeChapter), saved.rawValue > chapter.rawValue else { return }
        chapter = saved
        furthest = max(furthest, saved.rawValue)
    }

    func complete() {
        // Setup is over; nothing left to resume.
        resumeChapter = 0
        if launchAtLogin != appState.launchAtLoginEnabled {
            appState.setLaunchAtLogin(launchAtLogin)
        }
        finish()
    }

    // MARK: - Rail copy
    //
    // Chapter 4 renames itself after what the chosen engine actually needs.

    private func label(for candidate: Chapter) -> String {
        switch candidate {
        case .access: return SettingsPane.permissions.title
        case .engine: return SettingsPane.engine.title
        case .setup: return setupLabel
        case .voice: return SettingsPane.voice.title
        case .rewrite: return "Rewrite"
        case .profiles: return "Profiles"
        case .overlay: return "Overlay"
        case .ready: return "Ready"
        }
    }

    private var setupLabel: String {
        switch settings.provider {
        case .whisper, .parakeet, .nemotron: return "Model"
        case .openAI, .gemini: return "API key"
        case .custom: return "Server"
        case .appleSpeech: return "Options"
        }
    }

    /// The rail is a receipt — but never for the chapter you are standing on.
    private func summary(for candidate: Chapter) -> String? {
        guard candidate != chapter, candidate.rawValue <= furthest else { return nil }
        switch candidate {
        case .access:
            var granted: [String] = []
            if appState.microphoneGranted { granted.append("Mic") }
            if appState.speechGranted { granted.append("speech") }
            if appState.accessibilityGranted { granted.append("auto-paste") }
            return granted.isEmpty ? "Nothing granted yet" : granted.joined(separator: ", ")
        case .engine:
            return settings.provider.title
        case .setup:
            return setupSummary
        case .voice:
            return "\(settings.shortcut.displayString) \u{00B7} \(settings.shortcutMode.shortTitle)"
        case .rewrite:
            guard settings.enhancementEnabled else { return "Off \u{2014} no AI rewriting" }
            let profile = settings.currentRewriteProfile
            return "\(profile?.name ?? "Rewrite") \u{00B7} \(settings.rewriteProvider.title)"
        case .profiles:
            guard settings.enhancementEnabled else { return nil }
            return settings.currentRewriteProfile?.name
        case .overlay:
            guard settings.overlayEnabled else { return "Off" }
            return settings.overlayStyle == .dock
                ? "Dock \u{00B7} \(settings.overlayDockStyle.title)"
                : "Pill \u{00B7} \(settings.overlaySize.title)"
        case .ready:
            return nil
        }
    }

    private var setupSummary: String? {
        switch settings.provider {
        case .whisper, .parakeet, .nemotron:
            guard let model = WhisperModelCatalog.model(withID: settings.whisperModelID) else { return nil }
            return "\(model.displayName) \u{00B7} \(model.approximateSizeMB) MB"
        case .openAI:
            return "API key"
        case .custom:
            return settings.customBaseURL.isEmpty ? nil : settings.customBaseURL
        case .appleSpeech:
            return settings.preferOnDevice ? "On this Mac only" : "Cloud processing allowed"
        case .gemini:
            return "API key"
        }
    }

    // MARK: - Gating

    private var canAdvance: Bool {
        switch chapter {
        case .access:
            // All three, not just the microphone. Half-granted permissions
            // produce failures much later and far from their cause: a
            // dictation that lands on the clipboard instead of in the
            // document, or an engine that cannot start.
            return appState.microphoneGranted
                && appState.speechGranted
                && appState.accessibilityGranted
        case .setup:
            return setupSatisfied
        default:
            return true
        }
    }

    /// True when the chapter is waiting for the chosen local model to be
    /// fetched, and nothing is downloading yet.
    ///
    /// Picking a model in the list only selects it; the footer is what starts
    /// the download, so choosing one to read its description no longer commits
    /// to several hundred megabytes.
    private var needsModelDownload: Bool {
        guard chapter == .setup, settings.provider.isLocalModel else { return false }
        guard !WhisperModelManager.isInstalled(modelID: settings.whisperModelID) else { return false }
        return whisperModels.downloadProgress[settings.whisperModelID] == nil
    }

    private func startSelectedModelDownload() {
        guard let model = WhisperModelCatalog.model(withID: settings.whisperModelID) else { return }
        // The label promises both, so the chapter moves on by itself once the
        // file has landed.
        advanceAfterDownload = true
        whisperModels.download(model)
    }

    private var setupSatisfied: Bool {
        switch settings.provider {
        case .whisper, .parakeet, .nemotron:
            return WhisperModelManager.isInstalled(modelID: settings.whisperModelID)
        case .openAI:
            return !settings.openAIApiKey.trimmingCharacters(in: .whitespaces).isEmpty
        case .gemini:
            return !settings.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && GeminiModelCatalog.model(withID: settings.geminiModel) != nil
        case .custom:
            return !settings.customBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
        case .appleSpeech:
            return true
        }
    }

    /// Nothing is a dead end: a blocked button says what is missing.
    private var primaryLabel: String {
        switch chapter {
        case .access:
            if !appState.microphoneGranted { return "Allow the microphone to continue" }
            if !appState.speechGranted { return "Allow speech recognition to continue" }
            if appState.accessibilityAllowedPendingRestart { return "Restart to finish" }
            if !appState.accessibilityGranted { return "Allow accessibility to continue" }
            return "Continue"
        case .engine:
            switch settings.provider {
            case .whisper, .parakeet, .nemotron: return "Pick a model"
            case .openAI, .gemini: return "Add an API key"
            case .custom: return "Connect your server"
            case .appleSpeech: return "Continue"
            }
        case .setup:
            if setupSatisfied { return "Continue" }
            switch settings.provider {
            case .whisper, .parakeet, .nemotron:
                // The selected model's progress, not an arbitrary one: several
                // downloads can be in flight at once.
                if let progress = whisperModels.downloadProgress[settings.whisperModelID] {
                    return "Downloading\u{2026} \(Int(progress * 100))%"
                }
                if let other = whisperModels.downloadProgress.values.max() {
                    return "Downloading\u{2026} \(Int(other * 100))%"
                }
                return "Download and continue"
            case .openAI: return "Paste an API key to continue"
            case .custom: return "Enter a server URL to continue"
            default: return "Add a credential to continue"
            }
        case .voice:
            return "Continue"
        case .rewrite:
            if !settings.enhancementEnabled { return "Skip rewriting" }
            return rewriteConnected ? "Continue" : "Continue without rewriting"
        case .profiles:
            return "Continue"
        case .overlay:
            return "Continue"
        case .ready:
            return "Continue"
        }
    }

    private var rewriteConnected: Bool {
        settings.rewriteProviderIsConfigured
    }

    // MARK: - Chapters

    @ViewBuilder
    private var chapterBody: some View {
        switch chapter {
        case .access: AccessChapter()
        case .engine: EngineChapter()
        case .setup: SetupChapter()
        case .voice: VoiceChapter(capturing: $shortcutCapturing)
        case .rewrite: RewriteChapter()
        case .profiles: ProfilesChapter()
        case .overlay: OverlayChapter()
        case .ready: ReadyChapter(launchAtLogin: $launchAtLogin, start: complete)
        }
    }
}

/// One row of the chapter rail.
struct ChapterRow: View {
    let number: Int
    let label: String
    let summary: String?
    let state: RowState
    let action: () -> Void

    enum RowState { case visited, current, locked }

    init(number: Int, label: String, summary: String?, state: RowState, action: @escaping () -> Void) {
        self.number = number
        self.label = label
        self.summary = summary
        self.state = state
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Text(String(format: "%02d", number))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.44)
                    .foregroundStyle(numberColor)
                    .frame(width: 34, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(-0.14)
                        .foregroundStyle(labelColor)
                    if let summary {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            // An overlay, not a sibling: a Rectangle in the row's HStack has no
            // intrinsic height and stretched every row to fill the rail.
            // Inset 8pt top and bottom, per the design.
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 2,
                    topTrailingRadius: 2,
                    style: .continuous
                )
                .fill(state == .current ? Color.mfAccent : Color.clear)
                .frame(width: 2)
                .padding(.vertical, 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(state == .locked)
    }

    private var numberColor: Color {
        switch state {
        case .current: return .mfAccent
        case .visited: return .mfTextPrimary.opacity(0.4)
        case .locked: return .mfTextPrimary.opacity(0.22)
        }
    }

    private var labelColor: Color {
        switch state {
        case .current: return .mfTextPrimary
        case .visited: return .mfTextPrimary.opacity(0.62)
        case .locked: return .mfTextPrimary.opacity(0.3)
        }
    }
}

/// 300 ms fade with an 8 px rise. The only transition in the flow.
extension AnyTransition {
    static var beaconRise: AnyTransition {
        .modifier(
            active: BeaconRiseModifier(offset: 8, opacity: 0),
            identity: BeaconRiseModifier(offset: 0, opacity: 1)
        )
    }
}

private struct BeaconRiseModifier: ViewModifier {
    let offset: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.offset(y: offset).opacity(opacity)
    }
}
