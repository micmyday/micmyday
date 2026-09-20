import AppKit
import SwiftUI

// MARK: - General

struct GeneralPane: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var history: TranscriptHistory

    var body: some View {
        SettingsCard(eyebrow: "Theme") {
            // Four across, one row: the grid is the picker, so every theme is
            // visible at once rather than hidden behind a menu.
            HStack(spacing: 10) {
                ForEach(AppTheme.allCases) { theme in
                    ThemeSwatchCard(theme: theme, isSelected: settings.theme == theme) {
                        settings.theme = theme
                    }
                }
            }
        }

        // A build from source has no updater to configure; it updates by
        // being built again.
        if UpdateController.updatesItself {
            UpdatesCard(updates: appState.updates)
        }

        SettingsCard(
            eyebrow: "Startup"
        ) {
            SettingsRow(title: "Open at login", detail: "Start MicMyDay automatically when you sign in to your Mac.") {
                Toggle("", isOn: Binding(
                    get: { appState.launchAtLoginEnabled },
                    set: { appState.setLaunchAtLogin($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.mfAccent)
            }
        }


        SettingsCard(eyebrow: "Sounds") {
            SettingsRow(
                title: "Play sound cues",
                detail: "Sound cues when recording starts, during transcription, and on completion or errors."
            ) {
                Toggle("", isOn: $settings.playFeedbackSounds)
                    .labelsHidden().toggleStyle(.switch).tint(.mfAccent)
            }
        }

        SettingsCard(
            eyebrow: "History"
        ) {
            SettingsRow(
                title: "Keep recent transcripts",
                detail: "Save recent transcripts on this Mac. Turning this off deletes the saved history."
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.keepRecentTranscripts },
                    set: { settings.keepRecentTranscripts = $0; history.isPersistenceEnabled = $0 }
                ))
                .labelsHidden().toggleStyle(.switch).tint(.mfAccent)
            }
            if settings.keepRecentTranscripts {
                SettingsRow(title: "How many to keep") {
                    Picker("", selection: Binding(
                        get: { settings.historyLimit },
                        set: { settings.historyLimit = $0; history.limit = $0 }
                    )) {
                        ForEach(TranscriptHistory.selectableLimits, id: \.self) { limit in
                            Text("\(limit)").tag(limit)
                        }
                    }
                    .dsMenuPicker(width: 110)
                }
            }
            HStack {
                Text("\(history.entries.count) kept")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.42))
                Spacer()
                Button("Clear now") { history.clear() }
                    .buttonStyle(.beaconQuiet)
                    .disabled(history.entries.isEmpty)
            }
        }
    }
}

// MARK: - Voice

/// Where a finished transcript goes.
///
/// Both cards here were somewhere else. Pasting sat under General, among the
/// app's own preferences, and inserting it again sat under Rewrite, which is
/// about changing the words rather than delivering them. Delivery is a stage
/// of a dictation in its own right, and the rail now reads as those stages in
/// the order they happen.
struct OutputPane: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
SettingsCard(
            eyebrow: "After you speak"
        ) {
            SettingsRow(
                title: "Paste automatically",
                detail: "Insert finished text at the cursor in the app you were using."
            ) {
                Toggle("", isOn: $settings.automaticPasteEnabled)
                    .labelsHidden().toggleStyle(.switch).tint(.mfAccent)
            }
            if settings.automaticPasteEnabled, !appState.accessibilityGranted {
                StatusLabel(
                    text: "Allow Accessibility to paste automatically. Until then, paste with ⌘V.",
                    tone: .warn,
                    symbol: "exclamationmark.triangle"
                )
            }
            // Only meaningful when the text is actually pasted: nothing is
            // pressed when a transcript falls back to the clipboard.
            if settings.automaticPasteEnabled {
                SettingsRow(
                    title: "Key to press after pasting",
                    detail: "Choose the key MicMyDay presses after pasting. Use the send shortcut for your app."
                ) {
                    Picker("", selection: $settings.autoSendKey) {
                        ForEach(AutoSendKey.allCases) { key in Text(key.title).tag(key) }
                    }
                    .dsMenuPicker(width: 170)
                }
            }
            SettingsRow(
                title: "End with a space",
                detail: "Add a space after each transcript to separate it from the next word."
            ) {
                Toggle("", isOn: $settings.appendTrailingSpace)
                    .labelsHidden().toggleStyle(.switch).tint(.mfAccent)
            }
            SettingsRow(
                title: "Restore clipboard after pasting",
                detail: "Restore what was copied before the transcript was pasted. Turn this off to keep the transcript on the clipboard."
            ) {
                Toggle("", isOn: $settings.restoreClipboardAfterPaste)
                    .labelsHidden().toggleStyle(.switch).tint(.mfAccent)
            }
        }

