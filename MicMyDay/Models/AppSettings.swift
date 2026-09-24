import AppKit
import Carbon
import Foundation
import Security

enum TranscriptionProviderKind: String, CaseIterable, Identifiable {
    case appleSpeech
    /// The three local engines were one entry, "Local Whisper & Parakeet",
    /// fronting a single list of every downloadable model. Choosing an engine
    /// is a real decision, and hiding it behind one name made the list long
    /// enough to scroll while saying nothing about which models belong
    /// together. Whisper keeps the old stored value so a setup that already
    /// chose it is unaffected; anyone whose selected model belongs to another
    /// engine is moved to it on the next launch.
    case whisper = "localWhisper"
    case parakeet
    case nemotron
    case openAI
    case gemini
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleSpeech: return "Apple Speech"
        case .whisper: return "Whisper"
        case .parakeet: return "Parakeet"
        case .nemotron: return "Nemotron"
        case .openAI: return "OpenAI API"
        case .gemini: return "Gemini API"
        case .custom: return "Custom"
        }
    }

    /// The hosted endpoint, for providers MicMyDay talks to over the
    /// OpenAI-compatible transcription API. Single source of truth: the key
    /// entry UI and `transcriptionConfiguration()` both read it, and used to
    /// keep their own copies that could drift apart.
    var transcriptionBaseURL: String? {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .gemini: return GeminiAPI.baseURL
        case .appleSpeech, .whisper, .parakeet, .nemotron, .custom: return nil
        }
    }

    /// Preselected when a key is first validated.
    var defaultTranscriptionModel: String? {
        switch self {
        case .openAI: return "gpt-transcribe"
        case .gemini: return GeminiModelCatalog.defaultModelID
        case .appleSpeech, .whisper, .parakeet, .nemotron, .custom: return nil
        }
    }

    /// The three engines that run on this Mac, and which one a provider means.
    /// Most code that used to ask "is this localWhisper" meant one or the
    /// other of these, and the two questions had been the same question.
    var localEngine: LocalModelEngine? {
        switch self {
        case .whisper: return .whisper
        case .parakeet: return .parakeet
        case .nemotron: return .nemotron
        default: return nil
        }
    }

    var isLocalModel: Bool { localEngine != nil }

    /// Remote providers that require an API key.
    var requiresAPIKey: Bool {
        switch self {
        case .openAI, .gemini: return true
        case .appleSpeech, .whisper, .parakeet, .nemotron, .custom: return false
        }
    }
}

enum ShortcutActivationMode: String, CaseIterable, Identifiable {
    /// Tap toggles; holding past a threshold turns the press into push-to-talk.
    case tapAndHold
    case tapToggle
    case holdToRecord

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tapAndHold: return "Tap to toggle, hold for push-to-talk"
        case .tapToggle: return "Tap to toggle"
        case .holdToRecord: return "Hold to record (push-to-talk)"
        }
    }

    var explanation: String {
        switch self {
        case .tapAndHold:
            return "A quick tap starts and stops recording; holding the shortcut records only while it is held."
        case .tapToggle:
            return "Press once to start recording and again to stop. Releasing the keys has no effect."
        case .holdToRecord:
            return "Recording runs only while the shortcut is held down and stops the moment you release it."
        }
    }

    /// Compact form for the rail receipt: "⌃⌥Space · Tap or hold".
    var shortTitle: String {
        switch self {
        case .tapAndHold: return "Tap or hold"
        case .tapToggle: return "Tap"
        case .holdToRecord: return "Hold"
        }
    }

    var cardDetail: String {
        switch self {
        case .tapAndHold: return "A quick tap starts and stops; holding records only while held."
        case .tapToggle: return "Press once to start, again to stop."
        case .holdToRecord: return "Records only while the shortcut is held."
        }
    }
}