SettingsCard(
            eyebrow: "Insert again",
            caption: "Insert the last transcript at your current cursor, even if the clipboard has changed."
        ) {
            InsertAgainShortcutRow()
        }
    }
}

struct VoicePane: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore
    @State private var capturing = false

    var body: some View {
        SettingsCard(
            eyebrow: "Shortcut",
            caption: capturing
                ? "Press a key combination, a function key or a single modifier such as right Shift. Press Esc to cancel."
                : nil
        ) {
            HStack(spacing: 14) {
                ShortcutRecorderView(shortcut: $settings.shortcut) { capturing = $0 }
                    .frame(width: 290)
                Spacer(minLength: 0)
                if appState.hotKeyRegistered {
                    BeaconChip(text: "Active system-wide", symbol: "checkmark.circle.fill", tone: .ready)
                } else if let error = appState.hotKeyError {
                    BeaconChip(text: error, symbol: "exclamationmark.triangle", tone: .warn)
                }
            }
        }

        SettingsCard(eyebrow: "When you press it") {
            HStack(alignment: .top, spacing: 10) {
                ForEach(ShortcutActivationMode.allCases) { mode in
                    ModeCard(mode: mode, selected: settings.shortcutMode == mode) {
                        settings.shortcutMode = mode
                    }
                }
            }
        }

        if settings.shortcutMode != .tapToggle {
            SettingsCard(
                eyebrow: "Hands-free",
                caption: "While holding the shortcut, tapping Space keeps the recording running after you let go. Space is only intercepted during the hold itself."
            ) {
                SettingsRow(title: "Tap Space while holding to go hands-free") {
                    Toggle("", isOn: $settings.spaceUpgradesHold)
                        .labelsHidden().toggleStyle(.switch).tint(.mfAccent)
                }
            }
        }

        if settings.shortcut.isModifierOnly && !appState.inputMonitoringGranted {
            SettingsCard(
                eyebrow: "Input Monitoring",
                caption: "Only needed for a modifier-only shortcut such as right Shift or Fn. A regular key combination doesn't need this permission."
            ) {
                Button("Allow Input Monitoring") { appState.requestInputMonitoringPermission() }
                    .buttonStyle(.beacon)
            }
        }

        // The pane is called Recording now, so the card takes the name of
        // what it actually holds. The anchor keeps the old word, so search
        // and the coverage tests still address the same card.
        SettingsCard(eyebrow: "Microphone", anchor: "Recording") {
            SettingsRow(title: "Microphone") {
                Picker("", selection: $settings.inputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(appState.inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .dsMenuPicker(width: 220)
            }
            if let error = appState.inputDeviceError {
                StatusLabel(text: error, tone: .warn, symbol: "exclamationmark.triangle")
            }
            SettingsRow(
                title: "Start recording when you speak",
                detail: "Start speaking to record—no shortcut needed."
            ) {
                Toggle("", isOn: $settings.voiceActivationEnabled)
                    .labelsHidden().toggleStyle(.switch).tint(.mfAccent)
            }
            // Only the failure is worth a line here. That it is listening is
            // what the toggle already says, and the menu bar shows the live
            // state anyway.
            if settings.voiceActivationEnabled, let error = appState.voiceActivationError {
                StatusLabel(text: error, tone: .warn, symbol: "exclamationmark.triangle")
            }
            SettingsRow(
                title: "Stop after silence",
                detail: "Stop after a pause when recording with the shortcut. Voice-activated recordings always stop after silence."
            ) {
                Toggle("", isOn: $settings.autoStopOnSilence)
                    .labelsHidden().toggleStyle(.switch).tint(.mfAccent)
            }
            // Voice activation uses this length too, and always: a spoken
            // phrase has to end on silence or it would never end. So the row
            // has to be reachable even when auto-stop itself is off, otherwise
            // the pause that ends a phrase has no visible control.
            if settings.autoStopOnSilence || settings.voiceActivationEnabled {
                SettingsRow(title: "Silence before stopping") {
                    Picker("", selection: $settings.silenceStopSeconds) {
                        ForEach([0.5, 0.75, 1.0, 1.5, 2.0, 2.5, 3.0], id: \.self) { value in
                            Text(String(format: "%g s", value)).tag(value)
                        }
                    }
                    .dsMenuPicker(width: 110)
                }
            }
            SettingsRow(
                title: "Mute other audio while recording",
                detail: "Audio fades out during recording and back in afterward."
            ) {
                Toggle("", isOn: $settings.duckOtherAudio)
                    .labelsHidden().toggleStyle(.switch).tint(.mfAccent)
            }
            SettingsRow(
                title: "Maximum recording",
                detail: "Set how long a recording can last before it stops automatically."
            ) {
                Stepper(
                    value: $settings.maximumRecordingSeconds,
                    in: 30...600,
                    step: 30
                ) {
                    // The label lives in the row; the stepper shows only the value.
                    Text(String(format: "%dm %02ds", settings.maximumRecordingSeconds / 60, settings.maximumRecordingSeconds % 60))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.mfTextPrimary)
                }
                .controlSize(.small)
            }
            SettingsRow(
                title: "Count down the last five seconds",
                detail: "A tick sounds each second during the final five seconds before the recording limit is reached."
            ) {
                Toggle("", isOn: $settings.countdownBeforeMaximum)
                    .labelsHidden().toggleStyle(.switch).tint(.mfAccent)
                    // Nothing to hear with the cues switched off, and a lone
                    // tick from an app that is otherwise silent would be a
                    // surprise rather than a warning.
                    .disabled(!settings.playFeedbackSounds)
            }
            if settings.countdownBeforeMaximum, !settings.playFeedbackSounds {
                StatusLabel(
                    text: "Sound cues are off under General → Sounds, so the countdown will not be heard.",
                    tone: .warn,
                    symbol: "speaker.slash"
                )
            }
        }
    }
}