struct KeyboardShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String

    static let `default` = KeyboardShortcut(
        keyCode: 60,
        modifiers: 0,
        keyLabel: "Right ⇧"
    )

    /// Key codes of the modifier keys themselves, for shortcuts that consist
    /// of a single modifier (e.g. tapping right ⇧). Carbon cannot register
    /// those; HotKeyManager watches flagsChanged events instead.
    /// Control-Option-Command-V. Key code 9 is V.
    ///
    /// Next to the paste everyone knows, so it reads as "paste, but the
    /// dictation" — but with all three modifiers, because a global hotkey
    /// swallows its combination system-wide and the two-modifier variants are
    /// spoken for: one is the system file manager's move command, another is
    /// paste-and-match-style. Changeable, and clearable.
    static let insertAgainDefault = KeyboardShortcut(
        keyCode: 9,
        modifiers: UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey),
        keyLabel: "V"
    )

    /// Control-Option-Command-Right Arrow switches to the next rewrite profile.
    ///
    /// Three modifiers rather than one, and the same three that insert again
    /// uses above. Shift-Arrow was the wrong thing to take: it selects text in
    /// every writing app there is, which is precisely where somebody is
    /// standing when they reach for a different profile. A shortcut that
    /// arrives mid-sentence and eats a selection is worse than no shortcut.
    static let cycleProfilesDefault = KeyboardShortcut(
        keyCode: UInt32(kVK_RightArrow),
        modifiers: UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey),
        keyLabel: "→"
    )

    /// Control-Option-Command-Left Arrow switches to the previous one.
    static let previousProfileDefault = KeyboardShortcut(
        keyCode: UInt32(kVK_LeftArrow),
        modifiers: UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey),
        keyLabel: "←"
    )

    static let modifierKeyCodes: Set<UInt32> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    var isModifierOnly: Bool {
        modifiers == 0 && Self.modifierKeyCodes.contains(keyCode)
    }

    var displayString: String {
        var pieces: [String] = []
        if modifiers & UInt32(controlKey) != 0 { pieces.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { pieces.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { pieces.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { pieces.append("⌘") }
        pieces.append(keyLabel)
        return pieces.joined()
    }
}

struct TranscriptionConfiguration {
    let provider: TranscriptionProviderKind
    let baseURL: String
    let model: String
    let apiKey: String
    let language: String
    let prompt: String
    let preferOnDevice: Bool
    var localModelURL: URL?
}

@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let provider = "provider"
        static let openAIModel = "openAIModel"
        static let geminiModel = "geminiModel"
        static let whisperModelID = "whisperModelID"
        static let localRewriteModelID = "localRewriteModelID"
        static let restoreClipboardAfterPaste = "restoreClipboardAfterPaste"
        static let enhancementEnabled = "enhancementEnabled"
        static let enhancementBaseURL = "enhancementBaseURL"
        static let enhancementModel = "enhancementModel"
        static let customBaseURL = "customBaseURL"
        static let customModel = "customModel"
        static let language = "language"
        static let prompt = "prompt"
        static let preferOnDevice = "preferOnDevice"
        static let appendTrailingSpace = "appendTrailingSpace"
        static let playFeedbackSounds = "playFeedbackSounds"
        static let legacyPlayCompletionSound = "playCompletionSound"
        static let maximumRecordingSeconds = "maximumRecordingSeconds"
        static let voiceActivationEnabled = "voiceActivationEnabled"
        static let autoStopOnSilence = "autoStopOnSilence"
        static let silenceStopSeconds = "silenceStopSeconds"
        static let onboardingCompleted = "onboardingCompleted"
        static let shortcut = "shortcut"
        static let shortcutMode = "shortcutMode"
        static let inputDeviceUID = "inputDeviceUID"
        static let coachingTipsCompleted = "coachingTipsCompleted"
        static let rewriteProvider = "rewriteProvider"
        static let rewriteProfiles = "rewriteProfiles"
        static let rewriteProfileID = "rewriteProfileID"
        static let rewritePrompts = "rewritePrompts"
        static let rewriteCustomHeaders = "rewriteCustomHeaders"
        static let profileShortcuts = "profileShortcuts"
        static let rewriteProviderModels = "rewriteProviderModels"
        static let customModelManualEntry = "customModelManualEntry"
        static let rewriteModelManualEntry = "rewriteModelManualEntry"
        static let keepRecentTranscripts = "keepRecentTranscripts"
        static let cycleProfilesShortcut = "cycleProfilesShortcut"
        static let cycleProfilesShortcutCleared = "cycleProfilesShortcutCleared"
        static let previousProfileShortcut = "previousProfileShortcut"
        static let previousProfileShortcutCleared = "previousProfileShortcutCleared"
        static let editSelectionShortcut = "editSelectionShortcut"
        static let insertAgainShortcut = "insertAgainShortcut"
        static let insertAgainShortcutCleared = "insertAgainShortcutCleared"
        static let overlayEnabled = "overlayEnabled"
        static let overlayStyle = "overlayStyle"
        static let overlayDockStyle = "overlayDockStyle"
        static let overlayElapsedLine = "overlayElapsedLine"
        static let countdownBeforeMaximum = "countdownBeforeMaximum"
        static let overlaySize = "overlaySize"
        static let duckOtherAudio = "duckOtherAudio"
        static let overlayPosition = "overlayPosition"
        static let overlayOpacity = "overlayOpacity"
        static let overlayLivePreview = "overlayLivePreview"
        static let spaceUpgradesHold = "spaceUpgradesHold"
        static let profileIcons = "profileIcons"
        static let profileAutoSend = "profileAutoSend"
        static let autoSendKey = "autoSendKey"
        static let textReplacements = "textReplacements"
        static let removeFillerWords = "removeFillerWords"
        static let requireVoiceActivity = "requireVoiceActivity"
        static let fillerWords = "fillerWords"
        static let historyLimit = "historyLimit"
        static let streamingMode = "streamingMode"
        static let theme = "theme"
        static let automaticPaste = "automaticPaste"
    }

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    @Published var provider: TranscriptionProviderKind {
        didSet {
            // Switching engine leaves the old engine's model selected, which
            // would show a list with nothing chosen in it and transcribe with
            // something the list does not offer. Fall to that engine's own
            // recommendation instead.
            if let engine = provider.localEngine,
               WhisperModelCatalog.model(withID: whisperModelID)?.engine != engine,
               let replacement = WhisperModelCatalog.models.first(where: { $0.engine == engine && $0.isRecommended })
                   ?? WhisperModelCatalog.models.first(where: { $0.engine == engine }) {
                whisperModelID = replacement.id
            }
            defaults.set(provider.rawValue, forKey: Key.provider)
        }
    }

    @Published var openAIModel: String {
        didSet { defaults.set(openAIModel, forKey: Key.openAIModel) }
    }

    @Published var geminiModel: String {
        didSet { defaults.set(geminiModel, forKey: Key.geminiModel) }
    }

    @Published var geminiAPIKey: String {
        didSet { try? keychain.set(geminiAPIKey, account: "gemini-api-key") }
    }

    @Published var customBaseURL: String {
        didSet { defaults.set(customBaseURL, forKey: Key.customBaseURL) }
    }

    @Published var customModel: String {
        didSet { defaults.set(customModel, forKey: Key.customModel) }
    }

    @Published var openAIApiKey: String {
        didSet { try? keychain.set(openAIApiKey, account: "openai-api-key") }
    }

    @Published var whisperModelID: String {
        didSet { defaults.set(whisperModelID, forKey: Key.whisperModelID) }
    }

    /// Which model rewrites when the provider is "On this Mac": Apple's
    /// built-in one, or a downloaded GGUF run by llama.cpp.
    @Published var localRewriteModelID: String {
        didSet { defaults.set(localRewriteModelID, forKey: Key.localRewriteModelID) }
    }

    /// Puts back whatever was on the clipboard before a dictation borrowed it.
    ///
    /// On by default: pasting is how the text is delivered, but the clipboard
    /// is the user's, and quietly keeping whatever they had copied is the kind
    /// of small theft that is noticed only when something is already lost.
    @Published var restoreClipboardAfterPaste: Bool {
        didSet { defaults.set(restoreClipboardAfterPaste, forKey: Key.restoreClipboardAfterPaste) }
    }

    @Published var enhancementEnabled: Bool {
        didSet { defaults.set(enhancementEnabled, forKey: Key.enhancementEnabled) }
    }

    @Published var enhancementBaseURL: String {
        didSet { defaults.set(enhancementBaseURL, forKey: Key.enhancementBaseURL) }
    }

    @Published var enhancementModel: String {
        didSet { defaults.set(enhancementModel, forKey: Key.enhancementModel) }
    }

    @Published var enhancementAPIKey: String {
        didSet { try? keychain.set(enhancementAPIKey, account: "rewrite-\(rewriteProvider.rawValue)-api-key") }
    }

    @Published var customAPIToken: String {
        didSet { try? keychain.set(customAPIToken, account: "custom-api-token") }
    }

    @Published var language: String {
        didSet { defaults.set(language, forKey: Key.language) }
    }

    @Published var prompt: String {
        didSet { defaults.set(prompt, forKey: Key.prompt) }
    }

    @Published var preferOnDevice: Bool {
        didSet { defaults.set(preferOnDevice, forKey: Key.preferOnDevice) }
    }

    @Published var appendTrailingSpace: Bool {
        didSet { defaults.set(appendTrailingSpace, forKey: Key.appendTrailingSpace) }
    }

    @Published var playFeedbackSounds: Bool {
        didSet { defaults.set(playFeedbackSounds, forKey: Key.playFeedbackSounds) }
    }

    @Published var maximumRecordingSeconds: Int {
        didSet { defaults.set(maximumRecordingSeconds, forKey: Key.maximumRecordingSeconds) }
    }

    @Published var voiceActivationEnabled: Bool {
        didSet { defaults.set(voiceActivationEnabled, forKey: Key.voiceActivationEnabled) }
    }

    /// Applies to shortcut-started recordings; voice-activated recordings
    /// always stop on silence.
    @Published var autoStopOnSilence: Bool {
        didSet { defaults.set(autoStopOnSilence, forKey: Key.autoStopOnSilence) }
    }

    /// How long a pause must last before the message counts as finished.
    /// Shared by auto-stop and voice activation.
    @Published var silenceStopSeconds: Double {
        didSet { defaults.set(silenceStopSeconds, forKey: Key.silenceStopSeconds) }
    }

    @Published var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }

    @Published var shortcutMode: ShortcutActivationMode {
        didSet { defaults.set(shortcutMode.rawValue, forKey: Key.shortcutMode) }
    }

    @Published var shortcut: KeyboardShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(shortcut) {
                defaults.set(data, forKey: Key.shortcut)
            }
        }
    }

    /// Empty means "follow the current macOS default input device."
    @Published var inputDeviceUID: String {
        didSet { defaults.set(inputDeviceUID, forKey: Key.inputDeviceUID) }
    }

    /// The three first-dictation tips are shown once per install.
    @Published var coachingTipsCompleted: Bool {
        didSet { defaults.set(coachingTipsCompleted, forKey: Key.coachingTipsCompleted) }
    }

    // MARK: - Rewriting
    //
    // Which model rewrites transcripts, under which named prompt. Deliberately
    // separate from the transcription provider: one turns audio into text, the
    // other rewrites the text, and they are rarely the same vendor.

    @Published var rewriteProvider: RewriteProviderKind {
        didSet {
            defaults.set(rewriteProvider.rawValue, forKey: Key.rewriteProvider)
            guard oldValue != rewriteProvider else { return }
            // Never send a key for one provider to another provider.
            try? keychain.set(enhancementAPIKey, account: "rewrite-\(oldValue.rawValue)-api-key")
            enhancementAPIKey = (try? keychain.get(account: "rewrite-\(rewriteProvider.rawValue)-api-key")) ?? ""
        }
    }

    @Published var rewriteProfiles: [RewriteProfile] {
        didSet {
            if let data = try? JSONEncoder().encode(rewriteProfiles) {
                defaults.set(data, forKey: Key.rewriteProfiles)
            }
        }
    }

    /// The profile whose prompt is sent with the next dictation.
    @Published var rewriteProfileID: String {
        didSet { defaults.set(rewriteProfileID, forKey: Key.rewriteProfileID) }
    }

    /// Edited prompts, keyed by profile id. A profile absent from this map is
    /// still using its stock prompt, which is what makes "Reset to default"
    /// and the "edited" marker possible.
    @Published var rewritePrompts: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(rewritePrompts) {
                defaults.set(data, forKey: Key.rewritePrompts)
            }
        }
    }

    /// Extra headers for a self-hosted rewrite endpoint. Values are secrets in
    /// practice, so they are masked in the UI.
    @Published var rewriteCustomHeaders: [CustomHeader] {
        didSet {
            if let data = try? JSONEncoder().encode(rewriteCustomHeaders),
               let encoded = String(data: data, encoding: .utf8) {
                do {
                    try keychain.set(encoded, account: "rewrite-custom-headers")
                    defaults.removeObject(forKey: Key.rewriteCustomHeaders)
                } catch {
                    // Keep the in-memory value; don't fall back to plaintext.
                }
            }
        }
    }

    /// Set once the user signs in with OpenAI. One account serves both
    /// transcription and rewriting — the flow must never ask twice.
    /// One shortcut per rewrite profile, keyed by profile id. Pressing one
    /// records and rewrites with that profile in a single press, so switching
    /// profile never needs the panel.
    @Published var profileShortcuts: [String: KeyboardShortcut] {
        didSet {
            if let data = try? JSONEncoder().encode(profileShortcuts) {
                defaults.set(data, forKey: Key.profileShortcuts)
            }
        }
    }

    func shortcut(forProfile id: String) -> KeyboardShortcut? { profileShortcuts[id] }

    /// The rewrite model chosen per provider, keyed by provider raw value.
    /// Falls back to the provider's `defaultModel` until the user picks one.
    @Published var rewriteProviderModels: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(rewriteProviderModels) {
                defaults.set(data, forKey: Key.rewriteProviderModels)
            }
        }
    }

    /// Whether a finished transcript is pasted into the app you were last in.
    ///
    /// On by default: dictating straight into whatever you were writing is the
    /// point of the app. Turning it off keeps the transcript on the clipboard
    /// for a manual paste, which is also what happens when the Accessibility
    /// permission is missing.
    @Published var automaticPasteEnabled: Bool {
        didSet { defaults.set(automaticPasteEnabled, forKey: Key.automaticPaste) }
    }

    /// Which of the four looks the app draws with.
    @Published var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: Key.theme)
            Self.apply(theme)
        }
    }

    /// Publishes the active theme so windows can be rebuilt when it changes.
    ///
    /// The colour tokens are plain static properties that SwiftUI cannot
    /// observe, so a view tree tagged with this identity is discarded and
    /// rebuilt rather than left showing the previous theme's colours.
    var themeIdentity: String { theme.rawValue }

    /// Points the runtime and AppKit at a theme.
    ///
    /// The appearance matters as much as the palette: without it the light
    /// theme keeps dark scroll bars, menus and text cursors, because those are
    /// drawn by the system rather than by the app's own colours.
    static func apply(_ theme: AppTheme) {
        ThemeRuntime.current = theme
        NSApp?.appearance = NSAppearance(named: theme.isLight ? .aqua : .darkAqua)
    }

    /// Whether whatever else is playing is faded down while you dictate.
    ///
    /// On by default: dictating over music is something nobody wants, and the
    /// volume is restored on every path out of recording, so the cost of being
    /// wrong is one toggle rather than a setting the user has to discover.
    @Published var duckOtherAudio: Bool {
        didSet { defaults.set(duckOtherAudio, forKey: Key.duckOtherAudio) }
    }

    /// Whether and how a transcript appears while it is still arriving.
    @Published var streamingMode: StreamingMode {
        didSet { defaults.set(streamingMode.rawValue, forKey: Key.streamingMode) }
    }

    /// The mode actually in force: engines that cannot stream fall back to off
    /// no matter what is stored, so switching engine never silently changes
    /// what happens to your text.
    var effectiveStreamingMode: StreamingMode {
        provider.supportsStreamingTranscription ? streamingMode : .off
    }

    /// How many transcripts the in-memory history keeps.
    @Published var historyLimit: Int {
        didSet { defaults.set(historyLimit, forKey: Key.historyLimit) }
    }

    /// Find-and-replace rules applied to every finished transcript, before any
    /// rewrite so the model sees corrected text.
    @Published var textReplacements: [TextReplacement] {
        didSet {
            if let data = try? JSONEncoder().encode(textReplacements) {
                defaults.set(data, forKey: Key.textReplacements)
            }
        }
    }

    /// Whether a take is checked for a human voice before it is transcribed.
    ///
    /// Transcription models cannot answer "nothing was said": handed silence
    /// they return a plausible guess, which is why a take nobody spoke into
    /// comes back as "Yeah" or "Oh", and why those words appear in the live
    /// preview while nothing at all is being said. With this on, a detector
    /// trained on speech listens alongside the recording, and a take it never
    /// hears a voice in is dropped instead of guessed at.
    ///
    /// On by default, because the words it removes were never spoken. The
    /// switch exists for the opposite failure: if the detector ever decides
    /// wrongly that somebody was silent, a real dictation is lost, and
    /// waiting for an update is not an acceptable remedy.
    @Published var requireVoiceActivity: Bool {
        didSet { defaults.set(requireVoiceActivity, forKey: Key.requireVoiceActivity) }
    }

    /// Whether the hesitation noises are taken out of every transcript.
    ///
    /// On by default, because almost nobody wants "um" typed into their
    /// document, and off is one switch away for anyone who does. It is exact
    /// and offline, so leaving it on costs nothing and changes nothing else.
    @Published var removeFillerWords: Bool {
        didSet { defaults.set(removeFillerWords, forKey: Key.removeFillerWords) }
    }

    /// The words that removal takes out. Editable, because which noises a
    /// person makes depends on the language they are speaking.
    @Published var fillerWords: [String] {
        didSet { defaults.set(fillerWords, forKey: Key.fillerWords) }
    }

    /// What to press once the transcript has been pasted, for every dictation.
    ///
    /// One setting rather than one per rewrite profile: the question a person
    /// is answering is simply "having pasted my words, do you press Return
    /// too", and that does not change with the profile that rewrote them.
    /// Off by default, because pressing Return in the wrong place is
    /// destructive.
    @Published var autoSendKey: AutoSendKey {
        didSet { defaults.set(autoSendKey.rawValue, forKey: Key.autoSendKey) }
    }

    func rewriteModel(for provider: RewriteProviderKind) -> String? {
        rewriteProviderModels[provider.rawValue] ?? provider.defaultModel
    }

    /// Whether the selected rewrite provider is actually usable. A non-empty
    /// key alone is not enough: a typo'd key rendered a green "connected" row
    /// with an unverified default model, and every dictation then quietly fell
    /// back to the raw transcript. A model must be chosen too.
    var rewriteProviderIsConfigured: Bool {
        switch rewriteProvider.requirement {
        case .none:
            // "On this Mac" covers two quite different models. Apple's needs
            // nothing set up but may not be available; a downloaded one is
            // always capable but has to be on disk first.
            guard let model = RewriteModelCatalog.model(withID: localRewriteModelID) else { return false }
            return model.isAppleBuiltIn
                ? AppleOnDeviceRewriter.availability.isAvailable
                : RewriteModelManager.isInstalled(modelID: model.id)
        case .key:
            // Mirrors enhancementConfiguration(), which falls back to the
            // transcription key for OpenAI. Without this a user who already
            // connected OpenAI for transcription was told "not connected".
            var key = enhancementAPIKey.trimmingCharacters(in: .whitespaces)
            if key.isEmpty, rewriteProvider == .openai {
                key = openAIApiKey.trimmingCharacters(in: .whitespaces)
            }
            let hasKey = !key.isEmpty
            // Deliberately the *stored* model, not rewriteModel(for:), which
            // falls back to the provider's default. Only a successful key
            // validation writes this entry, so requiring it is what stops an
            // unverified key from rendering as connected.
            let stored = rewriteProviderModels[rewriteProvider.rawValue]?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return hasKey && !stored.isEmpty
        case .url:
            let hasURL = !enhancementBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
            let hasModel = !enhancementModel.trimmingCharacters(in: .whitespaces).isEmpty
            return hasURL && hasModel
        }
    }

    /// The rewrite profile currently selected, or nil when `rewriteProfileID`
    /// dangles. Every surface that names or applies the active profile goes
    /// through here so they can never disagree.
    var currentRewriteProfile: RewriteProfile? {
        rewriteProfiles.first { $0.id == rewriteProfileID }
    }

    /// Custom endpoints default to asking the server for its model list; these
    /// switch a section to a typed model id instead.
    @Published var customModelManualEntry: Bool {
        didSet { defaults.set(customModelManualEntry, forKey: Key.customModelManualEntry) }
    }
    @Published var rewriteModelManualEntry: Bool {
        didSet { defaults.set(rewriteModelManualEntry, forKey: Key.rewriteModelManualEntry) }
    }

    /// Moves forward or backward, wrapping. Returns the profile now selected.
    @discardableResult
    func cycleRewriteProfile(backwards: Bool = false) -> RewriteProfile? {
        guard !rewriteProfiles.isEmpty else { return nil }
        let index = rewriteProfiles.firstIndex { $0.id == rewriteProfileID } ?? (backwards ? 0 : -1)
        let step = backwards ? -1 : 1
        let next = rewriteProfiles[(index + step + rewriteProfiles.count) % rewriteProfiles.count]
        rewriteProfileID = next.id
        return next
    }

    /// One shortcut that advances to the next rewrite profile, wrapping at the
    /// end. Cheaper than a shortcut per profile when there are more than two or
    /// three, and it needs no key combination per profile.
    /// Inserts the last transcript again, wherever the cursor is now.
    ///
    /// This exists because giving the clipboard back took away the safety net
    /// that used to catch a mis-delivered dictation. The transcript used to sit
    /// on the clipboard afterwards, so a paste that landed in the wrong window
    /// could be repeated in the right one; restoring the clipboard is the
    /// better default but it removed that. This puts it back deliberately,
    /// which is also better than leaving it to a side effect.
    @Published var insertAgainShortcut: KeyboardShortcut? {
        didSet {
            if let insertAgainShortcut, let data = try? JSONEncoder().encode(insertAgainShortcut) {
                defaults.set(data, forKey: Key.insertAgainShortcut)
                defaults.set(false, forKey: Key.insertAgainShortcutCleared)
            } else {
                defaults.removeObject(forKey: Key.insertAgainShortcut)
                // Remembered, so a shortcut the user deliberately cleared does
                // not come back as the default on the next launch.
                defaults.set(true, forKey: Key.insertAgainShortcutCleared)
            }
        }
    }

    /// Starts an edit of whatever is selected in the focused app: the selection
    /// is read, the user says what to change, and the result replaces it.
    ///
    /// Optional, and unset by default. It borrows the clipboard and presses
    /// Command-C in somebody else's window, which is not something to do on a
    /// shortcut a user did not choose.
    @Published var editSelectionShortcut: KeyboardShortcut? {
        didSet {
            if let editSelectionShortcut, let data = try? JSONEncoder().encode(editSelectionShortcut) {
                defaults.set(data, forKey: Key.editSelectionShortcut)
            } else {
                defaults.removeObject(forKey: Key.editSelectionShortcut)
            }
        }
    }

    @Published var cycleProfilesShortcut: KeyboardShortcut? {
        didSet {
            if let cycleProfilesShortcut, let data = try? JSONEncoder().encode(cycleProfilesShortcut) {
                defaults.set(data, forKey: Key.cycleProfilesShortcut)
                defaults.set(false, forKey: Key.cycleProfilesShortcutCleared)
            } else {
                defaults.removeObject(forKey: Key.cycleProfilesShortcut)
                defaults.set(true, forKey: Key.cycleProfilesShortcutCleared)
            }
        }
    }

    @Published var previousProfileShortcut: KeyboardShortcut? {
        didSet {
            if let previousProfileShortcut, let data = try? JSONEncoder().encode(previousProfileShortcut) {
                defaults.set(data, forKey: Key.previousProfileShortcut)
                defaults.set(false, forKey: Key.previousProfileShortcutCleared)
            } else {
                defaults.removeObject(forKey: Key.previousProfileShortcut)
                defaults.set(true, forKey: Key.previousProfileShortcutCleared)
            }
        }
    }

    /// The floating overlay shown while dictating. On by default: the panel is
    /// closed while you talk, so without it nothing on screen says "recording".
    @Published var overlayEnabled: Bool {
        didSet { defaults.set(overlayEnabled, forKey: Key.overlayEnabled) }
    }

    @Published var overlayStyle: OverlayStyle {
        didSet { defaults.set(overlayStyle.rawValue, forKey: Key.overlayStyle) }
    }

    /// Which surface the Dock wears. Only the Dock has one, so it is only
    /// offered while the Dock is the chosen shape.
    @Published var overlayDockStyle: DockStyle {
        didSet { defaults.set(overlayDockStyle.rawValue, forKey: Key.overlayDockStyle) }
    }

    /// The Dock's hairline showing how much of the maximum has gone. Opt in,
    /// and only the Dock draws one, so it is offered only while the Dock is
    /// the chosen shape.
    @Published var overlayElapsedLine: Bool {
        didSet { defaults.set(overlayElapsedLine, forKey: Key.overlayElapsedLine) }
    }

    /// A tick for each of the last five seconds of a recording.
    ///
    /// The maximum is a real cliff: the take stops and whatever was half said
    /// is what gets transcribed. Somebody mid-sentence is looking at their
    /// document rather than at the indicator, so the warning has to be
    /// audible to be a warning at all.
    @Published var countdownBeforeMaximum: Bool {
        didSet { defaults.set(countdownBeforeMaximum, forKey: Key.countdownBeforeMaximum) }
    }

    @Published var overlaySize: OverlaySize {
        didSet { defaults.set(overlaySize.rawValue, forKey: Key.overlaySize) }
    }

    @Published var overlayPosition: OverlayPosition {
        didSet { defaults.set(overlayPosition.rawValue, forKey: Key.overlayPosition) }
    }

    /// How solid the overlay is drawn, 1 being fully opaque. Kept as opacity
    /// rather than transparency because that is what the window layer takes.
    /// Clamped on the way out so a bad stored value cannot make it invisible.
    @Published var overlayOpacity: Double {
        didSet { defaults.set(overlayOpacity, forKey: Key.overlayOpacity) }
    }

    var effectiveOverlayOpacity: Double { min(1, max(0.01, overlayOpacity)) }

    /// The floating panel above the pill that shows the words as they arrive.
    /// Off by default: it is the most attention-demanding thing the overlay
    /// can do, so it has to be asked for.
    @Published var overlayLivePreview: Bool {
        didSet { defaults.set(overlayLivePreview, forKey: Key.overlayLivePreview) }
    }

    /// Tapping Space during a held shortcut keeps the recording running
    /// after the keys are released. On by default; the Space key is only
    /// ever intercepted while a hold is actually in progress.
    @Published var spaceUpgradesHold: Bool {
        didSet { defaults.set(spaceUpgradesHold, forKey: Key.spaceUpgradesHold) }
    }

    /// One icon per rewrite profile, keyed by profile id.
    ///
    /// Keyed by id rather than by name, which is what the handoff suggests: a
    /// profile can be renamed, and its icon should survive that.
    @Published var profileIcons: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(profileIcons) {
                defaults.set(data, forKey: Key.profileIcons)
            }
        }
    }

    func iconID(forProfile id: String) -> String {
        profileIcons[id] ?? ProfileIcon.defaultIconID(forProfile: id)
    }

    func icon(forProfile id: String) -> ProfileIcon {
        ProfileIcon.icon(id: iconID(forProfile: id))
    }

    /// Whether finished dictations are remembered for the History window.
    @Published var keepRecentTranscripts: Bool {
        didSet { defaults.set(keepRecentTranscripts, forKey: Key.keepRecentTranscripts) }
    }

    /// The prompt in force for a profile: its edit if there is one, else stock.
    func prompt(for profileID: String) -> String {
        rewritePrompts[profileID] ?? RewriteProfile.defaultPrompt(for: profileID)
    }

    func promptWasEdited(_ profileID: String) -> Bool {
        guard let stored = rewritePrompts[profileID] else { return false }
        return stored != RewriteProfile.defaultPrompt(for: profileID)
    }

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStore = KeychainStore()
    ) {
        self.defaults = defaults
        self.keychain = keychain

        let storedProvider = defaults.string(forKey: Key.provider)
        // Whichever engine this Mac's language is best served by, and the
        // one the default model belongs to. A first launch that started on a
        // different engine than the model beside it left setup offering a
        // list the selected model was not in.
        var loadedProvider = TranscriptionProviderKind(rawValue: storedProvider ?? "")
            ?? (WhisperModelCatalog.recommendedEngine == .parakeet ? .parakeet : .whisper)
        // One local entry became three, and the stored value for the old one
        // is Whisper's. Somebody who had chosen a Parakeet or Nemotron model
        // under it would otherwise open a Whisper list that does not contain
        // what they are actually using, so the selected model decides which
        // of the three they are now on. Nothing about their setup changes;
        // only the name the app gives it.
        if loadedProvider == .whisper,
           let storedModel = defaults.string(forKey: Key.whisperModelID),
           let engine = WhisperModelCatalog.model(withID: storedModel)?.engine {
            switch engine {
            case .whisper: break
            case .parakeet: loadedProvider = .parakeet
            case .nemotron: loadedProvider = .nemotron
            }
        }
        provider = loadedProvider
        openAIModel = defaults.string(forKey: Key.openAIModel) ?? "gpt-transcribe"
        geminiModel = defaults.string(forKey: Key.geminiModel) ?? GeminiModelCatalog.defaultModelID
        geminiAPIKey = (try? keychain.get(account: "gemini-api-key")) ?? ""
        whisperModelID = defaults.string(forKey: Key.whisperModelID) ?? WhisperModelCatalog.defaultModelID
        enhancementEnabled = defaults.object(forKey: Key.enhancementEnabled) as? Bool ?? false
        // Empty on purpose: these belong to the "Custom" rewrite provider, and
        // defaulting them to OpenAI made picking Custom silently point at
        // OpenAI without a key.
        enhancementBaseURL = defaults.string(forKey: Key.enhancementBaseURL) ?? ""
        enhancementModel = defaults.string(forKey: Key.enhancementModel) ?? ""
        // Seeded from the legacy shared account; the per-provider migration at
        // the end of init moves it to a provider-scoped Keychain entry.
        enhancementAPIKey = (try? keychain.get(account: "enhancement-api-key")) ?? ""
        // The Custom *transcription* endpoint, separate from the rewrite one
        // above, and unchanged: a local server is the documented default.
        customBaseURL = defaults.string(forKey: Key.customBaseURL) ?? "http://127.0.0.1:8000/v1"
        customModel = defaults.string(forKey: Key.customModel) ?? "whisper-1"
        openAIApiKey = (try? keychain.get(account: "openai-api-key")) ?? ""
        customAPIToken = (try? keychain.get(account: "custom-api-token")) ?? ""
        // Normalised to a catalog id so the picker's selection matches its
        // tags; the field used to be free text, so "de_DE" or "EN " can be on
        // disk and would otherwise render an empty picker.
        language = SpokenLanguageCatalog.language(forStored: defaults.string(forKey: Key.language) ?? "").id
        // An unknown id means a model we no longer offer, or a settings file
        // from a newer build. Falling back beats leaving the picker with
        // nothing selected and the rewrite pointing at a file that is not there.
        restoreClipboardAfterPaste = defaults.object(forKey: Key.restoreClipboardAfterPaste) as? Bool ?? true
        let storedRewriteModel = defaults.string(forKey: Key.localRewriteModelID) ?? ""
        localRewriteModelID = RewriteModelCatalog.model(withID: storedRewriteModel)?.id
            ?? RewriteModelCatalog.defaultModelID
        prompt = defaults.string(forKey: Key.prompt) ?? ""
        preferOnDevice = defaults.object(forKey: Key.preferOnDevice) as? Bool ?? true
        appendTrailingSpace = defaults.object(forKey: Key.appendTrailingSpace) as? Bool ?? true
        let legacySoundPreference = defaults.object(forKey: Key.legacyPlayCompletionSound) as? Bool
        playFeedbackSounds = defaults.object(forKey: Key.playFeedbackSounds) as? Bool
            ?? legacySoundPreference
            ?? true
        if defaults.object(forKey: Key.playFeedbackSounds) == nil, let legacySoundPreference {
            defaults.set(legacySoundPreference, forKey: Key.playFeedbackSounds)
        }
        maximumRecordingSeconds = defaults.object(forKey: Key.maximumRecordingSeconds) as? Int ?? 120
        voiceActivationEnabled = defaults.object(forKey: Key.voiceActivationEnabled) as? Bool ?? false
        autoStopOnSilence = defaults.object(forKey: Key.autoStopOnSilence) as? Bool ?? false
        silenceStopSeconds = defaults.object(forKey: Key.silenceStopSeconds) as? Double ?? 1.5
        onboardingCompleted = defaults.object(forKey: Key.onboardingCompleted) as? Bool ?? false
        inputDeviceUID = defaults.string(forKey: Key.inputDeviceUID) ?? ""
        coachingTipsCompleted = defaults.object(forKey: Key.coachingTipsCompleted) as? Bool ?? false

        // A stored "chatgpt" value (the removed Codex CLI route) falls back to
        // .openai, and rewriting is switched off: the user may hold an OpenAI
        // key and a remembered consent, so the next dictation would otherwise
        // silently switch to a billed provider they never chose for rewriting.
        let storedRewriteProvider = defaults.string(forKey: Key.rewriteProvider) ?? ""
        rewriteProvider = RewriteProviderKind(rawValue: storedRewriteProvider) ?? .openai
        if storedRewriteProvider == "chatgpt" {
            enhancementEnabled = false
            defaults.set(false, forKey: Key.enhancementEnabled)
            defaults.set(RewriteProviderKind.openai.rawValue, forKey: Key.rewriteProvider)
        }
        if let data = defaults.data(forKey: Key.rewriteProfiles),
           let stored = try? JSONDecoder().decode([RewriteProfile].self, from: data),
           !stored.isEmpty {
            rewriteProfiles = stored
        } else {
            rewriteProfiles = RewriteProfile.builtins
        }
        rewriteProfileID = defaults.string(forKey: Key.rewriteProfileID) ?? "agentPrompt"
        if let data = defaults.data(forKey: Key.rewritePrompts),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            rewritePrompts = stored
        } else {
            rewritePrompts = [:]
        }
        let headerData = (try? keychain.get(account: "rewrite-custom-headers"))?.data(using: .utf8)
            ?? defaults.data(forKey: Key.rewriteCustomHeaders)
        if let data = headerData,
           let stored = try? JSONDecoder().decode([CustomHeader].self, from: data) {
            rewriteCustomHeaders = stored
            if let encoded = String(data: data, encoding: .utf8) {
                do {
                    try keychain.set(encoded, account: "rewrite-custom-headers")
                    defaults.removeObject(forKey: Key.rewriteCustomHeaders)
                } catch { /* Preserve the legacy value until migration succeeds. */ }
            }
        } else {
            rewriteCustomHeaders = [CustomHeader(name: "Authorization", value: "")]
        }
        historyLimit = defaults.object(forKey: Key.historyLimit) as? Int ?? TranscriptHistory.defaultLimit
        streamingMode = StreamingMode(rawValue: defaults.string(forKey: Key.streamingMode) ?? "") ?? .off
        theme = AppTheme(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .indigo
        // `bool(forKey:)` reports false for a key that was never written, so
        // the default has to be read through `object(forKey:)`.
        automaticPasteEnabled = defaults.object(forKey: Key.automaticPaste) as? Bool ?? true
        if let data = defaults.data(forKey: Key.textReplacements),
           let stored = try? JSONDecoder().decode([TextReplacement].self, from: data) {
            textReplacements = stored
        } else {
            textReplacements = []
        }
        removeFillerWords = defaults.object(forKey: Key.removeFillerWords) as? Bool ?? true
        requireVoiceActivity = defaults.object(forKey: Key.requireVoiceActivity) as? Bool ?? true
        // A stored empty list means the user emptied it deliberately, which is
        // different from never having had one, so `object(forKey:)` decides.
        fillerWords = defaults.object(forKey: Key.fillerWords) as? [String] ?? FillerWords.defaults
        if let stored = defaults.string(forKey: Key.autoSendKey) {
            autoSendKey = AutoSendKey(rawValue: stored) ?? .off
        } else if let data = defaults.data(forKey: Key.profileAutoSend),
                  let legacy = try? JSONDecoder().decode([String: AutoSendKey].self, from: data) {
            // Carried over from when this was set per rewrite profile: the
            // plain-dictation entry is the one that applied most of the time.
            autoSendKey = legacy["__rawTranscript"] ?? .off
        } else {
            autoSendKey = .off
        }
        if let data = defaults.data(forKey: Key.profileShortcuts),
           let stored = try? JSONDecoder().decode([String: KeyboardShortcut].self, from: data) {
            // Older builds could record lone modifiers for action shortcuts;
            // they can never register, so drop them instead of showing a
            // shortcut that silently does nothing.
            let usable = stored.filter { !$0.value.isModifierOnly }
            profileShortcuts = usable
            if usable.count != stored.count, let cleaned = try? JSONEncoder().encode(usable) {
                defaults.set(cleaned, forKey: Key.profileShortcuts)
            }
        } else {
            profileShortcuts = [:]
        }
        if let data = defaults.data(forKey: Key.rewriteProviderModels),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            rewriteProviderModels = stored
        } else {
            rewriteProviderModels = [:]
        }
        customModelManualEntry = defaults.object(forKey: Key.customModelManualEntry) as? Bool ?? false
        rewriteModelManualEntry = defaults.object(forKey: Key.rewriteModelManualEntry) as? Bool ?? false
        keepRecentTranscripts = defaults.object(forKey: Key.keepRecentTranscripts) as? Bool ?? true
        overlayEnabled = defaults.object(forKey: Key.overlayEnabled) as? Bool ?? true
        overlayLivePreview = defaults.object(forKey: Key.overlayLivePreview) as? Bool ?? false
        spaceUpgradesHold = defaults.object(forKey: Key.spaceUpgradesHold) as? Bool ?? true
        if let data = defaults.data(forKey: Key.profileIcons),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            profileIcons = stored
        } else {
            profileIcons = [:]
        }
        let storedSize = defaults.string(forKey: Key.overlaySize) ?? ""
        // Dock, not the pill. It is one object rather than two, it opens at
        // the height of the form without a preview and grows only as the
        // words need it, and a stored choice still wins for anyone who
        // already picked.
        overlayStyle = OverlayStyle(rawValue: defaults.string(forKey: Key.overlayStyle) ?? "") ?? .dock
        // Obsidian until somebody picks otherwise. Only an install that has
        // never chosen a style is affected: choosing one writes the key, so a
        // Dock somebody set themselves is never changed out from under them.
        overlayDockStyle = DockStyle(rawValue: defaults.string(forKey: Key.overlayDockStyle) ?? "") ?? .obsidian
        overlayElapsedLine = defaults.object(forKey: Key.overlayElapsedLine) as? Bool ?? false
        // On unless turned off. The maximum is a cliff: the take stops
        // wherever it has got to, and the words being spoken at that moment
        // are simply lost. A warning nobody switched on cannot warn anybody,
        // and five quiet ticks are a smaller imposition than a sentence
        // cut in half.
        countdownBeforeMaximum = defaults.object(forKey: Key.countdownBeforeMaximum) as? Bool ?? true
        overlaySize = OverlaySize(rawValue: storedSize == "regular" ? "wide" : storedSize) ?? .compact
        duckOtherAudio = defaults.object(forKey: Key.duckOtherAudio) as? Bool ?? true
        overlayPosition = OverlayPosition(rawValue: defaults.string(forKey: Key.overlayPosition) ?? "") ?? .bc
        overlayOpacity = defaults.object(forKey: Key.overlayOpacity) as? Double ?? 1.0
        if let data = defaults.data(forKey: Key.insertAgainShortcut),
           let stored = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            insertAgainShortcut = stored
        } else if defaults.bool(forKey: Key.insertAgainShortcutCleared) {
            insertAgainShortcut = nil
        } else {
            insertAgainShortcut = KeyboardShortcut.insertAgainDefault
        }
        if let data = defaults.data(forKey: Key.editSelectionShortcut),
           let stored = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            editSelectionShortcut = stored
        } else {
            editSelectionShortcut = nil
        }
        if let data = defaults.data(forKey: Key.cycleProfilesShortcut),
           let stored = try? JSONDecoder().decode(KeyboardShortcut.self, from: data),
           !stored.isModifierOnly {
            cycleProfilesShortcut = stored
        } else if defaults.bool(forKey: Key.cycleProfilesShortcutCleared) {
            cycleProfilesShortcut = nil
        } else {
            cycleProfilesShortcut = .cycleProfilesDefault
            defaults.removeObject(forKey: Key.cycleProfilesShortcut)
        }
        if let data = defaults.data(forKey: Key.previousProfileShortcut),
           let stored = try? JSONDecoder().decode(KeyboardShortcut.self, from: data),
           !stored.isModifierOnly {
            previousProfileShortcut = stored
        } else if defaults.bool(forKey: Key.previousProfileShortcutCleared) {
            previousProfileShortcut = nil
        } else {
            previousProfileShortcut = .previousProfileDefault
            defaults.removeObject(forKey: Key.previousProfileShortcut)
        }

        shortcutMode = ShortcutActivationMode(rawValue: defaults.string(forKey: Key.shortcutMode) ?? "") ?? .tapAndHold

        if
            let data = defaults.data(forKey: Key.shortcut),
            let decoded = try? JSONDecoder().decode(KeyboardShortcut.self, from: data)
        {
            shortcut = decoded
        } else {
            shortcut = .default
        }

        if let providerKey = try? keychain.get(account: "rewrite-\(rewriteProvider.rawValue)-api-key") {
            enhancementAPIKey = providerKey
        } else if !enhancementAPIKey.isEmpty {
            do {
                try keychain.set(enhancementAPIKey, account: "rewrite-\(rewriteProvider.rawValue)-api-key")
                try keychain.set("", account: "enhancement-api-key")
            } catch { /* Keep the original credential until migration succeeds. */ }
        }

        Self.apply(theme)
    }

    /// Nil when enhancement is disabled or misconfigured (empty custom prompt).
    /// Why a rewrite that is switched on will not happen, in the user's terms.
    ///
    /// Rewriting can be enabled and still have nothing to run: an on-device
    /// model macOS will not provide, a key that was removed, a profile whose
    /// prompt was emptied. `enhancementConfiguration()` returns nil for all of
    /// them, and a dictation that quietly inserts the raw transcript looks like
    /// a rewrite that did nothing rather than one that never started.
    var rewriteUnavailableReason: String? {
        guard enhancementEnabled, enhancementConfiguration() == nil else { return nil }
        guard rewriteProviderIsConfigured else {
            if rewriteProvider == .onDevice {
                guard let model = RewriteModelCatalog.model(withID: localRewriteModelID) else {
                    return "Choose a model to rewrite with."
                }
                guard model.isAppleBuiltIn else {
                    return "\(model.displayName) has not been downloaded yet."
                }
                return AppleOnDeviceRewriter.availability.explanation
                    ?? "Rewriting on this Mac is unavailable."
            }
            return "\(rewriteProvider.title) is not connected yet."
        }
        return "No rewrite instructions are set up."
    }

    /// The rewrite to run: for the profile named, or for whichever profile
    /// dictation is set to when none is.
    ///
    /// A named profile is an explicit request, the Tools menu asking for this
    /// text in this voice, so the "rewrite dictations" switch does not gate
    /// it. That switch decides what happens to dictation by default, which is
    /// a different question from what the user just asked for by name.
    func enhancementConfiguration(forProfileID profileID: String? = nil) -> EnhancementConfiguration? {
        if profileID == nil {
            guard enhancementEnabled else { return nil }
        }
        // Onboarding allows leaving with rewriting on but no provider set up
        // ("Continue without connecting"). Returning a config anyway made every
        // dictation attempt a doomed request and surface a failure note.
        guard rewriteProviderIsConfigured else { return nil }
        let profile: RewriteProfile
        if let profileID {
            // An id that no longer resolves means the profile was deleted
            // between the menu being built and the work starting. Falling
            // back to the dictation profile would quietly rewrite the text in
            // a voice nobody chose, which is worse than not rewriting it.
            guard let named = rewriteProfiles.first(where: { $0.id == profileID }) else { return nil }
            profile = named
        } else {
            guard let current = currentRewriteProfile else { return nil }
            profile = current
        }
        let systemPrompt = (rewritePrompts[profile.id] ?? RewriteProfile.defaultPrompt(for: profile.id))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !systemPrompt.isEmpty else { return nil }

        var apiKey = enhancementAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if apiKey.isEmpty, rewriteProvider == .openai {
            apiKey = openAIApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let baseURL: String
        let model: String
        switch rewriteProvider {
        case .onDevice:
            baseURL = ""
            // Carries the model's identity so the enhancer does not have to
            // reach back into settings from whatever thread it runs on.
            model = localRewriteModelID
        case .anthropic, .gemini, .openai:
            baseURL = rewriteProvider.apiBaseURL ?? ""
            model = rewriteModel(for: rewriteProvider) ?? ""
        case .custom:
            baseURL = enhancementBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            model = enhancementModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return EnhancementConfiguration(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            systemPrompt: systemPrompt,
            customHeaders: rewriteProvider == .custom ? rewriteCustomHeaders : [],
            usesOnDeviceModel: rewriteProvider == .onDevice,
            profileID: profile.id,
            profileName: profile.name
        )
    }

    /// The language the user picked, resolved from the stored code.
    var selectedLanguage: SpokenLanguage {
        SpokenLanguageCatalog.language(forStored: language)
    }

    /// ISO 639-1, for whisper.cpp and the OpenAI-style multipart APIs, which
    /// reject a region subtag.
    private var baseLanguageCode: String { selectedLanguage.id }

    /// Full BCP-47, for Gemini's language_codes and Apple's Locale.
    private var regionalLanguageTag: String { selectedLanguage.regionalTag }

    func transcriptionConfiguration() -> TranscriptionConfiguration {
        switch provider {
        case .appleSpeech:
            return TranscriptionConfiguration(
                provider: provider,
                baseURL: "",
                model: "",
                apiKey: "",
                language: regionalLanguageTag,
                prompt: prompt,
                preferOnDevice: preferOnDevice
            )
        case .whisper, .parakeet, .nemotron:
            return TranscriptionConfiguration(
                provider: provider,
                baseURL: "",
                model: whisperModelID,
                apiKey: "",
                language: baseLanguageCode,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                preferOnDevice: true,
                localModelURL: WhisperModelManager.localURL(forModelID: whisperModelID)
            )
        case .openAI:
            return TranscriptionConfiguration(
                provider: provider,
                baseURL: provider.transcriptionBaseURL ?? "",
                model: openAIModel.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: openAIApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                language: baseLanguageCode,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                preferOnDevice: false
            )
        case .gemini:
            return TranscriptionConfiguration(
                provider: provider,
                baseURL: GeminiAPI.baseURL,
                model: geminiModel.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
                language: regionalLanguageTag,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                preferOnDevice: false
            )
        case .custom:
            return TranscriptionConfiguration(
                provider: provider,
                baseURL: customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                model: customModel.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: customAPIToken.trimmingCharacters(in: .whitespacesAndNewlines),
                language: baseLanguageCode,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                preferOnDevice: false
            )
        }
    }
}