private struct ModeCard: View {
    let mode: ShortcutActivationMode
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 7) {
                // The same KEY/MIC timeline the setup assistant uses: the
                // difference between how long the shortcut is held and how long
                // the microphone is actually live is the whole distinction
                // between these three modes, and it is quicker to see than read.
                PressDiagram(mode: mode, isSelected: selected)
                    .padding(.bottom, 3)
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .strokeBorder(selected ? Color.mfAccent : Color.mfFill(0.22), lineWidth: 1.5)
                            .frame(width: 13, height: 13)
                        if selected { Circle().fill(Color.mfAccent).frame(width: 6, height: 6) }
                    }
                    Text(mode.shortTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mfTextPrimary)
                }
                Text(mode.cardDetail)
                    .font(.system(size: 11))
                    .lineSpacing(2)
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.mfAccent.opacity(0.12) : Color.mfFill(0.04),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? Color.mfAccent : Color.clear, lineWidth: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The card draws its own selection, so VoiceOver otherwise announced
        // an unlabelled button with no state.
        .accessibilityLabel(mode.title)
        .accessibilityValue(mode.explanation)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .focusEffectDisabled()
    }
}

// MARK: - Rewrite

/// Mirrors onboarding chapter 6 by reusing its parts outright, so the two can
/// never drift.
struct RewritePane: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var pickerOpen = false
    /// Set when the pane opens on an already-configured provider, and when
    /// the user presses the confirm button. Without it, typing the first
    /// character of a model id collapsed the editor and persisted a partial
    /// value, because the readiness check flips as soon as the fields are
    /// non-empty.
    @State private var confirmed = false

    var body: some View {

        SettingsCard(
            eyebrow: "Rewriting",
            caption: "The selected AI model rewrites your transcript using the active profile’s instructions."
        ) {
            SettingsRow(title: "Rewrite transcripts before inserting") {
                Toggle("", isOn: $settings.enhancementEnabled)
                    .labelsHidden().toggleStyle(.switch).tint(.mfAccent)
            }
        }

        if settings.enhancementEnabled {
            if confirmed && connected && !pickerOpen {
                SettingsCard(eyebrow: "Rewrite engine") {
                    RewriteConnectedRow { pickerOpen = true }
                }
                .onAppear { if connected { confirmed = true } }
                localModelCard
                SettingsCard(eyebrow: "Profiles") {
                    RewriteProfilesSection(showsEyebrow: false)
                }
                SettingsCard(
                    eyebrow: "Edit by voice",
                    caption: "Select text, press the shortcut and say how to change it, such as “make it shorter”. MicMyDay replaces the selection with the edited text."
                ) {
                    EditSelectionShortcutRow()
                }

                SettingsCard(
                    eyebrow: "Cycle profiles",
                    caption: "Switch between rewrite profiles without starting a recording. The shortcuts wrap around at either end of the list."
                ) {
                    CycleProfileShortcutRow(title: "Next profile", shortcut: $settings.cycleProfilesShortcut)
                    CycleProfileShortcutRow(title: "Previous profile", shortcut: $settings.previousProfileShortcut)
                }

                SettingsCard(
                    eyebrow: "Profile shortcuts",
                    caption: "Start recording with a specific rewrite profile using its own shortcut."
                ) {
                    ProfileShortcutList()
                }
            } else {
                SettingsCard(eyebrow: "Rewrite engine") {
                    RewriteProviderPicker(onConnected: { confirmed = true; pickerOpen = false }, showsEyebrow: false)
                        .onAppear { if connected { confirmed = true } }
                }
                localModelCard
            }
        } else {
            SettingsCard(eyebrow: "What rewriting would do") {
                RewriteOffComparison()
            }
        }
    }

    /// Only "On this Mac" has a model to choose; every other provider chooses
    /// its model with the credential that reaches it.
    @ViewBuilder
    private var localModelCard: some View {
        if settings.rewriteProvider == .onDevice {
            SettingsCard(
                eyebrow: "Model",
                caption: "Rewrite privately on your Mac with Apple’s built-in model or a downloaded model. Downloaded models work offline."
            ) {
                LocalRewriteModelPicker()
            }
        }
    }

    private var connected: Bool {
        settings.rewriteProviderIsConfigured
    }
}

private struct CycleProfileShortcutRow: View {
    let title: String
    @Binding var shortcut: KeyboardShortcut?

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Color.mfTextPrimary)
            Spacer(minLength: 8)
            ShortcutRecorderView(
                shortcut: Binding(
                    get: { shortcut ?? KeyboardShortcut(keyCode: 0, modifiers: 0, keyLabel: "") },
                    set: { shortcut = $0 }
                ),
                allowsModifierOnly: false
            )
            .frame(width: 240)
            if shortcut != nil {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Clear shortcut")
            }
        }
    }
}

private struct EditSelectionShortcutRow: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        HStack(spacing: 12) {
            Text("Edit the selection")
                .font(.system(size: 12))
                .foregroundStyle(Color.mfTextPrimary)
            Spacer(minLength: 8)
            ShortcutRecorderView(
                shortcut: Binding(
                    get: { settings.editSelectionShortcut ?? KeyboardShortcut(keyCode: 0, modifiers: 0, keyLabel: "") },
                    set: { settings.editSelectionShortcut = $0 }
                ),
                allowsModifierOnly: false
            )
            .frame(width: 240)
            if settings.editSelectionShortcut != nil {
                Button {
                    settings.editSelectionShortcut = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Clear shortcut")
            }
        }
    }
}

private struct InsertAgainShortcutRow: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        HStack(spacing: 12) {
            Text("Insert last transcript")
                .font(.system(size: 12))
                .foregroundStyle(Color.mfTextPrimary)
            Spacer(minLength: 8)
            ShortcutRecorderView(
                shortcut: Binding(
                    get: { settings.insertAgainShortcut ?? KeyboardShortcut(keyCode: 0, modifiers: 0, keyLabel: "") },
                    set: { settings.insertAgainShortcut = $0 }
                ),
                allowsModifierOnly: false
            )
            .frame(width: 240)
            if settings.insertAgainShortcut != nil {
                Button {
                    settings.insertAgainShortcut = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Clear shortcut")
            }
        }
    }
}

private struct ProfileShortcutList: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(spacing: 10) {
            ForEach(settings.rewriteProfiles) { profile in
                HStack(spacing: 12) {
                    Text(profile.name)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mfTextPrimary)
                    Spacer(minLength: 8)
                    ShortcutRecorderView(
                        shortcut: Binding(
                            get: { settings.profileShortcuts[profile.id] ?? KeyboardShortcut(keyCode: 0, modifiers: 0, keyLabel: "") },
                            set: { settings.profileShortcuts[profile.id] = $0 }
                        ),
                        allowsModifierOnly: false
                    )
                    .frame(width: 240)
                    if settings.profileShortcuts[profile.id] != nil {
                        Button {
                            settings.profileShortcuts[profile.id] = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help("Clear shortcut")
                    }
                }
            }
        }
    }
}

// MARK: - States

/// A development aid: put the app into any phase to see what it looks like.
struct StatesPane: View {
    @EnvironmentObject private var appState: AppState

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    private var phases: [(String, AppPhase)] {
        [
            ("Idle", .idle),
            ("Recording", .recording(startedAt: Date())),
            ("Transcribing", .transcribing),
            ("Rewriting", .enhancing),
            ("Typing", .inserting),
            ("Failed", .failed(RecoveryAdvice.silence)),
        ]
    }

    var body: some View {
        SettingsCard(
            eyebrow: "Phases",
            caption: "Choose a state to preview its appearance without recording or transcribing. The next dictation returns the app to normal."
        ) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(phases, id: \.0) { name, phase in
                    Button {
                        appState.previewPhase(phase)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: phase.symbolName)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.mfAccent)
                                .frame(width: 16)
                            Text(name)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.mfTextPrimary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.mfFill(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
        }
    }
}

// MARK: - Profile icons

/// The whole curated set visible at once — 10 across, no scrolling and no
/// search, which is the point of curating it to 30 in the first place.
struct ProfileIconPicker: View {
    @EnvironmentObject private var settings: SettingsStore
    let profileID: String
    let profileName: String

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 6), count: 10)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(ProfileIcon.all) { icon in
                    let selected = settings.iconID(forProfile: profileID) == icon.id
                    Button {
                        settings.profileIcons[profileID] = icon.id
                    } label: {
                        Image(systemName: icon.symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(selected ? .white : Color.mfTextPrimary.opacity(0.62))
                            .frame(width: 30, height: 30)
                            .background(
                                selected ? Color.mfAccent : Color.mfFill(0.05),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help(icon.title)
                }
            }
            Text("Choose the icon for \(profileName) in the recording overlay.")
                .font(.system(size: 11))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
        }
    }
}

/// One theme in the picker: a miniature of the theme rather than a colour chip.
///
/// The pill is the theme's window colour carrying the two roles the recording
/// overlay uses — an accent dot and a record-coloured bar — so a theme that
/// repurposes either of them, as Indigo does with yellow, reads as different
/// here before it is selected.
private struct ThemeSwatchCard: View {
    let theme: AppTheme
    let isSelected: Bool
    let select: () -> Void

    /// A miniature of the app in this theme rather than a row of dots: its
    /// own canvas, a card sitting on it with two lines of text, and the three
    /// colours that actually carry meaning in use. The point of a theme is
    /// how those sit together, which a swatch of separate chips cannot show.
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.palette.canvas)
            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.palette.cardTint.opacity(theme.palette.cardOpacity))
                    .overlay {
                        VStack(alignment: .leading, spacing: 4) {
                            Capsule()
                                .fill(theme.palette.textPrimary.opacity(0.75))
                                .frame(width: 34, height: 3)
                            Capsule()
                                .fill(theme.palette.textPrimary.opacity(0.35))
                                .frame(width: 22, height: 3)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                    }
                    .frame(height: 28)

                HStack(spacing: 5) {
                    Capsule()
                        .fill(theme.palette.accent)
                        .frame(width: 20, height: 7)
                    Circle()
                        .fill(theme.palette.record)
                        .frame(width: 7, height: 7)
                    Circle()
                        .fill(theme.palette.ready)
                        .frame(width: 7, height: 7)
                    Spacer(minLength: 0)
                }
            }
            .padding(7)
        }
        .frame(height: 64)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.mfHairline, lineWidth: 1)
        }
    }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                preview
                HStack(spacing: 4) {
                    Text(theme.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.mfTextPrimary)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.mfAccent)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.mfAccent.opacity(0.16) : Color.mfFill(0.04))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.mfAccent : Color.mfFill(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        // The description is gone from the card but kept here: a sentence
        // about what a theme looks like is exactly what somebody who cannot
        // see the swatch needs, and it costs no room.
        .accessibilityLabel("\(theme.title). \(theme.detail)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Settings → General → Updates.
///
/// Its own view holding the updater directly: `AppState` owns the controller,
/// and a nested observable object does not republish through its parent, so a
/// card reading it through `appState` would show a toggle that never moved and
/// a button whose enabled state never changed.
private struct UpdatesCard: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        SettingsCard(eyebrow: "Updates") {
            SettingsRow(
                title: "Check automatically",
                detail: "Check for new versions in the background. Current version: \(UpdateController.currentVersion)."
            ) {
                Toggle("", isOn: $updates.automaticallyChecks)
                    .labelsHidden().toggleStyle(.switch).tint(.mfAccent)
            }
            SettingsRow(title: "Check now") {
                Button("Check for Updates") { updates.checkForUpdates() }
                    .buttonStyle(.beaconQuiet)
                    .disabled(!updates.canCheck)
            }
        }
    }
}
