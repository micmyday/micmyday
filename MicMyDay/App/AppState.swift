import AppKit
import AVFoundation
import Carbon.HIToolbox
import OSLog
import Combine
import ServiceManagement
import Speech
import SwiftUI
import UniformTypeIdentifiers

enum AppPhase: Equatable {
    case idle
    case requestingPermission
    case recording(startedAt: Date)
    case transcribing
    case enhancing
    /// Kept for completeness, but never entered: putting the text into the
    /// other app is a clipboard write and a keystroke, over in a few
    /// milliseconds, and announcing it showed a label that was gone before it
    /// could be read.
    case inserting
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "Ready"
        case .requestingPermission: return "Checking permissions…"
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .enhancing: return "Enhancing…"
        case .inserting: return "Typing…"
        case .failed: return "Needs attention"
        }
    }

    var symbolName: String {
        switch self {
        case .idle: return "waveform.badge.mic"
        case .requestingPermission: return "ellipsis.circle"
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .enhancing: return "wand.and.stars"
        case .inserting: return "keyboard"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var isBusy: Bool {
        switch self {
        case .requestingPermission, .transcribing, .enhancing, .inserting: return true
        default: return false
        }
    }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

/// A failure translated into the fix, not the error code. Every message names
/// what the user can do about it; the raw error text is never shown alone.
/// Which rewrite a one-off tool should run. Chosen in the Tools menu at the
/// moment of use, rather than read from the dictation settings, so rewriting
/// one file or one clipboard in a particular voice never changes what the
/// next dictation will do.
enum ToolRewrite: Equatable {
    case asSpoken
    case profile(String)
}

struct RecoveryAdvice: Equatable {
    var message: String
    /// Offers "Open Privacy Settings", which also reveals Settings → Permissions.
    var offersAccessibility: Bool = false
    var permissionIssue: PermissionIssue?

    static func advice(for error: Error) -> RecoveryAdvice {
        if let transcription = error as? TranscriptionError, case .emptyResponse = transcription {
            return RecoveryAdvice(message: silence)
        }
        if let transcription = error as? TranscriptionError, case .speechPermissionDenied = transcription {
            return RecoveryAdvice(message: PermissionIssue.speechRecognition.detail, permissionIssue: .speechRecognition)
        }
        if let recorder = error as? AudioRecorderError {
            switch recorder {
            case .noAudioCaptured, .silentInput:
                return RecoveryAdvice(message: silence)
            case .microphoneDenied:
                return RecoveryAdvice(message: PermissionIssue.microphone.detail, permissionIssue: .microphone)
            default:
                break
            }
        }
        if let urlError = error as? URLError {
            let host = urlError.failingURL?.host() ?? "the transcription server"
            return RecoveryAdvice(message: "The transcription request failed: the server at \(host) could not be reached. Your recording was deleted; nothing was sent anywhere else.")
        }
        return RecoveryAdvice(message: error.localizedDescription)
    }

    static let silence = "No speech was recognized. Check the selected microphone in Settings → Voice, make sure it is not muted, and try again."

    /// Why a dictation did not start, when entitlement is the reason. Phrased
    /// as the state's own explanation so the trial and a failed check do not
    /// read as the same problem.
    static func licenceRequired(_ state: LicenseState) -> RecoveryAdvice {
        RecoveryAdvice(message: state.blockedReason ?? "A licence is required to dictate.")
    }

    /// A step ran past the point where waiting could still be the right thing.
    static func tookTooLong(_ step: String) -> RecoveryAdvice {
        RecoveryAdvice(
            message: "\(step) was taking too long, so MicMyDay stopped waiting. If this keeps happening, check your connection, or switch to a local model in Settings so dictation does not depend on a server."
        )
    }

    static let accessibility = RecoveryAdvice(
        message: "Transcription finished, but MicMyDay could not paste it: Accessibility access is turned off. The text is on the clipboard, so press ⌘V, or turn the permission on to paste automatically.",
        offersAccessibility: true,
        permissionIssue: .accessibility
    )
}

/// Where a finished transcript ended up.
enum DeliveryOutcome: Equatable {
    case pasted(appName: String?)
    /// Part of the transcript is in the app and the clipboard holds only the
    /// rest, so the user appends rather than replaces.
    case remainderOnClipboard
    /// Part of the transcript is in the app but the clipboard holds the whole
    /// of it, so the user must replace rather than append.
    case replacementOnClipboard
    /// Reached the app, but the clipboard could not be updated, so telling the
    /// user it was "also copied" would send them to stale contents.
    case insertedNotCopied(appName: String?)
    case clipboardOnly
}

/// Everything the menu-bar status item draws, and nothing else.
///
/// MenuBarExtra rasterizes its label into an NSImage on every update, and
/// resolving an SF Symbol is expensive. Observing AppState directly meant the
/// 50 Hz input level and the permission poll each forced a fresh rasterization
/// until the main thread had no time left for anything else — which looked
/// exactly like dictation hanging on "Checking permissions". This object is
/// written only when the icon genuinely changes.
@MainActor
final class MenuBarModel: ObservableObject {
    enum Emphasis: Equatable {
        case neutral, recording, failed
    }

    @Published fileprivate(set) var symbolName = AppPhase.idle.symbolName
    @Published fileprivate(set) var emphasis: Emphasis = .neutral
    /// `0:07` while recording, nil otherwise — updated once per second.
    @Published fileprivate(set) var elapsed: String?
    @Published fileprivate(set) var accessibilityLabel = "MicMyDay: \(AppPhase.idle.title)"
}

/// One of the three tips shown after the very first successful dictation.
struct CoachingTip: Equatable {
    let symbol: String
    let title: String
    let text: String

    static let all: [CoachingTip] = [
        CoachingTip(
            symbol: "keyboard",
            title: "Talk from anywhere",
            text: "Put your cursor where the text should land, whether a terminal, an editor, or a browser field, then press the shortcut. MicMyDay returns focus to that app and types there."
        ),
        CoachingTip(
            symbol: "clipboard.fill",
            title: "The clipboard is the safety net",
            text: "Every transcript is also copied. If auto-paste is not possible, your words are one ⌘V away."
        ),
        CoachingTip(
            symbol: "wand.and.stars",
            title: "Speak in whole thoughts",
            text: "Long, rambling sentences transcribe better than short fragments, and rewriting can restructure them into a crisp agent prompt."
        ),
    ]
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var phase: AppPhase = .idle {
        didSet {
            if case .failed = phase {} else { recovery = nil }
            // The waiting tick is tied to the busy phases themselves rather
            // than to each exit path, so no route out of processing — cancel,
            // failure, dismissal — can leave it ticking forever.
            if !phase.isBusy { feedbackSoundPlayer.stopWaiting() }
            // The safety net for the hands-free key: its arm/disarm sites
            // all assume the shortcut's release event arrives, and a release
            // can be lost — an event tap disabled under load, a settings
            // change mid-hold, the Mac sleeping. Whatever happened, once no
            // dictation is starting or running there is nothing to upgrade,
            // and Space must never stay swallowed while the app sits idle.
            if !phase.isRecording, phase != .requestingPermission {
                handsFreeKey.disarm()
            }
            updateCancelHotKey()
            updateMenuBar()
            updateVoiceActivation()
            if phase == .requestingPermission { armStartingOverlay() } else { cancelStartingOverlay() }
            refreshOverlay()
            if case .idle = phase { prewarmAudio() }
        }
    }

    /// How long the microphone may take to open before the wait is worth
    /// admitting to. A wired input is ready well inside this, so its overlay
    /// goes straight to recording and "Starting…" is never seen; a wireless
    /// headset needs several hundred milliseconds to renegotiate its link, and
    /// showing nothing for that long reads as a missed keypress.
    private static let startingOverlayGrace: Duration = .milliseconds(180)

    private var showStartingOverlay = false
    private var startingOverlayTask: Task<Void, Never>?

    private func armStartingOverlay() {
        startingOverlayTask?.cancel()
        showStartingOverlay = false
        startingOverlayTask = Task { [weak self] in
            try? await Task.sleep(for: Self.startingOverlayGrace)
            guard !Task.isCancelled, let self, self.phase == .requestingPermission else { return }
            self.showStartingOverlay = true
            self.refreshOverlay()
        }
    }

    private func cancelStartingOverlay() {
        startingOverlayTask?.cancel()
        startingOverlayTask = nil
        showStartingOverlay = false
    }

    /// Gets the audio graph and the output ready while nothing is happening, so
    /// the next shortcut press has only `engine.start()` left to do.
    ///
    /// Pressing the shortcut a second time straight after a dictation has
    /// always felt instant while the first press of a session did not, because
    /// the first one pays for resolving the input device and waking the audio
    /// daemon. That work does not need the user to be waiting for it.
    func prewarmAudio() {
        guard !phase.isRecording else { return }
        // Never while a startup still owns the engine: cancelling a startup
        // shows .idle before start() has returned, and prewarming then is a
        // second thread inside an engine that is still being opened.
        guard !startupActive else { return }
        recorder.prewarm(inputDeviceUID: settings.inputDeviceUID)
        if settings.playFeedbackSounds { feedbackSoundPlayer.prewarm() }
    }

    @Published private(set) var voiceActivationArmed = false
    @Published private(set) var voiceActivationError: String?
    /// The transcript as it arrives, while streaming is on. Empty otherwise.
    @Published var streamingTranscript = ""
    @Published private(set) var lastTranscript = ""
    /// Which dictation last wrote `lastTranscript`, so a preservation write
    /// from a cancelled task can be allowed without ever letting it clobber a
    /// newer dictation's finished words. Guarding on equality instead failed
    /// on exactly the paths preservation exists for, because cancellation is
    /// what bumps the session.
    private var lastTranscriptSession = 0

    /// True when `lastTranscript` is an exact replacement — a kept edit whose
    /// whitespace was deliberately preserved — so inserting it again must not
    /// trim it or append a space.
    private var lastTranscriptExact = false

    /// Writes `lastTranscript` unless a newer dictation already has. The one
    /// gate every write goes through, stale or fresh.
    private func keepTranscript(_ text: String, from session: Int, exact: Bool = false) {
        guard session >= lastTranscriptSession else { return }
        lastTranscriptSession = session
        lastTranscript = text
        lastTranscriptExact = exact
        // New text on show means no delivery claim until something makes one.
        // Half a dozen paths preserve a transcript that was never delivered,
        // a cancelled rewrite among them, and each one used to leave the
        // previous dictation's "Pasted into Xcode" caption sitting under text
        // that had gone nowhere. Every caller that did deliver sets these
        // again straight afterwards.
        lastDelivery = nil
        lastEnhancementNote = nil
        // The settled text, for the overlay's live preview: once this exists
        // the panel stops showing interim words and shows what will actually
        // land — the rewrite's output when a profile ran. Keyed to the session
        // so the next dictation's panel can never open on the last one's text.
        overlayFinalText = text
        overlayFinalTextSession = session
        refreshOverlay()
    }

    /// What `keepTranscript` last settled on, and for which session. Read only
    /// by `refreshOverlay`, which ignores it for any other session.
    private var overlayFinalText = ""
    private var overlayFinalTextSession = -1
    @Published private(set) var hotKeyError: String?
    @Published private(set) var hotKeyRegistered = false
    @Published private(set) var microphoneStatus = "Not requested"
    @Published private(set) var speechStatus = "Not requested"
    @Published private(set) var accessibilityStatus = "Not granted"
    /// Set when a restart could not be started, so the user is told to quit and
    /// reopen rather than being left with an unexplained dead button.
    @Published private(set) var relaunchFailed = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var permissionIssues: [PermissionIssue] = []
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    @Published private(set) var inputDeviceError: String?
    @Published private(set) var activeInputDeviceName: String?
    @Published private(set) var inputLevel: Float = 0
    /// The fix for the current `.failed` phase, phrased for a person.
    @Published private(set) var recovery: RecoveryAdvice?
    @Published private(set) var lastDelivery: DeliveryOutcome?
    /// Name of the app a dictation will be pasted into, for the busy caption.
    @Published private(set) var insertionTargetName: String?
    /// Set only when enhancement failed and the raw transcript was used.
    @Published private(set) var lastEnhancementNote: String?
    /// Index into `CoachingTip.all`, or nil when no tip is showing.
    @Published private(set) var coachingTipIndex: Int?
    /// True while the assistant or Settings has a window on screen. Coaching
    /// is advice about the panel, so it must never be half-covered by one.
    @Published private(set) var windowIsOpen = false
    /// Briefly names the profile after the cycle shortcut switches it, so the
    /// press is not silent when the panel is closed.
    @Published fileprivate(set) var activeProfileNote: String?

    let settings: SettingsStore
    let menuBar = MenuBarModel()
    /// Recent dictations, kept across launches in the sandbox container.
    let history: TranscriptHistory

    private let recorder = AudioRecorder()
    private let audioDucker = SystemAudioDucker()
    /// Per-model counters. Written to only after a dictation has delivered, so
    /// nothing about statistics can slow down or fail the job itself.
    let usage = UsageStatistics()
    /// True while a wireless headset's microphone is deliberately being held
    /// open past the end of capture, so the final cue can be heard before the
    /// Bluetooth link switches back.
    private var holdingWirelessInput = false
    private var wirelessHoldTask: Task<Void, Never>?
    /// Rises with every dictation. Closing cues and hold timers carry the
    /// session they belong to, so a callback from a dictation that has been
    /// superseded cannot release the resources of the one running now.
    private var dictationSession = 0
    /// Bounds whatever the dictation is doing after the microphone has closed.
    private var workDeadline: Task<Void, Never>?
    /// The work itself, so cancelling can stop it rather than merely hiding it.
    private var workTask: Task<Void, Never>?

    /// Longest any single step after recording may take before it is given up
    /// on.
    ///
    /// A step that has not finished by now is not going to: a provider that is
    /// unreachable, a local model wedged, a rewrite that will never return.
    /// Without this the app simply waited, with no way out, which is the one
    /// state a dictation must never be able to reach.
    ///
    /// Transcription is allowed the audio's own length on top, because a long
    /// recording genuinely takes longer to transcribe and a flat limit would
    /// cut off dictations that were working.
    private static let stepLimit: Duration = .seconds(20)

    /// Overridden by tests, which cannot wait twenty seconds to find out that
    /// a step gave up.
    var stepLimitForTesting: Duration?

    /// Starts the work a dictation does after recording, without needing a
    /// microphone. Exists so the cancellation and timeout logic can be tested;
    /// the app itself always arrives here through `stopAndTranscribe`.
    ///
    /// Always as a practice run, and that is not a detail. A practice run
    /// pastes nothing, leaves the clipboard alone and sends no Return. Without
    /// it this drove the real delivery path, and a test's fake transcript was
    /// typed into whatever the developer happened to have focused. A test must
    /// not be able to reach out of the test.
    func beginDictationForTesting(audioURL: URL) {
        transcribe(audioURL: audioURL, insertionTarget: nil, practice: true)
    }
    private var waitingForAudioTask: Task<Void, Never>?
    /// The two things a wireless dictation waits for before it stops looking
    /// like it is still starting. Both are events, and whichever arrives second
    /// is the one that ends the spinner.
    private var audioIsFlowing = false
    private var openingCueFinished = false
    /// How long to wait for a wireless headset's first buffer before showing
    /// the recording regardless. Generous: it is not a deadline the microphone
    /// has to meet, only the point at which a spinner stops being useful.
    private static let firstBufferLimit: Duration = .seconds(15)
    /// Entitlement. Owned here so every path into recording can consult it
    /// without waiting on anything.
    let licence = LicenseManager()
    /// In-app updates. Direct distribution means there is no App Store to ship
    /// a fix through, so the app has to be able to update itself.
    let updates = UpdateController()
    private let voiceListener = VoiceActivationListener()
    private var voiceSegmentInFlight = false
    /// Bumped whenever a voice segment ends for any reason, including a cancel
    /// or a listener restart. A segment's callbacks carry the generation they
    /// began in, so a late write from an abandoned segment cannot transcribe
    /// its audio into a newer recording or clear that recording's state.
    private var voiceSegmentGeneration = 0

    private var voiceRearmTask: Task<Void, Never>?
    private var voiceFailureStreak = 0
    private let hotKeyManager = HotKeyManager()
    private let inputMonitoringPermission = InputMonitoringPermission()
    private let permissionDragHelper = PermissionDragHelper()
    private let cancelHotKey = CancelHotKey()
    /// Space, armed only while the dictation shortcut is held; see
    /// `HandsFreeKey` and `upgradeHoldToHandsFree`.
    private let handsFreeKey = HandsFreeKey()
    /// A short-lived chip on the recording pill ("Hands-free"), in the slot
    /// the armed profile normally occupies.
    @Published private(set) var overlayNoteText: String?
    private var overlayNoteTask: Task<Void, Never>?
    /// The dictation currently writing into another app, if any. Held so
    /// Escape can stop it after transcription has already begun.
    private var activeStream: StreamingSession? {
        didSet { updateCancelHotKey() }
    }
    /// What a voice edit is working on: the text that was selected, and the
    /// clipboard that reading it borrowed.
    ///
    /// Set before recording starts and cleared when the dictation ends, however
    /// it ends. While it is set, what the user says is an instruction about
    /// this text rather than text to insert.
    /// The selection an edit is working on, the clipboard reading it borrowed,
    /// and the change count at the moment it was borrowed.
    ///
    /// The count is what makes restoring safe: if the clipboard has moved on,
    /// the user has copied something since and that is now the thing they
    /// expect to paste. Passing the *current* count instead, as this first did,
    /// made the check always pass and could take a fresh copy away from them.
    private var pendingEdit: (
        selection: String,
        clipboard: TextInjector.ClipboardContents,
        changeCount: Int
    )?

    /// The give-back for the edit currently in flight, reachable from the
    /// cancel paths. The task owns the edit tuple, but a cancelled local
    /// rewrite can hold the task for seconds, and the user's clipboard was
    /// squatting un-returned that whole time. Consumed by nil-swap, so the
    /// task's own late cleanup finds nothing to return twice.
    private var activeEditReturn: (clipboard: TextInjector.ClipboardContents, changeCount: Int)?

    private func consumeActiveEditReturn() {
        guard let pending = activeEditReturn else { return }
        activeEditReturn = nil
        textInjector.giveBackBorrowed(pending.clipboard, ifUnchangedFrom: pending.changeCount)
    }

    /// Set while a selection is being copied, before any phase has changed.
    /// Pressing the shortcut twice, or starting a dictation during the copy,
    /// would otherwise leave two flows running over each other.
    private var capturingSelection = false

    /// Whether the current recording captures through the shared recorder
    /// (manual dictations) or the voice listener's own engine (voice
    /// segments). The startup deferral must only park controls for recordings
    /// that contend with the recorder a startup is holding — keyed on this
    /// rather than on voiceSegmentInFlight, which a settings change can clear
    /// while the recording is still going, wedging Escape behind a stale
    /// startup forever.
    private var recordingUsesRecorder = true

    /// Watches for a click or a keystroke during an edit, which means the
    /// passage the edit was asked about may no longer be what is selected.
    private var editWatcher: UserInteractionWatcher?

    /// The startup currently opening the microphone, if any. New startups
    /// chain behind it rather than running beside it: `recorder.start()` runs
    /// off the main actor, and a second start — or a cancel — arriving while
    /// it is still inside the engine mutates the same recorder from two
    /// threads. The wait ends when the previous startup returns, which is the
    /// event that says the recorder is free.
    private var startupTask: Task<Void, Never>?
    /// Which press each queued startup belongs to. A press that was cancelled
    /// while its startup sat behind a slow one must not run when its turn
    /// comes: it would hijack whichever press is newest.
    private var startupRequest = 0
    /// True from the moment a startup begins until `beginRecording` returns.
    /// The recorder is being mutated off the main actor for that whole span,
    /// so nothing else — prewarming, a stop from an early first buffer, a
    /// cancel — may touch it until this goes false.
    private var startupActive = false

    private func launchRecordingStartup() {
        startupRequest += 1
        let request = startupRequest
        let previous = startupTask
        startupTask = Task { [weak self] in
            await previous?.value
            guard let self, self.startupRequest == request else { return }
            self.startupActive = true
            await self.beginRecording()
            self.startupActive = false
            self.runDeferredRecordingControls()
        }
    }

    /// Applies a stop or cancel that arrived while the recorder was still
    /// starting. Sequenced on the startup's completion — the event that says
    /// the recorder is safe to touch — rather than attempted concurrently.
    private func runDeferredRecordingControls() {
        guard phase.isRecording else { return }
        if cancelWhenRecordingBegins {
            cancelWhenRecordingBegins = false
            stopWhenRecordingBegins = false
            cancelRecording()
        } else if stopWhenRecordingBegins {
            stopWhenRecordingBegins = false
            stopAndTranscribe()
        }
    }

    /// Set while the last transcript is being inserted again. The phase does
    /// not change for that, so without this a second press of the shortcut
    /// starts a second paste into the same place.
    private var insertingAgain = false

    /// Recognition running against the live microphone, when the engine can do
    /// it and the user asked for live text. Nil otherwise, and nil is the
    /// ordinary case: every other engine takes a finished recording.
    private var liveTranscriber: (any LiveTranscribing)?
    /// Listens alongside the recording and answers whether anybody spoke.
    /// Nil when the check is switched off or its model is not downloaded, in
    /// which case every take is transcribed exactly as before.
    private var voiceDetector: VoiceActivityDetector?
    /// The transcription configuration captured when the recording started,
    /// bound to its session so an abandoned take's snapshot can never leak
    /// into a later dictation that skipped the capture; see `transcribe`.
    private var recordingConfiguration: (session: Int, configuration: TranscriptionConfiguration)?

    /// The stabiliser that keeps the preview from fidgeting, and the session
    /// it belongs to; see `PreviewStabilizer`. Session-bound like every
    /// other piece of live state.
    private var previewSession = -1
    private var previewStabilizer = PreviewStabilizer()
    private var previewFirmWords: Int?

    /// The stream belonging to the dictation in flight, registered whatever the
    /// streaming mode.
    ///
    /// Separate from `activeStream`, which carries a narrower meaning: words
    /// are being written into another app right now. With streaming off that is
    /// false, so nothing marked the stream cancelled, `shouldContinue` stayed
    /// true, and Escape pressed while the app waited to paste let the paste and
    /// the auto-send Return happen anyway.
    private weak var streamInFlight: StreamingSession?
    private let actionHotKeys = ActionHotKeyManager()
    private let overlayController = OverlayController()
    private var profileToastTask: Task<Void, Never>?
    /// Set while Settings → Overlay is open, so the real overlay stands in for
    /// a preview thumbnail.
    private var overlayPreviewing = false
    private var overlayPreviewTask: Task<Void, Never>?
    private var overlayTickTask: Task<Void, Never>?
    /// Substitutable so a test can hand in its own pasteboard. Without that
    /// seam a test of anything clipboard-shaped writes into whatever the
    /// developer had copied, which is a test reaching out of the test.
    private let textInjector: TextInjector
    private let feedbackSoundPlayer = FeedbackSoundPlayer()
    private var settingsCancellable: AnyCancellable?
    private var preloadCancellables: Set<AnyCancellable> = []
    private var maximumDurationTask: Task<Void, Never>?
    private var hotKeyPressStartedAt: Date?
    private var stopWhenRecordingBegins = false
    private var cancelWhenRecordingBegins = false
    private var targetPID: pid_t?
    /// Set while the onboarding try-out is recording.
    ///
    /// The try-out runs the real pipeline on purpose, but it must not deliver:
    /// the user is looking at MicMyDay's own window, so "the app you were last
    /// in" is whatever they happened to have open before setup, and pasting
    /// there sends the window to the back and drops words into a document they
    /// were not writing.
    private var isPracticeRun = false
    private var previousExternalPID: pid_t?
    private var historyWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private enum PermissionDestination {
        case settings(NSWindow, SettingsPane)
        case onboarding(NSWindow)

        var window: NSWindow {
            switch self {
            case .settings(let window, _), .onboarding(let window): return window
            }
        }
    }
    private var permissionReturnFlow = PermissionReturnFlow<PermissionDestination>()
    private var coachingWindow: NSWindow?
    private var permissionPollTimer: Timer?
    private var elapsedTimer: Timer?
    private var permissionPollClients = 0
    private var workspaceObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var keyWindowObserver: NSObjectProtocol?
    private var appLaunchObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    /// The two pieces of work a dictation does after the microphone closes.
    ///
    /// Injectable for one reason: the logic around them, cancelling, giving up
    /// on a step that is taking too long, discarding a result that arrives
    /// after the user has moved on, is where the bugs are, and testing it
    /// otherwise needs a microphone, a network and a person. With these
    /// substituted, a test can make transcription hang and assert that Escape
    /// leaves nothing behind.
    struct Work {
        var transcribe: (
            _ audioURL: URL,
            _ configuration: TranscriptionConfiguration,
            _ probe: UsageProbe?,
            _ onPartialText: (@MainActor (String) -> Void)?
        ) async throws -> String = { url, configuration, probe, onPartial in
            try await TranscriptionService.transcribe(
                audioURL: url,
                configuration: configuration,
                probe: probe,
                onPartialText: onPartial
            )
        }

        var enhance: (
            _ text: String,
            _ configuration: EnhancementConfiguration,
            _ probe: UsageProbe?
        ) async throws -> String = { text, configuration, probe in
            try await TranscriptEnhancer().enhance(text, configuration: configuration, probe: probe)
        }
    }

    let work: Work

    init(
        settings: SettingsStore,
        work: Work = Work(),
        textInjector: TextInjector = TextInjector()
    ) {
        self.settings = settings
        self.work = work
        self.textInjector = textInjector
        history = TranscriptHistory(
            limit: settings.historyLimit,
            isPersistenceEnabled: settings.keepRecentTranscripts
        )
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled

        actionHotKeys.onTriggered = { [weak self] action in
            self?.handleActionShortcut(action)
        }

        hotKeyManager.onPressed = { [weak self] in
            self?.handleHotKeyPress()
        }
        handsFreeKey.onUpgrade = { [weak self] in
            self?.upgradeHoldToHandsFree()
        }
        hotKeyManager.onReleased = { [weak self] in
            self?.handleHotKeyRelease()
        }

        recorder.onInputLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inputLevel = max(level, self.inputLevel * 0.72)
            }
        }
        recorder.onSilenceAutoStop = { [weak self] in
            guard let self, case .recording = self.phase, !self.voiceSegmentInFlight else { return }
            self.stopAndTranscribe()
        }

        voiceListener.onSpeechStart = { [weak self] in
            // The token this segment will come back with. Handed out here and
            // compared on return, so a segment's late file delivery carries the
            // generation it was *born* in rather than whatever is current. A
            // refused segment gets a token no generation will ever equal, so
            // its callbacks can never pass the check.
            guard let self, let token = self.voiceSegmentDidStart() else { return -1 }
            return token
        }
        voiceListener.onSpeechSegment = { [weak self] url, generation in
            self?.voiceSegmentDidFinish(url, generation: generation)
        }
        voiceListener.onSpeechDiscarded = { [weak self] generation in
            self?.voiceSegmentDidDiscard(generation: generation)
        }
        voiceListener.onInputLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inputLevel = max(level, self.inputLevel * 0.72)
            }
        }

        settingsCancellable = settings.$shortcut
            .dropFirst()
            .sink { [weak self] shortcut in
                self?.registerHotKey(shortcut)
            }

        settings.$provider.combineLatest(settings.$shortcut)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.refreshPermissionStatuses() }
            .store(in: &preloadCancellables)

        // Re-arm when a profile shortcut, either cycle shortcut, or the profile
        // list itself changes — a shortcut recorded in Settings has to work
        // without relaunching.
        settings.$profileShortcuts
            .combineLatest(settings.$cycleProfilesShortcut, settings.$previousProfileShortcut, settings.$rewriteProfiles)
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.refreshActionShortcuts()
            }
            .store(in: &preloadCancellables)
        // The two standalone action shortcuts, for the same reason. Left out of
        // the combine above only because it is already at its arity limit.
        // Without this a cleared edit shortcut stayed registered and could
        // still press Command-C in somebody's window.
        settings.$editSelectionShortcut
            .combineLatest(settings.$insertAgainShortcut)
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.refreshActionShortcuts()
            }
            .store(in: &preloadCancellables)

        // Load the selected local model ahead of the first dictation — at
        // launch, when the provider or model selection changes, and when a
        // download finishes for the currently selected model.
        settings.$provider
            .combineLatest(settings.$whisperModelID)
            .sink { provider, modelID in
                guard provider.isLocalModel else { return }
                WhisperModelManager.shared.preloadSelectedModel(id: modelID)
            }
            .store(in: &preloadCancellables)
        WhisperModelManager.shared.$installedModelIDs
            .dropFirst()
            .sink { [weak self] installed in
                guard let self, self.settings.provider.isLocalModel,
                      installed.contains(self.settings.whisperModelID) else { return }
                WhisperModelManager.shared.preloadSelectedModel(id: self.settings.whisperModelID)
            }
            .store(in: &preloadCancellables)

        // The same for the rewrite model. Reading a multi-gigabyte file cold can
        // take longer than a rewrite is allowed to run, so a model loaded only
        // when first needed would fail the very dictation that asked for it.
        settings.$rewriteProvider
            .combineLatest(settings.$localRewriteModelID, settings.$enhancementEnabled)
            .sink { provider, modelID, enabled in
                guard enabled, provider == .onDevice else { return }
                RewriteModelManager.shared.preloadModel(id: modelID)
            }
            .store(in: &preloadCancellables)
        RewriteModelManager.shared.$installedModelIDs
            .dropFirst()
            .sink { [weak self] installed in
                guard let self, self.settings.enhancementEnabled,
                      self.settings.rewriteProvider == .onDevice,
                      installed.contains(self.settings.localRewriteModelID) else { return }
                RewriteModelManager.shared.preloadModel(id: self.settings.localRewriteModelID)
            }
            .store(in: &preloadCancellables)

        // @Published emits on willSet, so deliver on the next runloop pass —
        // updateVoiceActivation() reads the property and must see the new value.
        settings.$voiceActivationEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateVoiceActivation()
            }
            .store(in: &preloadCancellables)
        // Restart the armed listener when a setting it captured at start changes.
        settings.$inputDeviceUID.map { _ in () }
            .merge(with: settings.$silenceStopSeconds.map { _ in () })
            .dropFirst(2)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.voiceListener.isListening else { return }
                self.voiceListener.stop()
                self.voiceActivationArmed = false
                // Restarting the listener throws away any segment it was
                // recording, so resolve that segment rather than leaving the
                // app stuck in .recording with no callback ever arriving.
                if self.voiceSegmentInFlight {
                    self.voiceSegmentGeneration += 1
                    self.voiceSegmentInFlight = false
                    if self.phase.isRecording { self.cancelRecording() }
                }
                self.updateVoiceActivation()
            }
            .store(in: &preloadCancellables)

        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.processIdentifier != ownPID {
            previousExternalPID = frontmost.processIdentifier
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                application.processIdentifier != ownPID
            else { return }
            Task { @MainActor [weak self] in
                self?.previousExternalPID = application.processIdentifier
                self?.permissionReturnFlow.externalAppActivated(bundleID: application.bundleIdentifier)
            }
        }
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            Task { @MainActor [weak self] in
                self?.windowDidBecomeKey(window)
            }
        }
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPermissionStatuses()
                self?.refreshLaunchAtLoginStatus()
                self?.refreshAudioInputDevices()
                self?.restorePermissionWindowOnReturn()
            }
        }
        // Quitting must not cost the last dictation: the save is coalesced, so
        // without this a transcript made in the final moment is still pending.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isTerminating = true
                self?.history.flush()
                // The same reasoning: the usage write is coalesced too, so
                // without this a quit inside that window loses the counters
                // from the dictation that just finished.
                self?.usage.flush()
                self?.audioDucker.restoreImmediately()
                self?.recorder.releaseInput()
            }
        }
        appLaunchObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.activate(evaluatingSetup: true)
                // Two megabytes, fetched once, quietly. The check that needs
                // it is on by default, so waiting for somebody to notice a
                // warning in Settings would mean it never worked for anyone
                // upgrading into this version.
                if self?.settings.requireVoiceActivity == true {
                    VoiceActivityModel.shared.ensureReady()
                }
            }
        }

        // State objects can be created on either side of the application launch
        // notification. This deferred attempt covers the latter case; register()
        // is idempotent for an unchanged shortcut.
        DispatchQueue.main.async { [weak self] in
            self?.activate(evaluatingSetup: true)
            // Same reason as the deferred activation above: this object can
            // be built after the launch notification has already gone by, and
            // then the observer never fires. Fetching is guarded, so whichever
            // of the two arrives first is the one that does it.
            if self?.settings.requireVoiceActivity == true {
                VoiceActivityModel.shared.ensureReady()
            }
        }
    }

    deinit {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let appActivationObserver {
            NotificationCenter.default.removeObserver(appActivationObserver)
        }
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
        }
        if let appLaunchObserver {
            NotificationCenter.default.removeObserver(appLaunchObserver)
        }
    }

    func activate(evaluatingSetup: Bool = false) {
        registerHotKey(settings.shortcut)
        refreshActionShortcuts()
        refreshPermissionStatuses()
        refreshLaunchAtLoginStatus()
        refreshAudioInputDevices()
        restorePermissionWindowOnReturn()
        updateVoiceActivation()
        prewarmAudio()
        // The pill's window, built before a dictation needs it rather than
        // during the one that does; see OverlayController.prepare. Returns
        // immediately once the window exists, so the panel-opening calls to
        // this method do no work.
        overlayController.prepare()
        history.isPersistenceEnabled = settings.keepRecentTranscripts
        licence.refreshState()
        licence.revalidateIfDue()
        // Not a one-time flag: the mandatory prerequisites are evaluated
        // live at every launch. A user who deleted their model, revoked a
        // permission in System Settings, or closed the assistant halfway
        // gets routed back to it, not left with an app that silently cannot
        // dictate. Everything read here is a passive status check; nothing
        // may trigger a system prompt. Launch only — this method also runs
        // when the menu-bar panel opens, and someone reaching for Settings
        // must not have the assistant shoved in front of them.
        if evaluatingSetup,
           !settings.onboardingCompleted || !setupIsComplete,
           settingsWindow?.isVisible != true {
            showOnboarding()
        }
    }

    /// Whether a dictation can currently run from key press to text landing:
    /// every needed permission, a working shortcut, and an engine that can
    /// actually transcribe. This is the mandatory set; anything optional —
    /// rewriting, profiles, sounds, the overlay — deliberately stays out.
    var setupIsComplete: Bool {
        guard permissionIssues.isEmpty, hotKeyRegistered else { return false }
        return transcriptionEngineUsable
    }

    /// Selected is not enough: a local model must be downloaded (and, for the
    /// Core ML one, prepared), and a hosted provider needs its key.
    private var transcriptionEngineUsable: Bool {
        switch settings.provider {
        case .appleSpeech:
            // Its one requirement is the speech permission, and that is
            // already part of `permissionIssues`.
            return true
        case .whisper, .parakeet, .nemotron:
            return WhisperModelManager.isInstalled(modelID: settings.whisperModelID)
        case .openAI, .gemini:
            let configuration = settings.transcriptionConfiguration()
            return !configuration.apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        case .custom:
            // A custom endpoint may be a keyless server on this machine, so
            // only the address and the model are mandatory, matching how the
            // rewrite side judges its own custom endpoints.
            let configuration = settings.transcriptionConfiguration()
            return !configuration.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                && !configuration.model.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    func showOnboarding() {
        guard !MicMyDayApp.isRunningTests else { return }
        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = OnboardingView { [weak self] in
            guard let self else { return }
            self.settings.onboardingCompleted = true
            self.closeOnboarding()
        }
        .environmentObject(self)
        .environmentObject(settings)

        onboardingWindow = presentChromelessWindow(
            root: root,
            size: CGSize(width: 960, height: 750),
            accessibilityTitle: "MicMyDay Setup"
        )
        updateWindowVisibility()
    }

    func showHistory() {
        guard !MicMyDayApp.isRunningTests else { return }
        dismissMenuBarPanel()
        if let window = historyWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = HistoryWindowView()
            .environmentObject(self)
            .environmentObject(history)

        historyWindow = presentChromelessWindow(
            root: root,
            // The design specifies 660 x 470; opening a little larger leaves
            // room for the detail pane without an immediate resize.
            size: CGSize(width: 820, height: 600),
            accessibilityTitle: "MicMyDay History",
            centresTrafficLights: true
        )
        updateWindowVisibility()
    }

    func closeHistory() {
        historyWindow?.close()
        historyWindow = nil
        updateWindowVisibility()
    }

    func closeOnboarding() {
        if let window = onboardingWindow { cancelPermissionReturn(for: window) }
        onboardingWindow?.close()
        onboardingWindow = nil
        updateWindowVisibility()
    }

    /// The menu-bar popover is its own window; leaving it up behind a real
    /// window shows two MicMyDay surfaces at once.
    func dismissMenuBarPanel() {
        for window in NSApp.windows where window.className.contains("MenuBarExtra") {
            window.close()
        }
    }

    func showSettings(selecting pane: SettingsPane? = nil) {
        // Structural, not per-test: several refusal paths open Settings to
        // the pane that explains them, and a suite that ran one of those
        // threw a window over whatever the developer was doing. A test can
        // never open a window, whichever branch it reaches.
        guard !MicMyDayApp.isRunningTests else { return }
        dismissMenuBarPanel()
        closeHistory()
        if let window = settingsWindow {
            if let pane { settingsSelection.pane = pane }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }
        if let pane { settingsSelection.pane = pane }
        let root = SettingsWindowView(onDone: { [weak self] in self?.closeSettings() })
            .environmentObject(self)
            .environmentObject(settings)
            .environmentObject(settingsSelection)
            .environmentObject(history)

        settingsWindow = presentChromelessWindow(
            root: root,
            size: CGSize(width: 900, height: 680),
            accessibilityTitle: "MicMyDay Settings",
            opensWithNothingFocused: true
        )
        updateWindowVisibility()
    }

    func closeSettings() {
        if let window = settingsWindow { cancelPermissionReturn(for: window) }
        settingsWindow?.close()
        settingsWindow = nil
        updateWindowVisibility()
    }

    /// The assistant and Settings are both borderless: the traffic lights sit
    /// over a 44px strip the content draws itself, and the window is fixed at
    /// the size the design specifies.
    private func presentChromelessWindow(
        root: some View,
        size: CGSize,
        accessibilityTitle: String,
        resizable: Bool = false,
        minimumSize: CGSize? = nil,
        centresTrafficLights: Bool = false,
        opensWithNothingFocused: Bool = false
    ) -> NSWindow {
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if resizable { styleMask.insert(.resizable) }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        // Tagged with the theme the window is born under. The colour tokens
        // are static properties, which SwiftUI has no way to observe, so this
        // guarantees a window created after a theme change starts on the new
        // palette. It does not track later changes: the id is fixed at
        // creation and this root view is never reassigned, so a view that
        // wants to follow the theme while open has to be invalidated by
        // something it does observe.
        let hosting = NSHostingController(rootView: root.id(settings.themeIdentity))
        // Without this SwiftUI insets the content by the titlebar height, so
        // the design's own title strip is pushed below a band of window
        // background and the seam between them is visible. Clearing the safe
        // area lets the content run to the top edge, with the real traffic
        // lights sitting over it as the design draws them.
        hosting.safeAreaRegions = []
        // The traffic lights are centred by AppKit in the titlebar, which is
        // 28pt tall by default: their centre lands 16pt down while a 48pt
        // custom title strip centres its own content at 24pt, and the two rows
        // read as misaligned. An empty toolbar makes the titlebar taller, so
        // the system moves the buttons down to match rather than us nudging
        // their frames and having AppKit put them back on the next layout.
        window.contentViewController = hosting
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Without these the window keeps its default light material, which
        // shows through behind the titlebar strip and reads as a half-filled
        // background against the ink canvas.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.043, green: 0.039, blue: 0.078, alpha: 1)
        window.isOpaque = true
        window.title = accessibilityTitle
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        // AppKit centres the traffic lights in the titlebar, 28pt tall by
        // default, so they sit 16pt down while a taller custom title strip
        // centres its own row lower and the two read as misaligned. An empty
        // toolbar makes the titlebar taller and the system moves the buttons
        // to match, rather than us setting their frames and having AppKit put
        // them back on the next layout.
        if centresTrafficLights {
            let toolbar = NSToolbar()
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified
        }
        // setFrame, not setContentSize. The window is .fullSizeContentView, so
        // SwiftUI sizes it to the content's frame; setContentSize would add the
        // titlebar height on top, leaving the window 32pt taller than SwiftUI
        // wants. SwiftUI then shrinks it back from windowDidLayout, that resize
        // re-marks the window as needing layout, and the two can re-trigger each
        // other. Past AppKit's limit of 30 layout passes in one display cycle
        // the window raises NSGenericException and the app aborts. Starting at
        // the size SwiftUI is going to ask for leaves it nothing to correct.
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        if let minimumSize { window.contentMinSize = minimumSize }
        window.center()
        window.delegate = windowDelegate
        // Regular first, active second, and the order is the point. macOS
        // wires an app's menu bar up when the app activates, so an accessory
        // app that activates and only then becomes regular is frontmost with
        // no menu bar at all. Mostly invisible, but with the menu bar set to
        // auto-hide it means mousing to the top of the screen reveals
        // nothing for as long as one of our windows is open.
        // `updateWindowVisibility` still flips the policy back once the last
        // window closes.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // AppKit hands a new window's focus to the first field it can find.
        // In Settings that is the search box, so the window opened with a
        // caret blinking in it and a highlighted border around it as though a
        // search were already under way. Only where that is wrong, though:
        // History opens on its own search field precisely so that someone
        // looking for an old transcript can start typing.
        if opensWithNothingFocused {
            window.initialFirstResponder = nil
            window.makeFirstResponder(nil)
        }
        return window
    }

    /// Coaching is suppressed while a window is open and returns when it
    /// closes. Permission polling is not driven from here — the panes start
    /// and stop it in pairs from their own lifecycle.
    private func updateWindowVisibility() {
        let wasOpen = windowIsOpen
        windowIsOpen = (onboardingWindow?.isVisible ?? false)
            || (settingsWindow?.isVisible ?? false)
            || (historyWindow?.isVisible ?? false)
        // onAppear/onDisappear never fire inside these retained
        // NSHostingController windows, so the permission poll is tied to the
        // window lifecycle here; the menu bar panel keeps its own client.
        if windowIsOpen != wasOpen {
            if windowIsOpen { startPermissionPolling() } else { stopPermissionPolling() }
        }
        if settingsWindow?.isVisible != true { setOverlayPreviewing(false) }
        // A menu-bar-only app has no Dock icon and no Cmd-Tab entry, so a
        // window that slips behind another app looks closed and cannot be
        // found again. While any window is open, appear in the Dock so one
        // click brings it back; return to menu-bar-only when the last closes.
        NSApp.setActivationPolicy(windowIsOpen ? .regular : .accessory)
        syncCoachingWindow()
    }

    func windowDidClose(_ window: NSWindow) {
        // Ignore a delayed close notification if a permission completion has
        // already brought this retained window back on screen.
        if window.isVisible { updateWindowVisibility(); return }
        // Preserve the exact view/page during a system permission interaction.
        // Explicit user closes cancel the return context separately.
        if permissionReturnFlow.destination?.window === window {
            updateWindowVisibility()
            return
        }
        if window === onboardingWindow {
            onboardingWindow = nil
            // Closing the assistant with the red button still counts as
            // finishing setup; it must not reopen on every launch.
            //
            // Quitting is not closing. Every window closes as the app
            // terminates, and treating that as "finished" meant the restart
            // the Accessibility row itself offers marked setup complete on
            // the way out: the user came back to no assistant, no onboarding,
            // and the permission they had just granted still unexplained.
            if !isTerminating { settings.onboardingCompleted = true }
        }
        if window === settingsWindow { settingsWindow = nil }
        if window === historyWindow { historyWindow = nil }
        updateWindowVisibility()
    }

    // MARK: - Permission window restoration

    fileprivate func cancelPermissionReturn(for window: NSWindow) {
        if windowAwaitingUnfloat === window { windowAwaitingUnfloat = nil }
        if permissionReturnFlow.destination?.window === window {
            window.level = .normal
            permissionReturnFlow.cancel()
        }
    }

    private func beginPermissionInteraction() -> UUID? {
        let id: UUID?
        if let window = onboardingWindow, window.isKeyWindow {
            id = permissionReturnFlow.begin(.onboarding(window))
        } else if let window = settingsWindow, window.isVisible {
            id = permissionReturnFlow.begin(.settings(window, settingsSelection.pane))
        } else if let window = onboardingWindow, window.isVisible {
            id = permissionReturnFlow.begin(.onboarding(window))
        } else {
            return nil
        }
        floatDuringPermissionInteraction(true)
        return id
    }

    /// Keeps the window that asked in front for as long as the asking lasts.
    ///
    /// Bringing it back afterwards was already attempted and is not enough.
    /// macOS calls the completion handler as the permission dialog is being
    /// dismissed, and then hands focus back to whatever was frontmost before
    /// it appeared; our activation lands first and the system's lands second,
    /// so the setup assistant ends up behind another app's window. A
    /// menu-bar app has no Dock icon most of the time, so a window that slips
    /// behind reads as one that closed itself.
    ///
    /// Raising the level sidesteps the race rather than trying to win it:
    /// the window cannot be covered whoever ends up with focus. Undone the
    /// moment the interaction ends, because nothing of ours should sit above
    /// other applications any longer than that.
    private func floatDuringPermissionInteraction(_ floating: Bool) {
        guard let window = permissionReturnFlow.destination?.window else { return }
        window.level = floating ? .floating : .normal
    }

    private func finishPermissionPrompt(_ requestID: UUID?) {
        refreshPermissionStatuses()
        if let destination = permissionReturnFlow.promptFinished(requestID) {
            restorePermissionWindow(destination)
        }
    }

    private func restorePermissionWindowOnReturn() {
        if let destination = permissionReturnFlow.appBecameActive() {
            restorePermissionWindow(destination)
        }
    }

    private func restorePermissionWindow(_ destination: PermissionDestination) {
        switch destination {
        case .settings(let window, let pane):
            settingsWindow = window
            settingsSelection.pane = pane
        case .onboarding(let window):
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        destination.window.makeKeyAndOrderFront(nil)
        // Still floating from `beginPermissionInteraction`, and it stays that
        // way until the window is actually key again. Dropping the level here
        // was the bug it exists to prevent: macOS hands focus back to
        // whatever was frontmost before its permission dialog appeared, that
        // hand-back lands after this method, and activation on modern macOS
        // is cooperative, so ours can simply be refused. The window then sat
        // at normal level behind the other app, which reads as the assistant
        // having closed itself. Becoming key is the one event that proves the
        // user is back in the window, so that is what lowers it.
        unfloatWhenKey(destination.window)
        updateWindowVisibility()
    }

    /// The window still held above others while its permission interaction
    /// winds down; lowered the moment it becomes key. Weak, because a window
    /// the user closes in that state must not be kept alive by the wait.
    private weak var windowAwaitingUnfloat: NSWindow?

    private func unfloatWhenKey(_ window: NSWindow) {
        if window.isKeyWindow {
            window.level = .normal
            return
        }
        windowAwaitingUnfloat = window
    }

    func windowDidBecomeKey(_ window: NSWindow) {
        guard window === windowAwaitingUnfloat else { return }
        windowAwaitingUnfloat = nil
        window.level = .normal
    }

    // MARK: - Status item

    /// Assign only on change: every write here costs a symbol rasterization.
    private func updateMenuBar() {
        let symbol = phase.symbolName
        if menuBar.symbolName != symbol { menuBar.symbolName = symbol }

        let emphasis: MenuBarModel.Emphasis
        switch phase {
        case .recording: emphasis = .recording
        case .failed: emphasis = .failed
        case .idle: emphasis = permissionIssues.isEmpty ? .neutral : .failed
        default: emphasis = .neutral
        }
        if menuBar.emphasis != emphasis { menuBar.emphasis = emphasis }

        let label = "MicMyDay: \(phase == .idle ? permissionIssues.first?.title ?? phase.title : phase.title)"
        if menuBar.accessibilityLabel != label { menuBar.accessibilityLabel = label }

        if case let .recording(startedAt) = phase {
            startElapsedTimer(from: startedAt)
        } else {
            elapsedTimer?.invalidate()
            elapsedTimer = nil
            if menuBar.elapsed != nil { menuBar.elapsed = nil }
        }
    }

    /// One string per second while recording — not a TimelineView, which
    /// invalidates the rasterized label far more often than once a second.
    private func startElapsedTimer(from startedAt: Date) {
        guard elapsedTimer == nil else { return }
        let tick: @MainActor () -> Void = { [weak self] in
            guard let self, case .recording = self.phase else { return }
            let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
            let text = String(format: "%d:%02d", seconds / 60, seconds % 60)
            if self.menuBar.elapsed != text { self.menuBar.elapsed = text }
        }
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    // MARK: - Live permission detection
    //
    // Rows update themselves the moment macOS grants: Accessibility sends no
    // notification, so it is polled while a window is on screen. The manual
    // "Refresh status" button in the Permissions pane is a fallback for the
    // case where a prompt was answered in another process.

    private static let relaunchLogger = Logger(subsystem: "com.micmyday.app", category: "relaunch")
    private static let audioLogger = Logger(subsystem: "com.micmyday.app", category: "WirelessCues")
    private static let workLogger = Logger(subsystem: "com.micmyday.app", category: "Dictation")

    /// Quits and reopens MicMyDay.
    ///
    /// Accessibility (post-event) access is read once per process: macOS does
    /// not tell a running app that the permission arrived, and polling cannot
    /// see it either, because the answer the app gets back was decided when it
    /// launched. Restarting is the only reliable way to pick it up, so the app
    /// offers to do it rather than leaving the user to guess.
    ///
    /// Done by starting a helper that waits for this process to exit and then
    /// reopens the app, rather than the other way round. Launching the new copy
    /// first cannot work: MicMyDay is an agent (LSUIElement), which
    /// LaunchServices treats as single-instance, so asking for another copy
    /// hands back the one already running, and quitting then closes the app
    /// with nothing left to come back.
    /// True from the moment a quit begins, so a window closing as part of it
    /// is not mistaken for the user closing it.
    private var isTerminating = false

    func relaunch() {
        relaunchFailed = false
        let bundlePath = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let quotedPath = "'" + bundlePath.replacingOccurrences(of: "'", with: "'\\''") + "'"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; sleep 0.3; open \(quotedPath)",
        ]
        do {
            try task.run()
        } catch {
            // The helper never started, so quitting would strand the user with
            // a closed app and no explanation.
            Self.relaunchLogger.error("Relaunch helper failed: \(error.localizedDescription, privacy: .public)")
            relaunchFailed = true
            return
        }
        isTerminating = true
        NSApp.terminate(nil)
    }

    func startPermissionPolling() {
        permissionPollClients += 1
        guard permissionPollTimer == nil else { return }
        refreshPermissionStatuses()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPermissionStatuses() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }

    func stopPermissionPolling() {
        permissionPollClients = max(0, permissionPollClients - 1)
        guard permissionPollClients == 0 else { return }
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    /// Raises the real macOS prompt. Once a permission has been denied macOS
    /// never asks again, so the second press has to open System Settings.
    func requestMicrophonePermission() {
        let requestID = beginPermissionInteraction()
        Task {
            if AudioRecorder.microphoneAuthorizationStatus == .notDetermined {
                _ = await AudioRecorder.requestMicrophoneAccess()
            } else if AudioRecorder.microphoneAuthorizationStatus != .authorized {
                openPrivacySettings(.microphone)
            }
            finishPermissionPrompt(requestID)
        }
    }

    func requestSpeechPermission() {
        let requestID = beginPermissionInteraction()
        Task {
            if AppleSpeechTranscriber.authorizationStatus == .notDetermined {
                _ = await AppleSpeechTranscriber.requestAuthorization()
            } else if AppleSpeechTranscriber.authorizationStatus != .authorized {
                openPrivacySettings(.speechRecognition)
            }
            finishPermissionPrompt(requestID)
        }
    }

    // The sandbox makes CGRequestPostEventAccess and IOHIDRequestAccess
    // silent no-ops, so MicMyDay can never put itself into these System
    // Settings lists. Open the pane and float the drag helper beside it so
    // the user can drag the icon into the list instead of hunting for "+".
    func requestAccessibilityPermission() {
        guard !accessibilityGranted else { return }
        openPrivacySettings(.accessibility)
        showPermissionDragHelper(for: .accessibility)
    }

    func requestInputMonitoringPermission() {
        guard !inputMonitoringPermission.isGranted else { return }
        openPrivacySettings(.inputMonitoring)
        showPermissionDragHelper(for: .inputMonitoring)
    }

    /// The helper keeps one polling client of its own, so the grant is
    /// noticed (and the panel dismissed) even if every app window is closed
    /// while the user is over in System Settings.
    private func showPermissionDragHelper(for issue: PermissionIssue) {
        if !permissionDragHelper.isVisible { startPermissionPolling() }
        permissionDragHelper.onDismiss = { [weak self] in self?.stopPermissionPolling() }
        permissionDragHelper.show(for: issue)
    }

    var microphoneGranted: Bool { AudioRecorder.microphoneAuthorizationStatus == .authorized }
    var microphoneDenied: Bool {
        let status = AudioRecorder.microphoneAuthorizationStatus
        return status == .denied || status == .restricted
    }
    var speechGranted: Bool { AppleSpeechTranscriber.authorizationStatus == .authorized }
    var accessibilityGranted: Bool { TextInjector.isAccessibilityTrusted }

    /// The user has allowed it, but this process still cannot use it.
    ///
    /// Post-event access is decided once per process, so a grant made while
    /// MicMyDay is running is invisible to the thing that needs it until the
    /// app restarts. Without this the app says the permission is missing to
    /// somebody looking at their own System Settings with the switch on,
    /// which reads as the app being broken rather than as needing a restart.
    var accessibilityAllowedPendingRestart: Bool {
        !TextInjector.isAccessibilityTrusted && TextInjector.isAccessibilityAllowedInSystemSettings
    }

    // MARK: - First-dictation coaching

    func dismissCoaching() {
        coachingTipIndex = nil
        settings.coachingTipsCompleted = true
        syncCoachingWindow()
    }

    func showNextCoachingTip() {
        guard let index = coachingTipIndex else { return }
        if index + 1 < CoachingTip.all.count {
            coachingTipIndex = index + 1
            syncCoachingWindow()
        } else {
            dismissCoaching()
        }
    }

    private func beginCoachingIfNeeded() {
        guard !settings.coachingTipsCompleted, coachingTipIndex == nil else { return }
        coachingTipIndex = 0
        syncCoachingWindow()
    }

    private func syncCoachingWindow() {
        let shouldShow = coachingTipIndex != nil && !windowIsOpen
        guard shouldShow else {
            coachingWindow?.orderOut(nil)
            coachingWindow = nil
            return
        }
        // The view observes AppState, so an open panel re-renders itself when
        // the tip index changes; only a missing panel has to be built.
        if let window = coachingWindow {
            window.orderFrontRegardless()
            return
        }
        let root = CoachingTipView().environmentObject(self)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = NSHostingController(
            rootView: root.id(settings.themeIdentity)
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        // Size to the tip before positioning, then anchor the top-left corner
        // so a longer tip grows downwards instead of drifting up the screen.
        panel.setContentSize(panel.contentViewController?.view.fittingSize ?? NSSize(width: 280, height: 140))
        positionCoachingPanel(panel)
        panel.orderFrontRegardless()
        coachingWindow = panel
    }

    /// Beside the menu-bar item, not over it: top-right of the active screen,
    /// clear of the popover the tips describe.
    private func positionCoachingPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(
            x: visible.maxX - panel.frame.width - 36,
            y: visible.maxY - 8
        ))
    }

    private lazy var settingsSelection = SettingsSelection()
    private lazy var windowDelegate = AppWindowDelegate(owner: self)

    /// Keeps the always-on listener aligned with the setting and app phase:
    /// it runs while idle (armed) and during a voice-triggered recording, and
    /// pauses during transcription so output tones and app sounds cannot
    /// retrigger it. Re-arming is delayed slightly for the same reason.
    private func updateVoiceActivation() {
        let shouldListen = settings.voiceActivationEnabled && (phase == .idle || voiceSegmentInFlight)
        if shouldListen {
            guard !voiceListener.isListening, voiceRearmTask == nil else { return }
            voiceRearmTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                self?.voiceRearmTask = nil
                self?.startVoiceListening()
            }
        } else {
            voiceRearmTask?.cancel()
            voiceRearmTask = nil
            if voiceListener.isListening {
                voiceListener.stop()
            }
            voiceActivationArmed = false
            // Turning the setting off mid-segment stops the listener, whose
            // buffers are gone; the recording phase would otherwise be stuck
            // with a Stop button that can never finish it.
            if voiceSegmentInFlight, !settings.voiceActivationEnabled {
                voiceSegmentGeneration += 1
                if phase.isRecording {
                    cancelRecording()
                }
                voiceSegmentInFlight = false
            }
        }
    }

    private func startVoiceListening() {
        guard settings.voiceActivationEnabled, phase == .idle, !voiceListener.isListening else { return }
        Task {
            guard await AudioRecorder.requestMicrophoneAccess() else {
                voiceActivationError = AudioRecorderError.microphoneDenied.localizedDescription
                scheduleVoiceActivationRetry()
                return
            }
            // Awaiting the permission prompt takes arbitrarily long, and the
            // user can switch the feature off or start a manual recording in
            // the meantime. Without rechecking, the microphone was opened
            // afterwards anyway, staying live with the toggle showing off.
            guard settings.voiceActivationEnabled, phase == .idle, !voiceListener.isListening else { return }
            do {
                try voiceListener.start(
                    inputDeviceUID: settings.inputDeviceUID,
                    maximumSegmentSeconds: settings.maximumRecordingSeconds,
                    silenceSeconds: settings.silenceStopSeconds
                )
                voiceActivationError = nil
                voiceActivationArmed = true
            } catch {
                voiceActivationError = error.localizedDescription
                voiceActivationArmed = false
                scheduleVoiceActivationRetry()
            }
        }
    }

    /// Right after launch (especially launch-at-login) the audio subsystem may
    /// not be ready: the input can briefly report no devices or a 0 Hz format.
    /// Without a retry the listener parked on that first error until the user
    /// toggled the setting off and on — so keep retrying while enabled.
    private func scheduleVoiceActivationRetry() {
        guard settings.voiceActivationEnabled, phase == .idle, voiceRearmTask == nil else { return }
        voiceRearmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.voiceRearmTask = nil
            self?.startVoiceListening()
        }
    }

    /// Returns the token the segment's later callbacks must present, or nil
    /// for a segment this method refused to start. A refused segment used to
    /// walk away with the live generation anyway, and its discard callback then
    /// passed the ownership check and cleared the target of the manual
    /// dictation that had displaced it.
    private func voiceSegmentDidStart() -> Int? {
        guard !insertingAgain, !capturingSelection else {
            voiceListener.abortSegment()
            return nil
        }
        guard phase == .idle, settings.voiceActivationEnabled, voiceListener.isListening else {
            voiceListener.abortSegment()
            return nil
        }
        voiceSegmentInFlight = true
        // A previous dictation may still be holding a wireless headset open
        // for its closing cue. The session bump below silences that cue's
        // session-guarded release, so the hold is retired here first, exactly
        // as beginRecording does — or the microphone stays claimed with no
        // release path at all.
        finishWirelessDictation()
        // Claimed like any other dictation. Without this, consecutive voice
        // dictations shared one session number and a stale task's transcript
        // write could not be told apart from the current one's.
        dictationSession += 1
        targetPID = currentExternalApplicationPID()
        if settings.playFeedbackSounds {
            feedbackSoundPlayer.playRecordingStart()
        }
        recordingUsesRecorder = false
        phase = .recording(startedAt: Date())
        // The same ceiling every other recording has. Without it a microphone
        // that stalls mid-segment left the recording running until a manual
        // stop, because the silence detector never fires on no buffers at all.
        scheduleMaximumDurationStop()
        return voiceSegmentGeneration
    }

    private func voiceSegmentDidFinish(_ audioURL: URL, generation: Int) {
        // A segment that was cancelled or superseded must not deliver audio
        // into whatever is happening now.
        guard generation == voiceSegmentGeneration else {
            try? FileManager.default.removeItem(at: audioURL)
            return
        }
        voiceSegmentGeneration += 1
        voiceSegmentInFlight = false
        inputLevel = 0
        let insertionTarget = targetPID
        targetPID = nil
        guard case .recording = phase else {
            try? FileManager.default.removeItem(at: audioURL)
            updateVoiceActivation()
            return
        }
        transcribe(audioURL: audioURL, insertionTarget: insertionTarget, isVoiceTriggered: true)
    }

    private func voiceSegmentDidDiscard(generation: Int) {
        guard generation == voiceSegmentGeneration else {
            // Not this segment's dictation any more, but the listener still
            // stopped: without re-arming here, a cancelled stalled segment
            // left the app claiming to listen while nothing did.
            updateVoiceActivation()
            return
        }
        voiceSegmentGeneration += 1
        voiceSegmentInFlight = false
        inputLevel = 0
        targetPID = nil
        if case .recording = phase {
            endStep()
            phase = .idle
        } else {
            updateVoiceActivation()
        }
    }

    func toggleRecording(practice: Bool = false) {
        #if DEBUG
        DuckTrace.mark("toggleRecording (shortcut)")
        #endif
        // A paste of the previous transcript, or a selection being read, is in
        // flight. Starting a dictation on top of either races two deliveries
        // into the same place.
        guard !insertingAgain, !capturingSelection else { return }
        switch phase {
        case .recording:
            stopAndTranscribe()
        case .idle, .failed:
            isPracticeRun = practice
            phase = .requestingPermission
            launchRecordingStartup()
        case .requestingPermission, .transcribing, .enhancing, .inserting:
            break
        }
    }

    private func handleHotKeyPress() {
        #if DEBUG
        DuckTrace.mark("hotkey pressed")
        #endif
        // The same reasoning as toggleRecording: a paste or a selection copy is
        // in flight and starting a dictation on top of it races two deliveries
        // into the same place.
        guard !insertingAgain, !capturingSelection else { return }
        switch phase {
        case .recording:
            // In hold-to-record mode a press cannot arrive while recording
            // (recording only exists between press and release), so treating
            // it as a stop is safe in every mode.
            hotKeyPressStartedAt = nil
            handsFreeKey.disarm()
            stopAndTranscribe()
        case .idle, .failed:
            hotKeyPressStartedAt = Date()
            // Space upgrades the hold to hands-free — but only in the modes
            // where releasing would otherwise stop the take; in pure toggle
            // mode Space stays untouched, because there is nothing to
            // upgrade and the key belongs to whatever the user is doing.
            // And never when the dictation shortcut itself is built on
            // Space: tapping Space mid-hold would then just repeat the
            // shortcut's own chord, and registering it again fails anyway.
            if settings.spaceUpgradesHold,
               settings.shortcutMode != .tapToggle,
               settings.shortcut.keyCode != UInt32(kVK_Space) {
                handsFreeKey.arm(modifiers: heldShortcutCarbonModifiers)
            }
            // A note from the previous take must not greet this one: an
            // upgrade followed by a quick cancel and restart still had
            // "Hands-free" on screen for a hold that would very much stop
            // on release.
            overlayNoteTask?.cancel()
            overlayNoteText = nil
            stopWhenRecordingBegins = false
            cancelWhenRecordingBegins = false
            phase = .requestingPermission
            launchRecordingStartup()
        case .requestingPermission, .transcribing, .enhancing, .inserting:
            break
        }
    }

    private func handleHotKeyRelease() {
        #if DEBUG
        DuckTrace.mark("hotkey released")
        #endif
        guard let pressedAt = hotKeyPressStartedAt else { return }
        hotKeyPressStartedAt = nil
        handsFreeKey.disarm()
        let heldDuration = Date().timeIntervalSince(pressedAt)

        switch ShortcutReleaseAction.forRelease(mode: settings.shortcutMode, heldDuration: heldDuration) {
        case .none:
            return
        case .stop:
            finishHeldRecording(discard: false)
        case .discard:
            finishHeldRecording(discard: true)
        }
    }

    private func finishHeldRecording(discard: Bool) {
        switch phase {
        case .recording:
            if discard {
                cancelRecording()
            } else {
                stopAndTranscribe()
            }
        case .requestingPermission:
            // Recording has not started yet; apply the release once it has.
            if discard {
                cancelWhenRecordingBegins = true
            } else {
                stopWhenRecordingBegins = true
            }
        case .idle, .transcribing, .enhancing, .inserting, .failed:
            break
        }
    }

    /// Escape cancels while the microphone is live, and also while a streamed
    /// transcript is still being written into the user's document, since that
    /// is the other moment there is something to stop. At any other time the
    /// key stays with whatever app the user is in.
    /// Escape is armed for the whole of a dictation, not just while the
    /// microphone is open.
    ///
    /// It used to be armed only while recording or streaming, which meant that
    /// the moment a dictation was most likely to need abandoning, waiting on a
    /// transcription or a rewrite that was taking too long, was exactly the
    /// moment there was no way to abandon it. Which step is running should not
    /// change whether the user can stop.
    private func updateCancelHotKey() {
        if phase.isRecording || phase.isBusy || activeStream != nil {
            cancelHotKey.onCancel = { [weak self] in self?.cancelRecording() }
            cancelHotKey.arm()
        } else {
            cancelHotKey.disarm()
        }
    }

    /// Undoes whatever we did to other audio when the recording began, which
    /// depends on the microphone: a wireless headset had playback paused, and
    /// anything else had it faded down.
    /// Lets go of a wireless headset once its closing cue has been heard.
    ///
    /// Everything here is safe to call when no headset is being held, because
    /// the closing cues fire on every dictation and only some of them are
    /// wireless.
    /// Longest a headset is ever held open past the end of capture.
    ///
    /// Every ordinary path releases it through a closing cue. This exists for
    /// the paths that do not arrive: a transcription provider that never
    /// answers would otherwise keep the microphone, and its indicator, running
    /// for as long as it liked.
    private static let wirelessHoldLimit: Duration = .seconds(90)

    private func scheduleWirelessHoldLimit() {
        let session = dictationSession
        wirelessHoldTask?.cancel()
        wirelessHoldTask = Task { [weak self] in
            try? await Task.sleep(for: Self.wirelessHoldLimit)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.dictationSession == session else { return }
                guard self.holdingWirelessInput else { return }
                Self.audioLogger.info("wireless hold timed out, releasing the microphone")
                self.finishWirelessDictation(session: session)
            }
        }
    }

    /// Passing a session makes this a no-op once a newer dictation has begun,
    /// so a late closing cue cannot take the microphone away from it.
    private func finishWirelessDictation(session: Int? = nil) {
        if let session, session != dictationSession { return }
        wirelessHoldTask?.cancel()
        wirelessHoldTask = nil
        guard holdingWirelessInput else { return }
        holdingWirelessInput = false
        recorder.releaseInput()
        feedbackSoundPlayer.releaseWirelessRoute()
        restoreOtherAudio()
    }

    /// The microphone is now genuinely listening: show it, say it, and let the
    /// rest of the recording machinery start.
    ///
    /// Separate from `beginRecording` because the moment it happens differs by
    /// device. A wired input reaches it as soon as the graph is built; a
    /// wireless one reaches it when its first buffer arrives, a second or so
    /// later, once the Bluetooth link has finished switching.
    /// Goes live once both the microphone is delivering audio and the opening
    /// cue has finished sounding.
    private func goLiveIfReady() {
        guard audioIsFlowing, openingCueFinished else { return }
        goLive(startedAt: Date(), cueAttackEnds: nil, wireless: true)
    }


    /// The duck after the opening cue's first strike: one fade straight to
    /// silence. The number is the user's, chosen by ear against real music
    /// after trying gentler envelopes with a floor and a glide; he rejected
    /// each as too slow, accepting that the bell's ring-out is shaded down
    /// with everything else.
    private static let recordingStartDuckFade: Duration = .milliseconds(60)

    private func goLive(startedAt: Date, cueAttackEnds: ContinuousClock.Instant?, wireless: Bool) {
        #if DEBUG
        DuckTrace.mark("goLive(wireless: \(wireless))")
        #endif
        recordingUsesRecorder = true
        abandonAudioWait()
        guard case .requestingPermission = phase else { return }
        phase = .recording(startedAt: startedAt)
        // Every cue sounded back at the keypress, in `beginRecording`; only
        // the instant its first strike finishes rising arrives here.
        //
        // The duck waits for that one instant, so the strike answers the key
        // at full volume, then fades straight to silence; the bell's
        // remaining ring is shaded down with the music, which is what the
        // user chose. The duck still begins no earlier than the recording
        // being ready: whichever of the two is later wins.
        let shouldDuck = !wireless && settings.duckOtherAudio
        if shouldDuck {
            duckDelayTask?.cancel()
            if let cueAttackEnds, cueAttackEnds > ContinuousClock.now {
                let session = dictationSession
                duckDelayTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(
                            until: cueAttackEnds,
                            tolerance: .milliseconds(20),
                            clock: .continuous
                        )
                    } catch {
                        return
                    }
                    guard let self, !Task.isCancelled,
                          self.dictationSession == session, self.phase.isRecording,
                          self.settings.duckOtherAudio else { return }
                    self.audioDucker.duck(to: 0, over: Self.recordingStartDuckFade)
                }
            } else {
                // The strike has been heard, or nothing sounded at all;
                // either way there is nothing left to wait for.
                audioDucker.duck(to: 0, over: Self.recordingStartDuckFade)
            }
        }
        scheduleMaximumDurationStop()
        refreshPermissionStatuses()
        if cancelWhenRecordingBegins {
            cancelWhenRecordingBegins = false
            stopWhenRecordingBegins = false
            cancelRecording()
        } else if stopWhenRecordingBegins {
            stopWhenRecordingBegins = false
            stopAndTranscribe()
        }
    }

    /// The wait between the opening cue's deadline and the duck it releases.
    /// Cancelled whenever other audio is restored, so a stop before the bell
    /// has finished can never be followed by a duck of what just came back.
    private var duckDelayTask: Task<Void, Never>?

    /// Forgets any outstanding wait for the microphone's first audio.
    private func abandonAudioWait() {
        waitingForAudioTask?.cancel()
        waitingForAudioTask = nil
        recorder.setFirstBufferHandler(nil)
    }

    private func restoreOtherAudio() {
        // A stop can land while the duck is still waiting out the bell; the
        // wait dies first, or the duck would land on the audio just restored.
        duckDelayTask?.cancel()
        duckDelayTask = nil
        audioDucker.unduck()
    }

    /// Abandons whatever the dictation is doing, at any stage.
    ///
    /// Named for recording because that is where it began, but it is the
    /// general "stop this" path: it also cancels work in flight after the
    /// microphone has closed, which is where a stall is most likely.
    func cancelRecording() {
        // A dictation that is past recording is cancelled by cutting off the
        // work rather than the microphone.
        if !phase.isRecording, activeStream == nil, phase.isBusy {
            abandonWorkInFlight()
            return
        }
        cancelRecordingInProgress()
    }

    /// Stops any post-recording work and returns to idle.
    /// Starts the clock on a step, replacing any clock already running.
    private func beginStep(_ name: String, allowing extra: TimeInterval = 0) {
        workDeadline?.cancel()
        let session = dictationSession
        let limit = (stepLimitForTesting ?? Self.stepLimit) + .seconds(extra)
        workDeadline = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.dictationSession == session, self.phase.isBusy else { return }
                Self.workLogger.error("\(name, privacy: .public) gave up after \(limit.components.seconds, privacy: .public)s")
                self.abandonWorkInFlight()
                self.enterFailedState(RecoveryAdvice.tookTooLong(name))
            }
        }
    }

    private func endStep() {
        workDeadline?.cancel()
        workDeadline = nil
    }

    private func abandonWorkInFlight() {
        // Streamed words that already reached the overlay survive the
        // abandonment: the watchdog clearing them here, an instant before the
        // provider's own error would have preserved them, left neither
        // transcript nor recording.
        let partial = cancellationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty { keepTranscript(partial, from: dictationSession) }
        abandonLiveRecognition()
        returnBorrowedClipboard()
        consumeActiveEditReturn()
        // These describe the dictation being abandoned, and left set they
        // apply themselves to the next one: a stale practice flag silently
        // skipped its delivery, and a stale held-release flag stopped it the
        // moment it began.
        isPracticeRun = false
        stopWhenRecordingBegins = false
        cancelWhenRecordingBegins = false
        hotKeyPressStartedAt = nil
        handsFreeKey.disarm()
        // A startup still waiting its turn belongs to the press being
        // abandoned; running it later would hijack whichever press is newest.
        startupRequest += 1
        // Escape while the microphone is still opening arrives here rather
        // than in the recording path. The recorder is deliberately NOT
        // cancelled from here while it may still be starting: `start()` runs
        // off the main actor, and cancelling concurrently mutates the same
        // engine and file from two threads. Moving the session on is enough —
        // `beginRecording` re-checks it after every suspension and closes the
        // microphone itself. Only a recording that is already live, where
        // `start()` has returned, is safe to cancel directly.
        if phase.isRecording {
            recorder.cancel(holdingInputOpen: false)
        }
        if phase == .requestingPermission || phase.isRecording {
            abandonAudioWait()
        }
        endStep()
        // Cancelled first, so anything checking `Task.isCancelled` between
        // awaits stops as soon as it can rather than running to completion.
        workTask?.cancel()
        workTask = nil
        dictationSession += 1
        activeStream?.cancelled = true
        activeStream = nil
        streamInFlight?.cancelled = true
        finishWirelessDictation()
        restoreOtherAudio()
        feedbackSoundPlayer.stopWaiting()
        streamingTranscript = ""
        targetPID = nil
        endStep()
        phase = .idle
        updateCancelHotKey()
    }

    /// Stops an edit because the user moved somewhere else.
    ///
    /// Ends it outright rather than letting it finish and deliver: what the
    /// result would replace is no longer the passage it was asked about.
    private func abandonEditOnInteraction() {
        guard pendingEdit != nil || editWatcher != nil else { return }
        stopEditWatcher()
        guard phase.isRecording || phase.isBusy else { return }
        Self.workLogger.notice("edit abandoned; the selection may have changed")
        cancelRecording()
    }

    private func stopEditWatcher() {
        editWatcher?.stop()
        editWatcher = nil
    }

    /// Stops the watcher only if it is still the one `owned` — the one started
    /// for the calling task's own edit. A dictation that was cancelled and
    /// finished late calls its cleanup after a newer edit has begun, and
    /// stopping unconditionally there stripped that newer edit's protection.
    private func stopEditWatcher(ifStill owned: UserInteractionWatcher?) {
        guard let owned, editWatcher === owned else { return }
        stopEditWatcher()
    }

    /// Gives back the clipboard borrowed by an edit that is now over.
    ///
    /// Separate from `returnBorrowedClipboard` because by this point the edit
    /// has been taken out of `pendingEdit` and belongs to the dictation task;
    /// without this, cancelling or failing after transcription began left the
    /// copied selection sitting on the user's clipboard.
    private func returnEditClipboard(
        _ edit: (selection: String, clipboard: TextInjector.ClipboardContents, changeCount: Int)?,
        watcher owned: UserInteractionWatcher? = nil
    ) {
        // Only an exit that belongs to an actual edit may touch the watcher,
        // and then only the watcher started for that same edit: a nonnil edit
        // alone was not ownership, and a cancelled edit finishing late used to
        // switch off the protection of the edit that had started since.
        guard edit != nil else { return }
        stopEditWatcher(ifStill: owned)
        // Consumed through the shared stash: whoever gets there first — this
        // cleanup or an Escape that beat it — returns the snapshot through the
        // gate, and the other finds nothing to return twice.
        consumeActiveEditReturn()
    }

    /// Hands back the clipboard a voice edit borrowed to read the selection.
    ///
    /// Reading the selection takes the clipboard before a single word has been
    /// spoken, so every way out of an edit has to give it back: cancelling,
    /// failing, or stopping with nothing said. Only the successful path can
    /// leave it to the paste, which restores it afterwards itself.
    /// Stops live recognition, whatever became of the dictation.
    private func abandonLiveRecognition() {
        recorder.onBuffer = nil
        voiceDetector?.stop()
        voiceDetector = nil
        liveTranscriber?.cancel()
        liveTranscriber = nil
        // The session binding already keeps a stale snapshot from being
        // consumed, but an abandoned dictation's configuration has no
        // business outliving it either way — and neither has its draft.
        recordingConfiguration = nil
        previewSession = -1
        previewStabilizer = PreviewStabilizer()
        previewFirmWords = nil
    }

    private func returnBorrowedClipboard() {
        stopEditWatcher()
        guard let pending = pendingEdit else { return }
        pendingEdit = nil
        textInjector.giveBackBorrowed(pending.clipboard, ifUnchangedFrom: pending.changeCount)
    }

    private func cancelRecordingInProgress() {
        // Same reasoning as stopAndTranscribe: the engine is mid-open. But a
        // voice segment records through the listener's own engine, not the
        // recorder a stale startup is holding, so its Escape proceeds — the
        // deferral once parked it behind a permission prompt that might never
        // be answered.
        guard !startupActive || !phase.isRecording || !recordingUsesRecorder else {
            cancelWhenRecordingBegins = true
            return
        }
        abandonLiveRecognition()
        returnBorrowedClipboard()
        consumeActiveEditReturn()
        // A cancelled recording is not a try-out any more, and a release of a
        // key whose press was already abandoned must not stop whatever is live
        // by the time it arrives.
        isPracticeRun = false
        hotKeyPressStartedAt = nil
        handsFreeKey.disarm()
        // A cancelled dictation plays no closing cue, so nothing else would
        // ever let the headset go.
        finishWirelessDictation()
        // If we were still waiting for the microphone to produce audio, that
        // wait is over too: without this the pending handler or its deadline
        // would later announce a recording that has been stopped.
        abandonAudioWait()
        restoreOtherAudio()
        // The words on the overlay survive a deliberate Escape just as they
        // survive the watchdog: the session bump below would otherwise gate
        // the provider's own preservation out, and the audio is deleted when
        // the task ends.
        let partial = cancellationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty { keepTranscript(partial, from: dictationSession) }
        streamingTranscript = ""
        // Whatever the streaming mode, the delivery about to happen must not.
        streamInFlight?.cancelled = true
        // Words are being typed into another app right now, so stopping that
        // matters more than the recording state below.
        if let activeStream {
            activeStream.cancelled = true
            self.activeStream = nil
            // Claimed on the way out. Idling without moving the session on is
            // what let this dictation's late reports pass ownership checks
            // against the dictation the user started next.
            dictationSession += 1
            // The work itself has to stop, not just be ignored. A cloud rewrite
            // left running only wastes a request, but a local one holds the GPU
            // and the engine's queue, so the next dictation would wait behind a
            // rewrite the user already abandoned.
            workTask?.cancel()
            workTask = nil
            updateCancelHotKey()
            if !phase.isRecording {
                endStep()
                phase = .idle
                return
            }
        }
        guard case .recording = phase else { return }
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        stopWhenRecordingBegins = false
        cancelWhenRecordingBegins = false
        if !recordingUsesRecorder {
            // Keyed on what the recording actually captures through, not on
            // voiceSegmentInFlight: a settings change can clear that flag
            // mid-segment, and this branch then fell through to
            // recorder.cancel() while an abandoned manual start() could still
            // be inside the engine — the exact two-thread mutation the startup
            // chain exists to prevent.
            //
            // Bumping the generation makes any write already queued for this
            // segment land as stale, so it cannot transcribe into whatever the
            // user starts next.
            voiceSegmentGeneration += 1
            voiceListener.abortSegment()
            voiceSegmentInFlight = false
        } else {
            recorder.cancel()
        }
        targetPID = nil
        activeInputDeviceName = nil
        inputLevel = 0
        endStep()
        phase = .idle
    }

    func clearError() {
        recovery = nil
        if case .failed = phase { phase = .idle }
    }

    func copyLastTranscript() {
        guard !lastTranscript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    /// Assign only on change. This runs on a timer while a window is open, and
    /// an unconditional write to four @Published properties several times a
    /// second re-renders every view observing AppState — including the status
    /// item, whose redraw is expensive.
    func refreshPermissionStatuses() {
        let microphone = Self.microphoneDescription(AudioRecorder.microphoneAuthorizationStatus)
        if microphoneStatus != microphone { microphoneStatus = microphone }

        let speech = Self.speechDescription(AppleSpeechTranscriber.authorizationStatus)
        if speechStatus != speech { speechStatus = speech }

        let accessibility = TextInjector.isAccessibilityTrusted ? "Granted" : "Not granted"
        if accessibilityStatus != accessibility { accessibilityStatus = accessibility }
        let monitoring = inputMonitoringPermission.isGranted
        if inputMonitoringGranted != monitoring { inputMonitoringGranted = monitoring }
        let issues = PermissionIssue.missing(
            microphone: microphoneGranted, speech: speechGranted,
            accessibility: accessibility == "Granted", inputMonitoring: monitoring,
            provider: settings.provider, modifierOnlyShortcut: settings.shortcut.isModifierOnly,
            automaticPaste: settings.automaticPasteEnabled
        )
        if permissionIssues != issues {
            permissionIssues = issues
            updateMenuBar()
        }
        if let resolved = recovery?.permissionIssue, !issues.contains(resolved) { clearError() }
        if let helped = permissionDragHelper.issue {
            let granted: Bool
            switch helped {
            case .accessibility: granted = accessibility == "Granted"
            case .inputMonitoring: granted = monitoring
            default: granted = false
            }
            if granted { permissionDragHelper.dismiss() }
        }
        if settings.shortcut.isModifierOnly, inputMonitoringGranted, !hotKeyManager.isRegistered {
            registerHotKey(settings.shortcut)
        } else if settings.shortcut.isModifierOnly, !inputMonitoringGranted, hotKeyRegistered {
            hotKeyManager.unregister()
            hotKeyRegistered = false
            hotKeyError = HotKeyRegistrationError.inputMonitoringRequired.localizedDescription
        }
    }

    /// Separate from the permission poll: reading it is a synchronous XPC call
    /// to the service-management daemon, far too costly to run on a timer, and
    /// it only changes when this app changes it.
    func refreshLaunchAtLoginStatus() {
        let enabled = SMAppService.mainApp.status == .enabled
        if launchAtLoginEnabled != enabled { launchAtLoginEnabled = enabled }
    }

    func refreshAudioInputDevices() {
        do {
            inputDevices = try AudioInputDeviceManager.inputDevices()
            inputDeviceError = inputDevices.isEmpty
                ? AudioInputDeviceError.noInputDevices.localizedDescription
                : nil
        } catch {
            inputDevices = []
            inputDeviceError = error.localizedDescription
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = enabled
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            enterFailedState(RecoveryAdvice(message: "Launch at Login could not be changed: \(error.localizedDescription)"))
        }
    }

    func openPrivacySettings(_ pane: PrivacyPane) {
        guard let url = URL(string: pane.urlString) else { return }
        if permissionReturnFlow.destination == nil { _ = beginPermissionInteraction() }
        // Dropped before System Settings opens. The float is for the dialog
        // our own process raises, which appears over everything anyway;
        // holding it through this route would park our window on top of the
        // pane we have just sent the user to.
        floatDuringPermissionInteraction(false)
        permissionReturnFlow.openedSystemSettings()
        if NSWorkspace.shared.open(url) {
            permissionReturnFlow.externalAppActivated(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        } else {
            let destination = permissionReturnFlow.destination
            permissionReturnFlow.cancel()
            if let destination { restorePermissionWindow(destination) }
        }
    }

    private func beginRecording() async {
        #if DEBUG
        DuckTrace.mark("beginRecording entered")
        #endif
        // Two tokens, because this function spans the moment the dictation
        // claims its own number. Before that it is still the previous
        // dictation's, and comparing against the one taken afterwards is what
        // stopped recording from ever starting.
        let entrySession = dictationSession
        // Set once the increment below claims a session, so the catch can tell
        // whether the failure it is handling still owns anything. A denied
        // permission prompt can be answered minutes later, after the user has
        // long since cancelled and started something else, and tearing that
        // something else down was the bug.
        var claimedSession: Int?
        // The one gate. Every route into a dictation reaches this function, so
        // checking here means no path can miss it, and the check is a cached
        // read rather than a network call, so it costs nothing.
        licence.refreshState()
        guard licence.state.allowsDictation else {
            enterFailedState(RecoveryAdvice.licenceRequired(licence.state))
            showSettings(selecting: .licence)
            return
        }

        // Closing the panel first matters: while it is open MicMyDay is the
        // frontmost app, so the target never truly regains key focus and the
        // paste keystroke lands nowhere. Dictation started from the panel used
        // to report "Pasted into <app>" for text that went nowhere at all.
        dismissMenuBarPanel()

        // The wired opening cue answers the keypress, so it sounds here, in
        // the synchronous stretch before any permission or engine work, and
        // only its play-return deadline travels onwards: `goLive` starts the
        // duck at whichever comes later, the recording being ready or that
        // deadline. The licence gate above has already passed, so a bell here
        // never announces a dictation that was refused; a microphone or
        // engine failure after it is answered by the failure sound, which
        // stops this one. Wireless keeps its own cue further down, because
        // its cue must go out over the route that still exists before the
        // microphone flips the headset into its other profile.
        let wirelessAtKeypress = (try? AudioInputDeviceManager.resolveInputDevice(
            uid: settings.inputDeviceUID
        ))?.isWireless ?? false
        var openingCueAttackEnds: ContinuousClock.Instant?
        if !wirelessAtKeypress, settings.playFeedbackSounds {
            #if DEBUG
            DuckTrace.mark("asking for the opening cue")
            openingCueAttackEnds = feedbackSoundPlayer.playRecordingStart {
                DuckTrace.mark("opening cue reported finished")
            }
            #else
            openingCueAttackEnds = feedbackSoundPlayer.playRecordingStart()
            #endif
        }

        do {
            guard await AudioRecorder.requestMicrophoneAccess() else {
                throw AudioRecorderError.microphoneDenied
            }
            #if DEBUG
            DuckTrace.mark("microphone access confirmed")
            #endif
            // Answering a permission prompt can take as long as the user likes,
            // and Escape during it ends this dictation. Checked after every
            // suspension, so a late "allow" cannot open the microphone for
            // something that is already over, or disturb whatever replaced it.
            guard dictationSession == entrySession, phase == .requestingPermission else { return }

            if settings.provider == .appleSpeech {
                guard await AppleSpeechTranscriber.requestAuthorization() == .authorized else {
                    throw TranscriptionError.speechPermissionDenied
                }
                guard dictationSession == entrySession, phase == .requestingPermission else { return }
            }
            // A previous dictation may still be holding a headset open for its
            // closing cue. Retire it here, before the recorder is touched:
            // otherwise its callback lands during the await below and stops the
            // recording that is just starting, and its hold timer stays armed
            // and stops the new one ninety seconds in.
            finishWirelessDictation()
            abandonAudioWait()
            audioIsFlowing = false
            openingCueFinished = false
            dictationSession += 1
            // Captured here, after the increment that starts this dictation,
            // and not on entry: taken earlier it was the *previous* dictation's
            // number, every guard below compared unequal, and recording could
            // never start at all.
            //
            // Permission prompts suspend for as long as the user takes to
            // answer, and Escape in the meantime moves this on, so the checks
            // that follow are what stop a late "allow" opening the microphone
            // for a dictation that is already over.
            let startingSession = dictationSession
            claimedSession = startingSession

            // Not for an edit: its target is the app the selection was read
            // from, captured before recording, and the user may well have moved
            // on by now. Overwriting it here pasted the result into whatever
            // was frontmost instead, replacing whatever was selected there.
            if pendingEdit == nil {
                targetPID = currentExternalApplicationPID()
            }
            inputLevel = 0

            // Resolved again here, after the permission awaits: a prompt can
            // stay open as long as the user likes, and the input can change
            // under it. The keypress cue already sounded on the earlier
            // answer; the wake, the route flag and the first-buffer handler
            // below follow the device as it is now.
            let wirelessAhead = (try? AudioInputDeviceManager.resolveInputDevice(
                uid: settings.inputDeviceUID
            ))?.isWireless ?? false

            // Before the microphone: played over the music route, which still
            // exists and can be woken. The route that replaces it cannot. If
            // the wired bell already answered this keypress because the
            // device only became wireless while a permission prompt sat open,
            // a second start cue would be one start too many, so this is
            // skipped and the else below marks the cue done.
            if wirelessAhead, settings.playFeedbackSounds, openingCueAttackEnds == nil {
                let session = dictationSession
                feedbackSoundPlayer.wakeWirelessOutput { [weak self] in
                    Task { @MainActor in
                        guard let self, self.dictationSession == session else { return }
                        self.openingCueFinished = true
                        self.goLiveIfReady()
                    }
                }
            } else {
                // The reverse of the race above: the device read wireless at
                // the keypress, so no bell answered it, and now it is wired.
                // A late bell beats a start that makes no sound at all.
                if !wirelessAhead, openingCueAttackEnds == nil, settings.playFeedbackSounds {
                    #if DEBUG
                    DuckTrace.mark("asking for the opening cue (late, device turned wired)")
                    #endif
                    openingCueAttackEnds = feedbackSoundPlayer.playRecordingStart()
                }
                // Nothing further will sound, so there is nothing to wait for.
                openingCueFinished = true
            }

            // Installed before starting, because a headset can deliver its
            // first buffer while `start()` is still returning. On a wired
            // device this never fires usefully: that path goes live as soon as
            // `start()` returns, and `goLive` ignores a second call.
            let session = dictationSession
            // Set before the microphone opens, not after. The first buffer can
            // arrive while `start()` is still returning, and a cue fired before
            // this flag was set went out through the wired path, on a route
            // that was mid-switch, where nothing could hear it.
            feedbackSoundPlayer.usesWirelessRoute = wirelessAhead

            recorder.setFirstBufferHandler { [weak self] in
                guard let self, self.dictationSession == session else { return }
                // Wired devices go live when start() returns, with their cue
                // and the ducking sequenced behind it. A wired first buffer
                // arriving before that return used to go live through the
                // wireless path instead: no cue, no duck, and the real
                // go-live then found recording already begun and did nothing.
                guard wirelessAhead else { return }
                // Half of what the overlay waits for. The other half is the
                // opening cue finishing. Going live on this alone made the
                // spinner flash past in a fraction of a second while the cue
                // was still a second away, so the two never agreed.
                self.audioIsFlowing = true
                self.goLiveIfReady()
            }

            guard dictationSession == startingSession, phase == .requestingPermission else { return }
            startLiveRecognitionIfAvailable()

            #if DEBUG
            DuckTrace.mark("recorder.start() called")
            #endif
            let inputDevice = try await recorder.start(
                inputDeviceUID: settings.inputDeviceUID,
                silenceAutoStopSeconds: settings.autoStopOnSilence ? settings.silenceStopSeconds : 0
            )
            #if DEBUG
            DuckTrace.mark("recorder.start() returned")
            #endif
            // Opening the device suspends too, and on a wireless headset for
            // a noticeable time. Anything cancelled in that window gets the
            // microphone closed again rather than left running.
            guard dictationSession == startingSession,
                  phase == .requestingPermission || phase.isRecording else {
                recorder.cancel(holdingInputOpen: false)
                abandonLiveRecognition()
                return
            }
            // The microphone is held open until the last cue has been heard.
            // Releasing it makes macOS switch the headset out of its microphone
            // profile, and that switch destroys whatever cue is playing.
            holdingWirelessInput = inputDevice.isWireless
            // Corrects the guess above in the rare case the resolved device is
            // not the one that opened.
            feedbackSoundPlayer.usesWirelessRoute = inputDevice.isWireless
            // Nothing at all is done to other audio on a wireless headset. Not
            // ducked, not paused. The Bluetooth link already drops whatever is
            // playing to headset quality for the length of the recording, so
            // there is little left to quieten, and every attempt to manage it
            // made the behaviour less predictable rather than more.
            // Ducking is not started here any more. It has to follow the
            // opening cue rather than run alongside it, so `goLive` starts it
            // at the cue's deadline, which travelled here from the keypress.
            activeInputDeviceName = inputDevice.name

            if inputDevice.isWireless {
                // Wait for audio to genuinely flow before saying so. `start()`
                // returning means the graph was built; on a wireless headset
                // the link then takes about a second to finish switching into
                // its microphone profile, and a cue played during that second
                // is either torn or never heard. The first buffer is the event
                // that says the switch is done, so the chime and the end of the
                // spinner happen together, and the chime means what it says.
                //
                // Bounded, but running out only stops the waiting. The
                // recording is already running by this point, and an earlier
                // version of this treated the deadline as proof that the
                // microphone had failed and cancelled the dictation: it threw
                // away perfectly good recordings whenever a headset took its
                // time. Nothing is claimed by giving up here, because a
                // wireless dictation sounds no cue at this moment anyway, so
                // the only thing that changes is that the spinner stops hiding
                // a recording that is working.
                waitingForAudioTask?.cancel()
                waitingForAudioTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.firstBufferLimit)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard let self, self.dictationSession == session else { return }
                        guard case .requestingPermission = self.phase else { return }
                        Self.audioLogger.info("no audio yet from \(inputDevice.name, privacy: .public), showing the recording anyway")
                        // Deliberately silent. This is not the readiness event,
                        // it is only the point at which a spinner stops being
                        // useful, and sounding the cue here would be claiming
                        // something that has not happened.
                        self.audioIsFlowing = true
                        self.openingCueFinished = true
                        self.goLiveIfReady()
                    }
                }
            } else {
                // Wired devices are listening by the time `start()` returns, so
                // nothing is gained by waiting and the cue keeps its old timing.
                goLive(startedAt: Date(), cueAttackEnds: openingCueAttackEnds, wireless: false)
            }
        } catch {
            // Only the startup that still owns the dictation may clean up.
            // After the increment that is the claimed session; before it, the
            // entry token together with a phase only this startup could have
            // set. A stale failure without either has nothing here that is
            // its to touch.
            let owns = claimedSession.map { dictationSession == $0 }
                ?? (dictationSession == entrySession && phase == .requestingPermission)
            guard owns else {
                Self.workLogger.notice("stale startup failure ignored; a newer dictation owns the state")
                return
            }
            stopWhenRecordingBegins = false
            cancelWhenRecordingBegins = false
            abandonAudioWait()
            finishWirelessDictation()
            restoreOtherAudio()
            recorder.cancel()
            targetPID = nil
            activeInputDeviceName = nil
            inputLevel = 0
            enterFailedState(RecoveryAdvice.advice(for: error))
            refreshPermissionStatuses()
        }
    }

    /// Failing must be audible: without a cue, a user who started dictating
    /// and switched windows keeps talking to a recording that already died.
    /// Arms both cycle shortcuts and every per-profile shortcut.
    ///
    /// Profile shortcuts are one press: they select the profile and start
    /// dictating, so the rewrite happens with that profile without switching
    /// first. The cycle shortcuts only move the selection.
    func refreshActionShortcuts() {
        var shortcuts: [String: KeyboardShortcut] = [:]
        if let cycle = settings.cycleProfilesShortcut {
            shortcuts["cycle"] = cycle
        }
        if let previous = settings.previousProfileShortcut {
            shortcuts["cyclePrevious"] = previous
        }
        if let edit = settings.editSelectionShortcut {
            shortcuts["edit"] = edit
        }
        if let again = settings.insertAgainShortcut {
            shortcuts["again"] = again
        }
        for profile in settings.rewriteProfiles {
            if let shortcut = settings.profileShortcuts[profile.id] {
                shortcuts["profile:\(profile.id)"] = shortcut
            }
        }
        actionHotKeys.register(shortcuts)
    }

    private func handleActionShortcut(_ action: String) {
        if action == "cycle" || action == "cyclePrevious" {
            guard let profile = settings.cycleRewriteProfile(backwards: action == "cyclePrevious") else { return }
            announceProfile(profile.name)
            return
        }
        if action == "again" {
            insertLastTranscriptAgain()
            return
        }
        if action == "edit" {
            beginVoiceEdit()
            return
        }
        guard action.hasPrefix("profile:") else { return }
        let id = String(action.dropFirst("profile:".count))
        guard settings.rewriteProfiles.contains(where: { $0.id == id }) else { return }
        settings.rewriteProfileID = id
        guard phase == .idle else { return }
        toggleRecording()
    }

    /// Puts the last transcript in wherever the cursor is now.
    ///
    /// For the dictation that went to the wrong window. Restoring the clipboard
    /// means the transcript is no longer sitting there to be pasted again, so
    /// this is what recovers it, and unlike the clipboard it survives having
    /// copied something since.
    ///
    /// Deliberately does nothing while a dictation is running: the text is
    /// about to be delivered anyway, and inserting the previous one into the
    /// middle of that would be its own kind of mess.
    private func insertLastTranscriptAgain() {
        guard !phase.isRecording, !phase.isBusy, !insertingAgain, !capturingSelection else { return }
        // A kept edit is inserted exactly as it was delivered; trimming it
        // here re-broke the whitespace the whole edit pipeline preserves.
        let exact = lastTranscriptExact
        let text = exact ? lastTranscript : lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            enterFailedState(RecoveryAdvice(
                message: "There is no transcript to insert yet."
            ))
            return
        }
        guard let target = currentExternalApplicationPID() else {
            enterFailedState(RecoveryAdvice(
                message: "Inserting again needs another app in front to type into. Click where the text should go, then press the shortcut."
            ))
            return
        }

        let restores = settings.restoreClipboardAfterPaste
        let appendsSpace = settings.appendTrailingSpace
        insertingAgain = true
        Task { @MainActor in
            defer { insertingAgain = false }
            // No auto-send: this is a repair, and the user is placing the text
            // somewhere it did not land the first time. Pressing Return for
            // them at that moment could submit something twice.
            let session = dictationSession
            let delivery: TextDeliveryResult?
            do {
                delivery = try await textInjector.insert(
                    text,
                    targetPID: target,
                    appendTrailingSpace: appendsSpace,
                    autoSend: .off,
                    restoreClipboard: restores,
                    insertExactly: exact,
                    shouldProceed: { [weak self] in
                        guard let self else { return false }
                        return self.dictationSession == session && !self.phase.isRecording
                    }
                )
            } catch {
                // Deliberately no clipboard write here. One of the ways insert
                // can throw is precisely that the user copied something during
                // the wait, and "recovering" by writing the transcript over
                // their copy is the loss this whole mechanism exists to avoid.
                // The transcript stays reachable through this same shortcut.
                enterFailedState(RecoveryAdvice.advice(for: error))
                refreshOverlay()
                return
            }
            let name = NSRunningApplication(processIdentifier: target)?.localizedName
            switch delivery {
            case .pastedAndCopied, .pasted:
                lastDelivery = .pasted(appName: name)
            case .copiedOnly:
                lastDelivery = .clipboardOnly
            default:
                lastDelivery = .pasted(appName: name)
            }
            refreshOverlay()
        }
    }

    /// Reads the selection in the focused app, then records what to do with it.
    ///
    /// Rewriting has to be configured, because the instruction is carried out
    /// by a model; without one there is nothing to apply. Said plainly rather
    /// than failing at the end, when the user has already spoken.
    private func beginVoiceEdit() {
        // .failed is a fine place to start from, exactly as it is for an
        // ordinary dictation; requiring .idle made the shortcut silently dead
        // after any error until something else cleared it.
        let startable: Bool
        switch phase {
        case .idle, .failed: startable = true
        default: startable = false
        }
        guard startable, !capturingSelection, !insertingAgain else { return }
        // Said before anything is touched: captureSelection returning nothing
        // for a missing permission used to be reported as "nothing selected",
        // which sends the user hunting in the wrong place entirely.
        guard AXIsProcessTrusted() else {
            enterFailedState(RecoveryAdvice(
                message: "Editing by voice needs Accessibility access, which reads the selection and types the result.",
                offersAccessibility: true
            ))
            return
        }
        guard settings.enhancementEnabled, settings.rewriteProviderIsConfigured else {
            enterFailedState(RecoveryAdvice(
                message: "Editing by voice needs rewriting switched on, since a model is what carries out the instruction."
            ))
            return
        }
        guard settings.automaticPasteEnabled else {
            enterFailedState(RecoveryAdvice(
                message: "Editing by voice replaces the selection for you, which needs automatic pasting switched on."
            ))
            return
        }
        guard let target = currentExternalApplicationPID() else {
            enterFailedState(RecoveryAdvice(
                message: "Editing by voice needs another app in front, since the selection lives there. Click into the text you want changed, then press the shortcut."
            ))
            return
        }

        capturingSelection = true
        // Watching starts before the selection is read, not after: the copy
        // polls for up to a second, and a click in that window changes what the
        // edit would later replace. Anything the user does from here to
        // delivery ends the edit.
        let watcher = UserInteractionWatcher()
        watcher.exemptWindow = { [weak self] in self?.overlayController.window }
        editWatcher = watcher
        watcher.start { [weak self] in
            Task { @MainActor in
                guard let self, self.editWatcher === watcher else { return }
                self.abandonEditOnInteraction()
            }
        }
        Task { @MainActor in
            defer { capturingSelection = false }
            let captured = await textInjector.captureSelection(targetPID: target)

            // Reading the selection takes time, and anything could have
            // happened in it. Checked before either branch touches state, so a
            // late answer cannot disturb a dictation already under way.
            let stillStartable: Bool
            switch phase {
            case .idle, .failed: stillStartable = true
            default: stillStartable = false
            }
            guard stillStartable, editWatcher === watcher else {
                stopEditWatcher()
                if let captured {
                    textInjector.giveBackBorrowed(captured.clipboard, ifUnchangedFrom: captured.changeCount)
                }
                return
            }
            guard let captured else {
                stopEditWatcher()
                enterFailedState(RecoveryAdvice(
                    message: "Nothing is selected. Select the text you want changed, then press the shortcut."
                ))
                return
            }
            pendingEdit = (captured.text, captured.clipboard, captured.changeCount)
            targetPID = target
            // Cleared before starting, not by the defer below: recording is
            // guarded on this flag, so leaving it set until the task unwound
            // meant the edit read the selection and then silently refused to
            // record a word about it.
            capturingSelection = false
            toggleRecording()
        }
    }

    /// Whether the selected engine can produce words while the user is still
    /// speaking. The preview panel only exists for engines that can: with a
    /// batch engine the words would appear in the same instant the real text
    /// lands in the target app, which previews nothing. The same three
    /// conditions gate `startLiveRecognitionIfAvailable`, and they must stay
    /// in step or the panel promises words that never come.
    private var engineStreamsWhileSpeaking: Bool {
        if settings.provider == .appleSpeech {
            return settings.streamingMode != .off && settings.preferOnDevice
        }
        if settings.provider.isLocalModel,
           let model = WhisperModelCatalog.model(withID: settings.whisperModelID) {
            if model.engine == .nemotron { return NemotronEngine.isReady(model.id) }
            // The same installation test the selection makes, so the panel
            // never promises words a missing model cannot produce.
            return (model.engine == .whisper || model.engine == .parakeet)
                && WhisperModelManager.isInstalled(modelID: model.id)
        }
        return false
    }

    /// What a cancelled dictation should keep: the engine's own last words,
    /// not the possibly-truncated text on screen. The panel may be holding
    /// back a revision when Escape lands, and insert-again must reproduce
    /// what was recognised, not what happened to be displayed.
    private var cancellationDraft: String {
        if previewSession == dictationSession, !previewStabilizer.latestHeard.isEmpty {
            return previewStabilizer.latestHeard
        }
        return streamingTranscript
    }


    /// The pill and its preview panel share an edge with the screen; the
    /// panel's text lines up with whichever side that is.
    private var overlayPreviewAlignment: HorizontalAlignment {
        switch settings.overlayPosition.horizontal {
        case .leading: return .leading
        case .centre: return .center
        case .trailing: return .trailing
        }
    }

    /// The overlay's profile picker: the same selection and the same toast as
    /// the cycle shortcut, so every way of switching feels identical.
    private func selectProfileFromOverlay(_ id: String) {
        guard settings.rewriteProfiles.contains(where: { $0.id == id }) else { return }
        guard settings.rewriteProfileID != id else { return }
        settings.rewriteProfileID = id
        if let name = settings.currentRewriteProfile?.name {
            announceProfile(name)
        }
    }

    /// The Carbon modifier mask the system sees while the dictation
    /// shortcut is held: its declared modifiers, plus the held key itself
    /// when that key IS a modifier — the default shortcut is a bare Right
    /// Shift, which arrives at the hot-key matcher as shift-Space.
    private var heldShortcutCarbonModifiers: UInt32 {
        let shortcut = settings.shortcut
        var mask = shortcut.modifiers
        switch Int(shortcut.keyCode) {
        case kVK_Command, kVK_RightCommand: mask |= UInt32(cmdKey)
        case kVK_Shift, kVK_RightShift: mask |= UInt32(shiftKey)
        case kVK_Option, kVK_RightOption: mask |= UInt32(optionKey)
        case kVK_Control, kVK_RightControl: mask |= UInt32(controlKey)
        default: break
        }
        return mask
    }

    /// Space during a held shortcut: the hold becomes an ordinary toggled
    /// recording, so the keys can be released mid-take. Stopping is then the
    /// shortcut again, or Escape. Works during startup too — a hold whose
    /// microphone is still opening upgrades the same way, and the eventual
    /// release finds nothing to act on.
    private func upgradeHoldToHandsFree() {
        guard hotKeyPressStartedAt != nil else { return }
        guard phase.isRecording || phase == .requestingPermission else { return }
        hotKeyPressStartedAt = nil
        handsFreeKey.disarm()
        showOverlayNote("Hands-free")
    }

    /// Shows a short-lived chip on the recording pill, where the armed
    /// profile normally sits. An upgrade during startup gets longer: the
    /// chip only renders once the pill is in its recording state, and a
    /// slow microphone would otherwise consume the whole showing unseen.
    private func showOverlayNote(_ text: String) {
        overlayNoteText = text
        overlayNoteTask?.cancel()
        let lifetime: UInt64 = phase.isRecording ? 1_700_000_000 : 4_000_000_000
        overlayNoteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: lifetime)
            guard !Task.isCancelled, let self else { return }
            self.overlayNoteText = nil
            self.refreshOverlay()
        }
        refreshOverlay()
    }

    /// Names the newly-selected profile on the overlay for 1700 ms.
    ///
    /// The timer is cancelled and restarted on every switch, so cycling quickly
    /// reads as one continuously-updating overlay rather than a queue of
    /// stacked notifications.
    func announceProfile(_ name: String) {
        activeProfileNote = name
        profileToastTask?.cancel()
        profileToastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            guard !Task.isCancelled, let self else { return }
            self.activeProfileNote = nil
            self.refreshOverlay()
        }
        refreshOverlay()
    }

    func setOverlayPreviewing(_ previewing: Bool) {
        overlayPreviewing = previewing
        overlayPreviewTask?.cancel()
        if previewing {
            // A still meter would misrepresent the thing being configured.
            overlayPreviewTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 110_000_000)
                    guard let self, self.overlayPreviewing else { return }
                    self.refreshOverlay()
                }
            }
        }
        refreshOverlay()
    }

    /// Recording beats busy beats toast, so a take in progress is never hidden.
    func refreshOverlay() {
        guard settings.overlayEnabled else {
            overlayController.hide()
            return
        }

        let content: OverlayContent?
        if phase.isRecording {
            content = .recording
        } else if phase == .requestingPermission {
            content = showStartingOverlay ? .starting : nil
        } else if phase.isBusy {
            content = .busy(phase)
        } else if let note = activeProfileNote {
            content = .profileToast(note)
        } else if overlayPreviewing {
            content = .recording
        } else {
            content = nil
        }

        guard let content else {
            stopOverlayTicking()
            // A move belongs to the take it was made during, so it goes when
            // the indicator does rather than following it into the next one.
            overlayController.clearDrag()
            overlayController.hide()
            return
        }

        // The meter and the timer are read at render time, so without a tick
        // the overlay froze on whatever level it happened to have when
        // recording started — a pulsing badge above a dead meter.
        if content == .recording {
            startOverlayTicking()
        } else {
            stopOverlayTicking()
        }

        let profile = settings.currentRewriteProfile

        // A dictation is under way, so the badge stops it and the profile
        // indicator picks; the panel accepts clicks only then. Judged from
        // the real phase alone: the Settings pane being open must not strip
        // the controls off a genuine recording happening under it.
        let controllable = phase.isRecording
            || phase == .requestingPermission || phase.isBusy
        // Only while a dictation is actually running: the Settings pane's
        // synthetic preview must never display a real transcript, least of
        // all one from a take that was cancelled.
        let finalText = controllable && overlayFinalTextSession == dictationSession
            ? overlayFinalText
            : ""
        let profileItems: [OverlayProfileItem] = settings.enhancementEnabled
            ? settings.rewriteProfiles.map { item in
                OverlayProfileItem(
                    id: item.id,
                    name: item.name,
                    symbol: settings.icon(forProfile: item.id).symbol,
                    shortcut: settings.profileShortcuts[item.id]?.displayString,
                    isActive: item.id == settings.rewriteProfileID
                )
            }
            : []

        let view = RecordingOverlay(
            content: content,
            style: settings.overlayStyle,
            dockStyle: settings.overlayDockStyle,
            size: settings.overlaySize,
            level: overlayPreviewing && !phase.isRecording ? Double.random(in: 0.25...0.85) : Double(inputLevel),
            elapsed: overlayElapsed,
            profileName: settings.enhancementEnabled ? profile?.name : nil,
            profileShortcut: profile.flatMap { settings.profileShortcuts[$0.id]?.displayString },
            profileSymbol: profile.map { settings.icon(forProfile: $0.id).symbol } ?? ProfileIcon.fallback.symbol,
            engineName: overlayEngineName,
            progress: overlayProgress,
            noteText: overlayNoteText,
            streamingText: streamingTranscript,
            livePreviewEnabled: settings.overlayLivePreview
                && (engineStreamsWhileSpeaking || (overlayPreviewing && !controllable)),
            // The pane's preview shows a sample sentence, so the toggle can be
            // judged without dictating; a real take shows the words so far,
            // then the settled text once it exists.
            livePreviewText: overlayPreviewing && !controllable
                ? "The words you say appear here, a moment before they land in your app."
                : overlayWords(final: finalText),
            livePreviewFirm: !finalText.isEmpty || (overlayPreviewing && !controllable),
            livePreviewFirmWords: previewSession == dictationSession ? previewFirmWords : nil,
            previewBelow: settings.overlayPosition.vertical == .top,
            take: dictationSession,
            previewAlignment: overlayPreviewAlignment,
            profiles: controllable ? profileItems : [],
            onSelectProfile: controllable
                ? { [weak self] id in self?.selectProfileFromOverlay(id) }
                : nil,
            onStop: controllable
                ? { [weak self] in self?.cancelRecording() }
                : nil,
            // Draggable only while it is accepting clicks at all, which is
            // while a take is running. There is nothing to get out of the way
            // of once it has stopped.
            onDrag: controllable
                ? { [weak self] translation in self?.overlayController.moveBy(translation) }
                : nil
        )
        overlayController.update(
            view,
            size: settings.overlaySize,
            position: settings.overlayPosition,
            opacity: settings.effectiveOverlayOpacity,
            interactive: controllable
        )
    }

    /// ~10 Hz, matching AudioScope.md: the meter's own 120 ms ease-out does the
    /// smoothing, so sampling faster only costs redraws.
    private func startOverlayTicking() {
        guard overlayTickTask == nil else { return }
        overlayTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 110_000_000)
                guard let self, self.phase.isRecording || self.phase == .requestingPermission else { break }
                self.refreshOverlay()
            }
            // Exiting without clearing the handle left a dead task in place, so
            // the next real recording could never start its ticker and the
            // overlay's meter and timer stayed frozen. Re-checking the phase
            // avoids clobbering a ticker that a new recording just started.
            guard let self, !(self.phase.isRecording || self.phase == .requestingPermission) else { return }
            self.overlayTickTask = nil
        }
    }

    private func stopOverlayTicking() {
        overlayTickTask?.cancel()
        overlayTickTask = nil
    }

    private var overlayElapsed: String {
        guard case .recording(let startedAt) = phase else { return "0:00" }
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// How far through the maximum a take has run, or nil when there is
    /// nothing to be a fraction of.
    ///
    /// The maximum exists so a recording cannot run forever unnoticed, which
    /// means the moment it matters is the moment it is nearly reached. A line
    /// filling along the bottom edge says that without a number to read: at a
    /// glance it is empty, and only worth looking at when it is not.
    private var overlayProgress: Double? {
        guard settings.overlayElapsedLine, settings.overlayStyle == .dock else { return nil }
        guard case .recording(let startedAt) = phase else { return nil }
        let limit = Double(settings.maximumRecordingSeconds)
        guard limit > 0 else { return nil }
        return min(1, max(0, Date().timeIntervalSince(startedAt) / limit))
    }

    private var overlayEngineName: String {
        guard settings.provider.isLocalModel else { return settings.provider.title }
        return WhisperModelCatalog.model(withID: settings.whisperModelID)?.displayName ?? settings.provider.title
    }

    /// Drives the phase directly for the Settings → States pane. A development
    /// aid: nothing is recorded, and the next real dictation overwrites it.
    func previewPhase(_ phase: AppPhase) {
        if case .failed(let message) = phase {
            recovery = RecoveryAdvice(message: message)
        }
        self.phase = phase
    }

    /// Roughly how long the recording is, so transcription is not cut off for
    /// being long rather than for being stuck.
    private func audioDuration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
            return 0
        }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    private func enterFailedState(_ advice: RecoveryAdvice) {
        abandonLiveRecognition()
        returnBorrowedClipboard()
        // A dictation that failed before recording began must not leave a
        // held-release or try-out flag armed for the next one: an unlicensed
        // fast hold-release used to stop the very next dictation the moment it
        // went live.
        isPracticeRun = false
        stopWhenRecordingBegins = false
        cancelWhenRecordingBegins = false
        endStep()
        // A failure is an exit path too, and the one most likely to be reached
        // from somewhere unexpected.
        //
        restoreOtherAudio()
        feedbackSoundPlayer.stopWaiting()
        if settings.playFeedbackSounds {
            let session = dictationSession
            feedbackSoundPlayer.playFailure { [weak self] in
                self?.finishWirelessDictation(session: session)
            }
        } else {
            finishWirelessDictation()
        }
        recovery = advice
        streamingTranscript = ""
        phase = .failed(advice.message)
    }

    /// Starts recognising the microphone as it is captured, where that is
    /// possible and wanted.
    ///
    /// Only Apple's engine accepts a live stream; the rest take a finished
    /// recording, which is why live text elsewhere can only ever begin once the
    /// user has stopped talking. Nothing is promised here: if a recogniser
    /// cannot be made, the dictation proceeds exactly as it did before and the
    /// recording is transcribed at the end as usual.
    private func startLiveRecognitionIfAvailable() {
        liveTranscriber = nil
        // Started before any recogniser, and independent of whether one is
        // made at all: a take with no live preview still has to be judged
        // before it is transcribed.
        let detector: VoiceActivityDetector?
        if settings.requireVoiceActivity, VoiceActivityDetector.isModelAvailable {
            detector = VoiceActivityDetector()
            detector?.start()
        } else {
            detector = nil
        }
        voiceDetector = detector
        if detector != nil {
            // The fallback route. Each branch below replaces this with one
            // that feeds its recogniser as well, and the branches that make
            // no recogniser leave it in place.
            recorder.onBuffer = { buffer in
                detector?.append(buffer)
            }
        }
        recordingConfiguration = nil
        previewSession = -1
        previewStabilizer = PreviewStabilizer()
        previewFirmWords = nil
        let session = dictationSession
        // Hiding disputed words suits engines that republish a whole pass
        // every second or so. Apple's recogniser revises several times a
        // second as a matter of course, and hiding each revision for a beat
        // made the panel pump; its partials render as they always did.
        let makePartialHandler: (Bool) -> (@Sendable (String) -> Void) = { [weak self] hideRevisions in
            { text in
                Task { @MainActor in
                    guard let self, self.dictationSession == session else { return }
                    guard self.phase.isRecording else { return }
                    // Nothing is shown until a voice has actually been heard.
                    // Words invented over silence are worse here than in the
                    // final text: they appear while the user is sitting there
                    // saying nothing, and read as the app hearing things.
                    guard self.voiceDetector?.heardVoice ?? true else { return }
                    guard hideRevisions else {
                        self.previewSession = session
                        self.previewFirmWords = max(0, text.split(whereSeparator: \.isWhitespace).count - 2)
                        self.streamingTranscript = text
                        self.refreshOverlay()
                        return
                    }
                    if self.previewSession != session {
                        self.previewSession = session
                        self.previewStabilizer = PreviewStabilizer()
                    }
                    guard let draft = self.previewStabilizer.ingest(text) else { return }
                    self.previewFirmWords = draft.firmWords
                    self.streamingTranscript = draft.text
                    self.refreshOverlay()
                }
            }
        }

        // Nemotron streams for real, in many languages, and its finish is
        // the final transcript; the recorded file only steps in when the
        // live session fails. Local by construction, so none of the consent
        // gating below applies to it. Not gated on the preview panel: the
        // stream is authoritative, not a display.
        if settings.provider.isLocalModel,
           WhisperModelCatalog.model(withID: settings.whisperModelID)?.engine == .nemotron,
           NemotronEngine.isReady(settings.whisperModelID) {
            let configuration = settings.transcriptionConfiguration()
            recordingConfiguration = (session, configuration)
            let transcriber = NemotronLiveTranscriber(
                language: configuration.language,
                modelID: configuration.model,
                onPartial: makePartialHandler(true)
            )
            liveTranscriber = transcriber
            transcriber.start()
            // The audio thread hands buffers straight over. Nothing here
            // touches the main actor, which is the rule for that callback.
            recorder.onBuffer = { [weak transcriber] buffer in
                detector?.append(buffer)
                transcriber?.append(buffer)
            }
            return
        }

        // The GGML engines cannot stream, but they can redecode the take
        // every second or so for the preview panel; the final text still
        // comes from the ordinary file pass. Only armed when the panel that
        // would show it is on: without it the redecoding is pure heat.
        if settings.provider.isLocalModel,
           settings.overlayLivePreview,
           settings.overlayEnabled,
           let model = WhisperModelCatalog.model(withID: settings.whisperModelID),
           model.engine == .whisper || model.engine == .parakeet,
           let modelURL = WhisperModelManager.localURL(forModelID: model.id),
           FileManager.default.fileExists(atPath: modelURL.path) {
            let configuration = settings.transcriptionConfiguration()
            recordingConfiguration = (session, configuration)
            let transcriber = ChunkedLocalLiveTranscriber(
                configuration: ChunkedLocalLiveTranscriber.Configuration(
                    modelPath: modelURL.path,
                    engine: model.engine,
                    language: configuration.language,
                    prompt: configuration.prompt
                ),
                onPartial: makePartialHandler(true)
            )
            liveTranscriber = transcriber
            transcriber.start()
            // The audio thread hands buffers straight over. Nothing here
            // touches the main actor, which is the rule for that callback.
            recorder.onBuffer = { [weak transcriber] buffer in
                detector?.append(buffer)
                transcriber?.append(buffer)
            }
            return
        }

        guard settings.provider == .appleSpeech, settings.streamingMode != .off else { return }
        // Only when recognition stays on the Mac. The consent gate that asks
        // before audio leaves lives in TranscriptionService, on the path that
        // transcribes the finished file; starting a live recogniser here went
        // around it, and with on-device off that would have sent audio to
        // Apple without asking. Requiring on-device keeps the promise without
        // needing a second gate that could drift from the first.
        guard settings.preferOnDevice else { return }

        let transcriber = LiveSpeechTranscriber(
            language: settings.selectedLanguage.regionalTag,
            preferOnDevice: settings.preferOnDevice,
            contextualStrings: settings.prompt
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            onPartial: makePartialHandler(false)
        )
        guard let transcriber else { return }
        liveTranscriber = transcriber
        transcriber.start()
        // The audio thread hands buffers straight over. Nothing here touches
        // the main actor, which is the rule for that callback.
        recorder.onBuffer = { [weak transcriber] buffer in
            detector?.append(buffer)
            transcriber?.append(buffer)
        }
    }

    private func stopAndTranscribe() {
        #if DEBUG
        DuckTrace.mark("stopAndTranscribe entered")
        #endif
        // The recorder is still inside `start()`, off the main actor. A
        // wireless first buffer can go live before start returns, and a
        // hold-to-record release then lands here; stopping the engine while it
        // is being opened is the same two-thread mutation the startup chain
        // exists to prevent. Deferred to the startup's completion instead.
        guard !startupActive || !recordingUsesRecorder else {
            stopWhenRecordingBegins = true
            return
        }
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        // Whatever was playing comes back as soon as the microphone is done,
        // not when the transcript is: the point was to keep music out of the
        // recording, and transcription takes no audio.
        //
        restoreOtherAudio()

        if voiceSegmentInFlight {
            // The listener is the recorder for this segment; it finalizes on
            // its audio thread and continues via the segment callback.
            voiceListener.endSpeechNow()
            return
        }

        do {
            let audioURL = try recorder.stop(holdingInputOpen: holdingWirelessInput)
            if holdingWirelessInput { scheduleWirelessHoldLimit() }
            activeInputDeviceName = nil
            inputLevel = 0
            let insertionTarget = targetPID
            targetPID = nil
            let practice = isPracticeRun
            isPracticeRun = false

            // Was anything said at all? Asked before the transcript is asked
            // for, because a model handed silence does not answer "nothing":
            // it guesses, and the guess is what used to be pasted.
            if let detector = voiceDetector {
                voiceDetector = nil
                let session = dictationSession
                phase = .transcribing
                workTask = Task { @MainActor in
                    let heard = await detector.finish()
                    guard !Task.isCancelled, self.dictationSession == session else { return }
                    guard heard else {
                        self.discardUnspokenTake(audioURL: audioURL)
                        return
                    }
                    self.deliverRecording(
                        audioURL: audioURL,
                        insertionTarget: insertionTarget,
                        practice: practice
                    )
                }
                return
            }

            deliverRecording(
                audioURL: audioURL,
                insertionTarget: insertionTarget,
                practice: practice
            )
        } catch {
            // The failure cue is this dictation's closing cue, so a wireless
            // headset stays open until it has played.
            recorder.cancel(holdingInputOpen: holdingWirelessInput)
            if holdingWirelessInput { scheduleWirelessHoldLimit() }
            targetPID = nil
            activeInputDeviceName = nil
            inputLevel = 0
            enterFailedState(RecoveryAdvice.advice(for: error))
        }
    }

    /// A take the detector heard no voice in.
    ///
    /// Treated exactly as a take the engine found nothing in, which is what
    /// it is: the recording is deleted, nothing is pasted, nothing is kept,
    /// and the same cue plays. The only difference is that no engine was
    /// troubled with it and no invented word was ever produced.
    private func discardUnspokenTake(audioURL: URL) {
        Self.workLogger.notice("take discarded: no voice was detected in it")
        liveTranscriber?.cancel()
        liveTranscriber = nil
        recorder.onBuffer = nil
        recordingConfiguration = nil
        streamingTranscript = ""
        try? FileManager.default.removeItem(at: audioURL)
        enterFailedState(RecoveryAdvice.advice(for: TranscriptionError.emptyResponse))
    }

    /// Turns a finished recording into a transcript, waiting first for the
    /// last revision of any live recogniser.
    private func deliverRecording(
        audioURL: URL,
        insertionTarget: pid_t?,
        practice: Bool
    ) {
        // The microphone is closed, so no more audio is coming. Waiting for
        // the recogniser's last revision is the one thing still outstanding,
        // and it is the difference between the finished text and the text
        // as it stood a moment before the user stopped.
        guard let live = liveTranscriber else {
            transcribe(audioURL: audioURL, insertionTarget: insertionTarget, practice: practice)
            return
        }
        liveTranscriber = nil
        recorder.onBuffer = nil
        let session = dictationSession
        // Tracked as the work task, so Escape reaches it: while this was
        // untracked, cancelling after Stop neither stopped it nor moved the
        // session on, and its result was inserted anyway.
        phase = .transcribing
        beginStep("The transcript")
        workTask = Task { @MainActor in
            // Bounded. A recogniser that never reports a final result must
            // not hold a dictation open; what it has already said is the
            // same words without the last revision.
            let text = await live.finishOrGiveUp(after: live.finishBudget)
            guard !Task.isCancelled, self.dictationSession == session else {
                live.cancel()
                // The recogniser already produced these words; Escape means
                // insert nothing, not forget them. Passed through the same
                // cleanup a delivered transcript gets, so insert-again
                // reproduces what WOULD have been typed, not the raw
                // recogniser text with the user's replacements ignored.
                if !text.isEmpty {
                    var kept = text
                    let fillers = self.settings.removeFillerWords ? self.settings.fillerWords : []
                    if !fillers.isEmpty { kept = FillerWords.strip(fillers, from: kept) }
                    kept = TextReplacementEngine.apply(self.settings.textReplacements, to: kept)
                    self.keepTranscript(kept, from: session)
                }
                // Nothing downstream will reach the deletion that
                // `transcribe` does, and the recorder has already given up
                // its URL, so this is the last place that knows about it.
                try? FileManager.default.removeItem(at: audioURL)
                return
            }
            self.transcribe(
                audioURL: audioURL,
                insertionTarget: insertionTarget,
                practice: practice,
                liveResult: text
            )
        }
    }

    /// Clears the streaming overlay text, but only if it still belongs to this
    /// dictation. A run that ends after the user has started another one must
    /// not wipe the newer one's words.
    /// The words the indicator should be showing, which is not always the
    /// words that exist right now.
    ///
    /// Between the microphone closing and the rewrite returning there is a gap
    /// where the live transcript has been cleared and the rewritten text does
    /// not exist yet. Showing nothing through it emptied the panel and filled
    /// it again a second later, which reads as the app having lost what was
    /// said. So the last words of this take are held until something better
    /// arrives and then replaced by it.
    private func overlayWords(final: String) -> String {
        if !final.isEmpty {
            heldOverlayWords = (dictationSession, final)
            return final
        }
        if !streamingTranscript.isEmpty {
            heldOverlayWords = (dictationSession, streamingTranscript)
            return streamingTranscript
        }
        // Only this take's words. A held phrase must never appear over the
        // beginning of the next dictation.
        guard let held = heldOverlayWords, held.session == dictationSession else { return "" }
        return held.words
    }

    /// The last words shown for a dictation, and which dictation they belong
    /// to. Cleared by the session check above rather than by a reset.
    private var heldOverlayWords: (session: Int, words: String)?

    private func clearStreamingTranscript(for stream: StreamingSession, session: Int) {
        // Owning the stream, or owning the session: a stale task with a nil
        // activeStream used to pass the old check and wipe the preview of the
        // live recording that came after it.
        guard activeStream === stream || dictationSession == session else { return }
        streamingTranscript = ""
    }

    /// Closes out a dictation that was pasted in pieces as it arrived.
    ///
    /// Part of the text is already in the user's document, so this appends only
    /// what has not been delivered yet. If a chunk failed earlier, or the
    /// finished transcript no longer starts with what was pasted, the rest goes
    /// to the clipboard instead: pasting the whole transcript on top of a
    /// partial one would duplicate it, which is worse than asking for a manual
    /// paste.
    /// Closes out a dictation that was typed in pieces as it arrived.
    ///
    /// Returns nil when the user cancelled, meaning nothing should be reported
    /// and nothing further written: the clipboard in particular is left alone,
    /// because they may have copied something else since pressing Escape.
    private func finishDirectPaste(
        transcript: String,
        finalText: String,
        stream: StreamingSession,
        targetPID: pid_t?,
        appendTrailingSpace: Bool,
        autoSend: AutoSendKey,
        keepsClipboard: Bool
    ) async throws -> TextDeliveryResult? {
        if stream.cancelled { return nil }

        // A clean stop leaves everything typed so far intact, so the rest can
        // still be handed over accurately. Checked before the failure branch,
        // which cannot make that assumption.
        if stream.stopped, !stream.failed, let rest = stream.undelivered(of: transcript) {
            var remainder = rest
            if appendTrailingSpace, (remainder.last ?? stream.pasted.last)?.isWhitespace != true {
                remainder.append(" ")
            }
            guard !remainder.isEmpty else {
                // A successful stop. The copy here is a convenience for pasting
                // a second time, and someone who asked for their clipboard back
                // has said they do not want it.
                guard keepsClipboard else { return .pasted }
                let copied = textInjector.copyToClipboard(finalText)
                guard copied else { throw TextInjectionError.clipboardWriteFailed }
                return .pastedAndCopied
            }
            guard textInjector.copyToClipboard(remainder) else {
                throw TextInjectionError.clipboardWriteFailed
            }
            return .remainderCopied
        }

        guard stream.shouldContinue, var remainder = stream.undelivered(of: transcript) else {
            // Delivery broke, or the finished text no longer starts with what
            // was typed. The clipboard is the recovery path either way, but the
            // instruction differs: with words already in the document, pasting
            // the whole transcript appends to them unless the user removes them
            // first, so the two cases must not share a message.
            guard textInjector.copyToClipboard(finalText) else {
                throw TextInjectionError.clipboardWriteFailed
            }
            return stream.pasted.isEmpty ? .copiedOnly : .replacementCopied
        }

        if appendTrailingSpace {
            // The last character of the whole dictation, which is in the
            // remainder only if there is one. Looking at an empty remainder's
            // last character finds nothing and appends a second space to a
            // transcript that already ended with one.
            let lastDelivered = remainder.last ?? stream.pasted.last
            if lastDelivered?.isWhitespace != true { remainder.append(" ") }
        }

        if !remainder.isEmpty {
            // A tab or newline cannot be typed: it would move focus or submit
            // the field. It cannot be pasted either, because pasting returns
            // before the app has read the clipboard, so the transcript written
            // there afterwards would be pasted instead and duplicate the words
            // already typed. So it goes to the user, who pastes it themselves.
            if StreamingSession.mustNotBeTyped(remainder) {
                guard textInjector.copyToClipboard(remainder) else {
                    throw TextInjectionError.clipboardWriteFailed
                }
                // Distinct from .copiedOnly on purpose: there the clipboard
                // holds the whole transcript and pasting replaces nothing,
                // whereas here part of it is already typed and the clipboard
                // holds only the rest. Telling the two apart is what stops the
                // user from duplicating or losing the opening words.
                return .remainderCopied
            }
            let landed = await textInjector.insertChunk(
                remainder,
                targetPID: targetPID,
                shouldProceed: { stream.shouldContinue }
            )
            if stream.cancelled { return nil }
            if landed != remainder {
                // Some of the closing piece did not arrive. What is left is
                // known exactly, so hand over only that: copying the whole
                // transcript here would duplicate everything already typed.
                let missing = String(remainder.dropFirst(landed.count))
                guard !missing.isEmpty else { return .pastedAndCopied }
                guard textInjector.copyToClipboard(missing) else {
                    throw TextInjectionError.clipboardWriteFailed
                }
                return .remainderCopied
            }

        }

        // Typing never touched the clipboard, so the transcript goes there now
        // for people who paste it a second time. Unless the user asked for the
        // clipboard back, in which case typing never taking it is exactly what
        // they wanted; the recovery copies above are different, because there
        // the clipboard is the only way not to lose text.
        let copied = keepsClipboard ? textInjector.copyToClipboard(finalText) : false

        if let stroke = autoSend.keyStroke, stream.shouldContinue {
            // Same reason as the normal path: the text has to land before
            // Return, or the app sends a half-written line.
            try? await Task.sleep(nanoseconds: 120_000_000)
            // Re-checked after the wait: Escape during these 120 ms must not
            // still submit the message.
            if stream.shouldContinue {
                textInjector.postAutoSend(
                    keyCode: stroke.keyCode,
                    flags: stroke.flags,
                    targetPID: targetPID
                )
            }
        }
        // Deliberately kept: the clipboard was never taken, which is not the
        // same outcome as a copy that failed. Reporting the failure case here
        // would send the user hunting for a problem that is actually their own
        // setting doing its job.
        if !keepsClipboard { return .pasted }
        // The text is in the document either way, but saying it was copied
        // when the clipboard write failed sends the user to an empty clipboard.
        return copied ? .pastedAndCopied : .insertedNotCopied
    }

    // MARK: - Transcribing a file

    /// Whether a one-off tool, a file import or a clipboard rewrite, would be
    /// accepted right now. The clipboard flags matter as much as the phase:
    /// selection capture and insert-again run through the idle phase on
    /// purpose, and a tool accepted mid-flight would invalidate their session.
    var canRunTool: Bool {
        guard !capturingSelection, !insertingAgain else { return false }
        switch phase {
        case .idle, .failed: return true
        default: return false
        }
    }

    /// The longest file the hosted providers are asked to swallow whole.
    /// Their upload limits sit in the tens of megabytes, which this length
    /// of 16 kHz mono audio stays safely under; the local engines read from
    /// disk and get no ceiling.
    private static let hostedImportLimit: TimeInterval = 10 * 60

    /// Transcribes an audio file the user dropped on the panel or picked in
    /// the open dialog. The same pipeline as a dictation, but with no
    /// insertion target: pasting is about where the cursor is, and a dropped
    /// file says nothing about that, so the result goes to the clipboard,
    /// the panel and history instead.
    ///
    /// The file is decoded to the app's own audio format before anything
    /// else sees it. That is what proves it is audio at all (a dropped
    /// document fails here, on this Mac, instead of being uploaded to a
    /// provider), and what keeps the upload honest for providers that trust
    /// the file's name to describe its bytes.
    func transcribeAudioFile(at url: URL, rewrite: ToolRewrite = .asSpoken) {
        guard canRunTool else { return }
        // The same gate every dictation passes; skipping it here would make
        // file imports the one unlicensed way in.
        licence.refreshState()
        guard licence.state.allowsDictation else {
            enterFailedState(RecoveryAdvice.licenceRequired(licence.state))
            showSettings(selecting: .licence)
            return
        }
        // The previous dictation may still be holding a wireless headset
        // open for its closing cue; the session bump below would silence
        // that cue's session-guarded release, so the hold is retired first,
        // exactly as every other dictation start does.
        finishWirelessDictation()
        // Claimed before the decode, not after it, so a dictation started
        // while a big file is still being read cannot interleave with it.
        dictationSession += 1
        let session = dictationSession
        phase = .transcribing
        beginStep("Reading the file", allowing: 120)
        updateCancelHotKey()
        // The configuration is decided now, before the decode, and handed
        // to transcribe directly rather than through shared state: a
        // provider switched mid-decode must not turn a length that was
        // checked against one provider into an upload to another, and a
        // stale dictation's cleanup must not be able to erase the pin.
        let configuration = settings.transcriptionConfiguration()
        let hostedLimit: TimeInterval? = settings.provider.isLocalModel ? nil : Self.hostedImportLimit
        // Kept as the dictation's work so Escape and the watchdog cancel the
        // decode itself, not just the phase that was watching it.
        workTask = Task { [weak self] in
            let prepared: (url: URL, seconds: TimeInterval)
            do {
                // Detached so the decode never runs on the main actor, and
                // cancel-linked by hand because a detached task inherits
                // nothing, including cancellation.
                let decode = Task.detached(priority: .userInitiated) {
                    try Self.prepareImportedAudio(url)
                }
                prepared = try await withTaskCancellationHandler {
                    try await decode.value
                } onCancel: {
                    decode.cancel()
                }
            } catch {
                guard let self, self.dictationSession == session, !(error is CancellationError) else { return }
                self.enterFailedState(RecoveryAdvice(
                    message: "That file could not be read as audio. MicMyDay can transcribe the audio formats macOS itself can play."
                ))
                return
            }
            guard let self else {
                try? FileManager.default.removeItem(at: prepared.url)
                return
            }
            // Escape, or a new dictation, may have claimed the app while
            // the file was being decoded; this import then owns nothing.
            guard !Task.isCancelled, self.dictationSession == session, case .transcribing = self.phase else {
                try? FileManager.default.removeItem(at: prepared.url)
                return
            }
            if let hostedLimit, prepared.seconds > hostedLimit {
                try? FileManager.default.removeItem(at: prepared.url)
                self.enterFailedState(RecoveryAdvice(
                    message: "This recording is longer than the hosted provider accepts in one piece. Choose a local engine in Settings \u{2192} Engine to transcribe long files."
                ))
                return
            }
            self.transcribe(
                audioURL: prepared.url,
                insertionTarget: nil,
                fileImport: true,
                configurationOverride: configuration,
                rewriteOverride: rewrite
            )
        }
    }

    /// Decodes any audio macOS can read into a 16 kHz mono WAV in the
    /// temporary directory, and reports its length. Throws for anything
    /// that is not decodable audio.
    nonisolated static func prepareImportedAudio(_ url: URL) throws -> (url: URL, seconds: TimeInterval) {
        try Task.checkCancellation()
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let samples = try WhisperCppTranscriber.monoSamples16kHz(from: url)
        // The decode above has no cancellation points of its own; checking
        // here and between write chunks keeps an abandoned import from
        // writing a file nobody is waiting for.
        try Task.checkCancellation()
        guard !samples.isEmpty else { throw TranscriptionError.emptyResponse }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("imported-" + UUID().uuidString)
            .appendingPathExtension("wav")
        // Scoped so the writer is gone, and its buffers flushed, before the
        // URL is handed to anything that will read it. AVAudioFile flushes
        // on deallocation and offers no explicit close on this OS floor.
        // A failed or cancelled write cleans up its own partial file; the
        // caller never learns this URL, so nobody else can.
        do {
            let file = try AVAudioFile(forWriting: destination, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ])
            let format = file.processingFormat
            let chunk = AVAudioFrameCount(16_000)
            var written = 0
            while written < samples.count {
                try Task.checkCancellation()
                let count = min(samples.count - written, Int(chunk))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let channel = buffer.floatChannelData?[0]
                else { throw TranscriptionError.emptyResponse }
                samples.withUnsafeBufferPointer { source in
                    channel.update(from: source.baseAddress! + written, count: count)
                }
                buffer.frameLength = AVAudioFrameCount(count)
                try file.write(from: buffer)
                written += count
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return (destination, Double(samples.count) / 16_000)
    }

    /// The longest clipboard a rewrite is offered for. Past this the request
    /// is large enough to be slow and expensive without the user having any
    /// idea they asked for it, and a clipboard that big is usually a whole
    /// document copied by accident.
    private static let clipboardRewriteLimit = 20_000

    /// Rewrites whatever text is on the clipboard with the named profile and
    /// puts the result back, so any selection in any app can be rewritten by
    /// copying it, picking a profile, and pasting.
    ///
    /// The result goes to the clipboard and nowhere else. A paste would have
    /// to guess which app and which selection it was meant for, and guessing
    /// wrong overwrites something the user did not offer.
    func rewriteClipboardText(profileID: String) {
        guard canRunTool else { return }
        // The same gate every dictation passes.
        licence.refreshState()
        guard licence.state.allowsDictation else {
            enterFailedState(RecoveryAdvice.licenceRequired(licence.state))
            showSettings(selecting: .licence)
            return
        }
        // The count is taken around the read itself, not later: everything
        // below here (validating, closing the panel, claiming the phase) is a
        // window in which the user can copy something else, and a count taken
        // after that window would accept their new clipboard as the thing
        // this rewrite was started for.
        let readChangeCount = textInjector.currentChangeCount
        let clipboard = (textInjector.clipboardText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard textInjector.currentChangeCount == readChangeCount else {
            enterFailedState(RecoveryAdvice(
                message: "The clipboard changed just as it was read, so nothing was rewritten. Try again."
            ))
            return
        }
        guard !clipboard.isEmpty else {
            enterFailedState(RecoveryAdvice(
                message: "There is no text on the clipboard to rewrite. Copy some text first, then choose a profile here."
            ))
            return
        }
        guard clipboard.count <= Self.clipboardRewriteLimit else {
            enterFailedState(RecoveryAdvice(
                message: "That is more text than MicMyDay will rewrite in one go. Copy a smaller passage and try again."
            ))
            return
        }
        guard let configuration = settings.enhancementConfiguration(forProfileID: profileID) else {
            enterFailedState(RecoveryAdvice(
                message: settings.rewriteUnavailableReason
                    ?? "Rewriting needs a provider. Choose one in Settings \u{2192} Rewrite, then try again."
            ))
            showSettings(selecting: .rewrite)
            return
        }

        dismissMenuBarPanel()
        // The previous dictation may still be holding a wireless headset open
        // for its closing cue; the session bump below would silence that cue's
        // session-guarded release.
        finishWirelessDictation()
        dictationSession += 1
        let session = dictationSession
        phase = .enhancing
        beginStep("Rewriting", allowing: 60)
        updateCancelHotKey()
        let probe = UsageProbe()

        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                let rewritten = try await self.work.enhance(clipboard, configuration, probe)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !Task.isCancelled, self.dictationSession == session else { return }
                guard !rewritten.isEmpty else { throw TranscriptionError.emptyResponse }
                // The request happened and was paid for whatever becomes of
                // the text, so it counts here rather than on the way out.
                self.usage.record(probe.drain(), wordsTyped: 0)
                // Kept before delivery is attempted, so a rewrite that cannot
                // reach the clipboard still lands somewhere the user can get
                // at it: the panel shows it with its own copy button. The
                // delivery line is cleared in that case rather than left
                // describing whatever was delivered last, which would caption
                // this text with another dictation's destination.
                self.keepTranscript(rewritten, from: session)
                guard self.textInjector.currentChangeCount == readChangeCount else {
                    self.enterFailedState(RecoveryAdvice(
                        message: "You copied something else while the rewrite was running, so the clipboard was left as you left it. The rewritten text is here in the panel."
                    ))
                    return
                }
                guard self.textInjector.copyToClipboard(rewritten) else {
                    self.enterFailedState(RecoveryAdvice(
                        message: "The rewrite finished but the clipboard would not accept it. The text is here in the panel, where it can be copied by hand."
                    ))
                    return
                }
                self.lastDelivery = .clipboardOnly
                if self.settings.keepRecentTranscripts {
                    self.history.record(
                        TranscriptEntry(
                            date: Date(),
                            spoken: clipboard,
                            pasted: rewritten,
                            profileName: configuration.profileName,
                            engineName: self.settings.rewriteProvider.title,
                            destinationApp: nil,
                            clipboardOnly: true
                        )
                    )
                }
                self.endStep()
                self.phase = .idle
            } catch {
                // Our own cancellation is handled by the cancel path, which
                // has already reset the phase; this task only has to stay
                // quiet. Anything else, a cancellation raised by the provider
                // included, has to end the step, or the app sits in
                // .enhancing until a watchdog notices.
                guard !Task.isCancelled, self.dictationSession == session else { return }
                self.enterFailedState(Self.rewriteAdvice(for: error))
            }
        }
    }

    /// Recovery wording for a clipboard rewrite. The dictation advice cannot
    /// be reused here: it talks about microphones and deleted recordings,
    /// neither of which this path has.
    private static func rewriteAdvice(for error: Error) -> RecoveryAdvice {
        if error is CancellationError {
            return RecoveryAdvice(message: "The rewrite stopped before it finished. The clipboard was left as it was.")
        }
        if let transcription = error as? TranscriptionError, case .emptyResponse = transcription {
            return RecoveryAdvice(message: "The rewrite came back empty, so the clipboard was left as it was.")
        }
        if let urlError = error as? URLError {
            let host = urlError.failingURL?.host() ?? "the rewrite server"
            return RecoveryAdvice(message: "The rewrite failed: the server at \(host) could not be reached. The clipboard was left as it was.")
        }
        // The stock descriptions name the transcription provider, which would
        // send someone to the wrong half of Settings for a rewrite that a
        // quite different provider refused.
        if let transcription = error as? TranscriptionError {
            switch transcription {
            case let .server(statusCode, message):
                return RecoveryAdvice(message: "The rewrite provider returned HTTP \(statusCode): \(message) The clipboard was left as it was.")
            case .invalidResponse:
                return RecoveryAdvice(message: "The rewrite provider returned something MicMyDay could not read. The clipboard was left as it was.")
            default:
                break
            }
        }
        return RecoveryAdvice(message: error.localizedDescription)
    }

    /// The click alternative to dropping a file on the panel.
    func pickAudioFileForTranscription(rewrite: ToolRewrite = .asSpoken) {
        dismissMenuBarPanel()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transcribeAudioFile(at: url, rewrite: rewrite)
    }

    private func transcribe(
        audioURL: URL,
        insertionTarget: pid_t?,
        isVoiceTriggered: Bool = false,
        practice: Bool = false,
        fileImport: Bool = false,
        configurationOverride: TranscriptionConfiguration? = nil,
        rewriteOverride: ToolRewrite? = nil,
        liveResult: String? = nil
    ) {
        // With automatic pasting off, there is no destination: the transcript
        // goes to the clipboard and the user places it themselves.
        let insertionTarget = settings.automaticPasteEnabled ? insertionTarget : nil
        // The configuration the recording started under, when one was
        // captured for this same session: a setting changed mid-take must not
        // hand the preview and the final pass different models or languages.
        let configuration = configurationOverride
            ?? recordingConfiguration
            .flatMap { $0.session == dictationSession ? $0.configuration : nil }
            ?? settings.transcriptionConfiguration()
        recordingConfiguration = nil
        // Taken here and cleared, so the edit belongs to exactly this dictation
        // whatever happens to it afterwards.
        let edit = pendingEdit
        pendingEdit = nil
        activeEditReturn = edit.map { ($0.clipboard, $0.changeCount) }
        // The watcher that belongs to this edit, by identity. Every stop this
        // task performs goes through it, so a stale task that outlived its
        // cancellation can never switch off the protection of an edit that
        // started after it.
        let editWatcherOwned = edit != nil ? editWatcher : nil

        // A tool names the rewrite it wants, including naming none; only a
        // dictation falls back to what the settings say.
        var enhancement = rewriteOverride.map { choice -> EnhancementConfiguration? in
            switch choice {
            case .asSpoken: return nil
            case let .profile(id): return settings.enhancementConfiguration(forProfileID: id)
            }
        } ?? settings.enhancementConfiguration()
        if let edit, enhancement != nil {
            // What the user said is an instruction about the selection, not
            // text to insert, so the profile's prompt is set aside: a cleanup
            // prompt applied to an instruction would tidy the instruction.
            enhancement?.systemPrompt = VoiceEdit.instruction
            enhancement?.profileID = "edit-selection"
            enhancement?.profileName = "Edit selection"
            _ = edit
        }
        // Why no rewrite will run, when none will. A tool answers for itself:
        // "as spoken" is the user's own choice and needs no apology, and a
        // named profile is judged on whether that profile could be prepared,
        // not on what the dictation settings happen to say. Reading the
        // dictation reason here both invented warnings for tools that worked
        // and dropped the profile's name from their history entry.
        let enhancementBlocked: String?
        switch rewriteOverride {
        case .asSpoken:
            enhancementBlocked = nil
        case .profile:
            enhancementBlocked = enhancement == nil
                ? "the chosen rewrite profile could not be prepared. Check the rewrite provider in Settings."
                : nil
        case nil:
            enhancementBlocked = settings.rewriteUnavailableReason
        }
        if let enhancementBlocked {
            // Indistinguishable from a rewrite that ran and changed nothing,
            // which is why it is worth a line of its own.
            Self.workLogger.notice("rewrite skipped: \(enhancementBlocked, privacy: .public)")
        } else if enhancement == nil, settings.enhancementEnabled {
            Self.workLogger.notice("rewrite skipped: no configuration could be built")
        }
        let shouldAppendSpace = settings.appendTrailingSpace
        let restoresClipboard = settings.restoreClipboardAfterPaste
        let autoSendKey = settings.autoSendKey
        let replacements = settings.textReplacements
        let fillers = settings.removeFillerWords ? settings.fillerWords : []

        // Direct paste writes words into the app as they arrive, so anything
        // that rewrites the transcript afterwards would contradict text the
        // user can already see. When either is active this dictation streams
        // into the overlay instead; the setting explains the trade.
        var streaming = settings.effectiveStreamingMode
        let willPostProcess = enhancement != nil
            || !fillers.isEmpty
            || replacements.contains { $0.isEnabled && !$0.spoken.trimmingCharacters(in: .whitespaces).isEmpty }
        if streaming == .directPaste, willPostProcess || insertionTarget == nil {
            streaming = .overlay
        }
        if edit != nil {
            // What is being spoken is an instruction, and the only thing that
            // may reach the document is the edited passage. Typing the
            // instruction as it arrives would put it there before anything had
            // decided whether the edit could happen at all.
            streaming = .overlay
        }
        if practice, streaming == .directPaste {
            // A try-out must not touch anybody's document. The final delivery
            // already respects this; the partial chunks that direct paste types
            // as they arrive did not, and onboarding's "Speak" could write into
            // whatever the user had focused before opening it.
            streaming = .overlay
        }
        streamingTranscript = ""
        phase = .transcribing
        beginStep("Transcription", allowing: audioDuration(of: audioURL))
        updateCancelHotKey()
        // The dictation this work belongs to. Anything with a side effect,
        // pasting, the clipboard, history, checks it before acting, because a
        // cancelled dictation that still types its result into the user's
        // terminal a few seconds later has not been cancelled at all.
        let session = dictationSession
        if settings.playFeedbackSounds {
            feedbackSoundPlayer.startProcessing()
        }

        workTask = Task {
                defer { try? FileManager.default.removeItem(at: audioURL) }
                // Outside the do block: if transcription fails partway, the
                // chunks already queued have to be stopped, and the catch needs
                // to reach them to do that.
                let stream = StreamingSession()
                // Collects what each engine consumed. Engines append to it once
                // their own work is finished, and it is folded into the totals
                // only after the transcript has been delivered.
                let probe = UsageProbe()
                // Any streamed dictation is interruptible once recording has
                // stopped: direct paste because it is writing into another app,
                // overlay because the user can see it running and expects
                // Escape to mean stop.
                if streaming != .off { activeStream = stream }
                streamInFlight = stream
                // Focus inside a window can only move by a click or a Tab, and
                // the sandbox rules out watching focus itself, so the input is
                // what gets watched. Anything the user does stops the typing
                // and leaves the rest to the clipboard.
                // One watcher per dictation. A shared instance let a late
                // finishing run tear down the monitor belonging to the run the
                // user had already started after it.
                let watcher = UserInteractionWatcher()
                watcher.exemptWindow = { [weak self] in self?.overlayController.window }
                if streaming == .directPaste {
                    watcher.start { stream.stopStreaming() }
                }
                defer {
                    watcher.stop()
                    if activeStream === stream { activeStream = nil }
                    if streamInFlight === stream { streamInFlight = nil }
                }
                do {
                    let generation = voiceSegmentGeneration

                    var onPartial: (@MainActor (String) -> Void)?
                    if streaming != .off {
                        onPartial = { [weak self] delta in
                            guard let self, self.voiceSegmentGeneration == generation else { return }
                            // A cancelled run can still receive in-flight
                            // deltas; they belong to nothing the user can see.
                            guard !stream.cancelled, self.activeStream === stream else { return }
                            self.streamingTranscript += delta
                            // The overlay ticker only runs while recording, so
                            // without this the pill would sit on "Transcribing…"
                            // while the words piled up unseen.
                            self.refreshOverlay()
                            guard streaming == .directPaste, stream.acceptsMoreChunks else { return }
                            guard let chunk = stream.buffer.append(delta) else { return }
                            // A tab would move focus and a newline would submit
                            // the field, so streaming stops here and the rest
                            // is left to the closing paste, which handles them.
                            guard !StreamingSession.mustNotBeTyped(chunk) else {
                                stream.stopStreaming()
                                return
                            }
                            stream.enqueue(chunk) { piece in
                                await self.textInjector.insertChunk(
                                    piece,
                                    targetPID: insertionTarget,
                                    shouldProceed: { stream.shouldContinue }
                                )
                            }
                        }
                    }

                    // Already transcribed, if the engine was recognising while
                    // the user spoke. Transcribing the file again would spend
                    // seconds arriving at text that is already on screen.
                    let transcript: String
                    if let live = liveResult, !live.isEmpty {
                        transcript = live
                        Self.workLogger.notice("used the live transcript; the recording was not re-transcribed")
                    } else {
                        transcript = try await work.transcribe(audioURL, configuration, probe, onPartial)
                    }
                    clearStreamingTranscript(for: stream, session: session)

                    var cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else { throw TranscriptionError.emptyResponse }
                    // Hesitation noises go first, so a correction matching a
                    // phrase is not defeated by an "um" sitting in the middle
                    // of it, and so a rewrite is not asked to tidy something
                    // that can simply be deleted.
                    cleaned = FillerWords.strip(fillers, from: cleaned)
                    // Before any rewrite, so the model reads corrected names.
                    cleaned = TextReplacementEngine.apply(replacements, to: cleaned)

                    // Enhancement failures fall back to the raw transcript: a
                    // degraded dictation beats losing the spoken words entirely.
                    var finalText = cleaned
                    // Set before the rewrite so a dictation that never had a
                    // rewrite to run still says why, rather than looking like
                    // one that ran and changed nothing.
                    var enhancementNote: String? = enhancementBlocked.map {
                        "Rewriting was skipped: \($0) Inserted the raw transcript."
                    }
                    // Checked before the rewrite: starting one for a cancelled
                    // dictation strands the app in .enhancing and spends a
                    // request on text nobody will see.
                    guard !stream.cancelled, dictationSession == session else {
                        // The words exist and the audio is about to be deleted;
                        // cancellation means "insert nothing", not "forget it".
                        // `cleaned` is still the spoken text here — the edit
                        // wrapping happens just below.
                        keepTranscript(cleaned, from: session)
                        clearStreamingTranscript(for: stream, session: session)
                        returnEditClipboard(edit, watcher: editWatcherOwned)
                        return
                    }
                    // What the user said, before it is wrapped up for the
                    // model. History and the overlay should show the
                    // instruction, not the passage and the labels around it.
                    let spoken = cleaned
                    if let edit {
                        // The model is given the passage and the instruction as
                        // one message, clearly separated, rather than the
                        // transcript alone.
                        cleaned = VoiceEdit.message(selection: edit.selection, instruction: cleaned)
                    }
                    if let enhancement {
                        phase = .enhancing
                        beginStep("The rewrite")
                        do {
                            finalText = try await work.enhance(cleaned, enhancement, probe)
                        } catch let cancellation where cancellation is CancellationError
                            || (cancellation as? URLError)?.code == .cancelled {
                            // Escape during the rewrite ends the dictation. It
                            // is not a failed rewrite to report and fall back
                            // from: nothing should be inserted at all.
                            //
                            // The words, though, already exist: transcription
                            // succeeded before the rewrite began, and the
                            // audio is deleted when this task ends. Kept where
                            // insert-again can reach them, inserted nowhere.
                            // This is also the path the rewrite watchdog takes,
                            // where losing the transcript over a slow provider
                            // would be plainly wrong.
                            keepTranscript(edit != nil ? spoken : cleaned, from: session)
                            clearStreamingTranscript(for: stream, session: session)
                            returnEditClipboard(edit, watcher: editWatcherOwned)
                            // Escape and the watchdog both reset the phase on
                            // their way through here, so this path had nothing
                            // to do. A cancellation raised by the provider
                            // itself arrives with neither, and without this the
                            // app sat in .enhancing, blocking every tool and
                            // dictation, until a watchdog eventually noticed.
                            if !Task.isCancelled, !stream.cancelled,
                               dictationSession == session, phase.isBusy {
                                endStep()
                                finishWirelessDictation()
                                restoreOtherAudio()
                                phase = .idle
                                updateCancelHotKey()
                            }
                            return
                        } catch {
                            // A late error from a dictation the user has moved
                            // on from must not disturb the one running now —
                            // but the transcription it carries still succeeded
                            // and is preserved like every other late exit.
                            guard !stream.cancelled, dictationSession == session else {
                                keepTranscript(edit != nil ? spoken : cleaned, from: session)
                                clearStreamingTranscript(for: stream, session: session)
                                returnEditClipboard(edit, watcher: editWatcherOwned)
                                return
                            }
                            if edit != nil {
                                // An edit has no safe fallback. The words are
                                // an instruction, not text, and the passage
                                // they describe is still selected: inserting
                                // anything here replaces it. Leave it alone.
                                clearStreamingTranscript(for: stream, session: session)
                                returnEditClipboard(edit, watcher: editWatcherOwned)
                                // The instruction was heard correctly; only
                                // carrying it out failed. Keeping it means the
                                // user can try again without saying it twice.
                                keepTranscript(spoken, from: session)
                                enterFailedState(RecoveryAdvice(
                                    message: "The edit could not be carried out (\(error.localizedDescription)). Your text was left as it was, and what you said is kept; the insert-again shortcut types it wherever your cursor is."
                                ))
                                return
                            }
                            enhancementNote = "Rewriting failed (\(error.localizedDescription)); inserted the raw transcript."
                        }
                    } else if edit != nil {
                        // Rewriting was switched off, or its setup was undone,
                        // between starting the edit and finishing it. Same
                        // reasoning: there is nothing safe to insert.
                        clearStreamingTranscript(for: stream, session: session)
                        returnEditClipboard(edit, watcher: editWatcherOwned)
                        keepTranscript(spoken, from: session)
                        enterFailedState(RecoveryAdvice(
                            message: "The edit needs rewriting switched on. Your text was left as it was, and what you said is kept; the insert-again shortcut types it wherever your cursor is."
                        ))
                        return
                    }

                    // Escape ends the dictation outright. Checked before any
                    // state is written: setting .inserting first and returning
                    // after would strand the app in a phase it never leaves, or
                    // overwrite the phase of a recording already under way.
                    guard !stream.cancelled else {
                        // finalText exists here: the rewrite finished before the
                        // cancellation was noticed, and the finished text is
                        // what insert-again should reproduce.
                        keepTranscript(
                            edit.map { VoiceEdit.rewrapped(finalText, like: $0.selection) } ?? finalText,
                            from: session,
                            exact: edit != nil
                        )
                        clearStreamingTranscript(for: stream, session: session)
                        returnEditClipboard(edit, watcher: editWatcherOwned)
                        return
                    }

                    guard dictationSession == session else {
                        // finalText exists here: the rewrite finished before the
                        // cancellation was noticed, and the finished text is
                        // what insert-again should reproduce.
                        keepTranscript(
                            edit.map { VoiceEdit.rewrapped(finalText, like: $0.selection) } ?? finalText,
                            from: session,
                            exact: edit != nil
                        )
                        clearStreamingTranscript(for: stream, session: session)
                        returnEditClipboard(edit, watcher: editWatcherOwned)
                        return
                    }
                    if let edit {
                        // Every rewrite path trims what it returns, rightly for
                        // a dictation and wrongly here: the result replaces the
                        // selection exactly, and the selection carried its own
                        // indentation and the newline that ended its paragraph.
                        // Put those back around the model's answer.
                        finalText = VoiceEdit.rewrapped(finalText, like: edit.selection)
                    }
                    keepTranscript(finalText, from: session, exact: edit != nil)
                    // A fresh step for delivery. The rewrite's deadline was
                    // still armed here, and typing a long edited passage
                    // crossed it mid-delivery: the watchdog cancelled a
                    // delivery that was working and left the selection half
                    // replaced.
                    endStep()
                    // Scaled to the text: typing paces itself in small batches,
                    // and a very long edited passage legitimately takes longer
                    // than the flat window — the watchdog then cancelled a
                    // delivery that was working, mid-selection.
                    // UTF-16 units, because that is what typing batches pace
                    // on: emoji-heavy text has several units per character,
                    // and a grapheme count under-budgeted it.
                    beginStep("The delivery", allowing: Double(finalText.utf16.count) / 1_000)
                    lastEnhancementNote = enhancementNote
                    let targetName = insertionTarget.flatMap {
                        NSRunningApplication(processIdentifier: $0)?.localizedName
                    }
                    // Everything queued has to land before the closing paste,
                    // or the last words arrive ahead of earlier ones.
                    await stream.drainQueue()
                    guard !stream.cancelled else {
                        keepTranscript(finalText, from: session, exact: edit != nil)
                        clearStreamingTranscript(for: stream, session: session)
                        returnEditClipboard(edit, watcher: editWatcherOwned)
                        return
                    }
                    // Cancelled while this was running, so it must deliver
                    // nothing. Checked here rather than only at the start,
                    // because the whole point is that the user pressed Escape
                    // partway through.
                    guard dictationSession == session else {
                        // Unreachable today (every session bump also cancels
                        // the stream, caught above), but a bare return here
                        // would strand the edit's clipboard if that ever
                        // changed, and its siblings all clean up.
                        keepTranscript(finalText, from: session, exact: edit != nil)
                        clearStreamingTranscript(for: stream, session: session)
                        returnEditClipboard(edit, watcher: editWatcherOwned)
                        return
                    }

                    // The try-out shows its result in the onboarding window and
                    // stops there: nothing is pasted, the clipboard is left
                    // alone, and no Return is sent.
                    if practice {
                        lastDelivery = nil
                        finishWirelessDictation()
                        endStep()
                        phase = .idle
                        return
                    }

                    let delivery: TextDeliveryResult
                    if streaming == .directPaste, !stream.pasted.isEmpty {
                        // Words are already in the document and cannot be taken
                        // back, so the only safe move is to add what is missing.
                        // Re-pasting finalText here would duplicate the lot.
                        guard let streamed = try await finishDirectPaste(
                            transcript: transcript,
                            finalText: finalText,
                            stream: stream,
                            targetPID: insertionTarget,
                            appendTrailingSpace: shouldAppendSpace,
                            autoSend: autoSendKey,
                            keepsClipboard: !restoresClipboard
                        ) else {
                            clearStreamingTranscript(for: stream, session: session)
                            return
                        }
                        delivery = streamed
                    } else {
                        delivery = try await textInjector.insert(
                            finalText,
                            targetPID: insertionTarget,
                            appendTrailingSpace: shouldAppendSpace,
                            // No Return after an edit: replacing a selection
                            // in a chat box must not also send the message.
                            autoSend: edit != nil ? .off : autoSendKey,
                            restoreClipboard: restoresClipboard,
                            restoring: edit?.clipboard,
                            restoringIfUnchangedFrom: edit?.changeCount,
                            // Typing is the raceless path, but a typed newline
                            // acts as Return and a typed tab moves focus, so a
                            // multi-line passage — any triple-clicked paragraph
                            // — cannot be typed at all. Those go through the
                            // paste path, where a newline is just a character;
                            // the clipboard race it reopens is the same bounded
                            // one every ordinary dictation accepts.
                            typeInsteadOfPasting: edit != nil
                                && !StreamingSession.mustNotBeTyped(finalText),
                            shouldProceed: { stream.shouldContinue }
                        )
                    }
                    guard !stream.cancelled else {
                        keepTranscript(finalText, from: session, exact: edit != nil)
                        clearStreamingTranscript(for: stream, session: session)
                        returnEditClipboard(edit, watcher: editWatcherOwned)
                        return
                    }
                    if settings.keepRecentTranscripts {
                    history.record(
                        TranscriptEntry(
                            date: Date(),
                            spoken: spoken,
                            pasted: finalText,
                            // The profile captured when the rewrite started,
                            // not the current selection: the overlay's picker
                            // can switch profiles while a delivery is still in
                            // flight, and that switch belongs to the next
                            // take, not to this entry.
                            profileName: enhancementNote == nil
                                ? enhancement?.profileName
                                : nil,
                            engineName: settings.provider.title,
                            destinationApp: targetName,
                            clipboardOnly: delivery == .copiedOnly
                                || delivery == .remainderCopied
                                || delivery == .replacementCopied
                        )
                    )
                    }
                    guard !stream.cancelled else {
                        keepTranscript(finalText, from: session, exact: edit != nil)
                        clearStreamingTranscript(for: stream, session: session)
                        returnEditClipboard(edit, watcher: editWatcherOwned)
                        return
                    }
                    // The edit has been delivered; its watcher's job is done.
                    // Left running, it outlived the edit and cancelled the NEXT
                    // dictation on the first keystroke — the hotkeys that start
                    // one are Carbon events its monitors never see, so it had
                    // no way to notice a new dictation had begun.
                    stopEditWatcher(ifStill: editWatcherOwned)
                    // Delivery restored the snapshot itself; empty the stash so
                    // nothing returns already-returned bytes later.
                    if edit != nil { activeEditReturn = nil }
                    if settings.playFeedbackSounds {
                        let session = dictationSession
                        feedbackSoundPlayer.playCompletion { [weak self] in
                            self?.finishWirelessDictation(session: session)
                        }
                    } else {
                        finishWirelessDictation()
                    }
                    voiceFailureStreak = 0
                    // The dictation is over and the text has landed. Only now
                    // do the counters move, and the write they schedule is
                    // coalesced and runs at low priority.
                    // Only what was actually typed. A transcript that went to
                    // the clipboard instead, because pasting is off or the
                    // paste failed, was never typed anywhere, and counting it
                    // would make the figure mean "words produced" a second
                    // time over.
                    let typed: Int
                    switch delivery {
                    case .copiedOnly, .replacementCopied:
                        typed = 0
                    case .remainderCopied:
                        // Part of it landed and the rest went to the clipboard.
                        // What landed is what the stream managed to deliver.
                        typed = UsageMeasurement.words(in: stream.pasted)
                    default:
                        typed = UsageMeasurement.words(in: finalText)
                    }
                    usage.record(probe.drain(), wordsTyped: typed)

                    switch delivery {
                    case .pastedAndCopied, .pasted:
                        lastDelivery = .pasted(appName: targetName)
                        endStep()
                        phase = .idle
                        beginCoachingIfNeeded()
                    case .insertedNotCopied:
                        lastDelivery = .insertedNotCopied(appName: targetName)
                        endStep()
                        phase = .idle
                        beginCoachingIfNeeded()
                    case .remainderCopied:
                        lastDelivery = .remainderOnClipboard
                        endStep()
                        phase = .idle
                    case .replacementCopied:
                        lastDelivery = .replacementOnClipboard
                        endStep()
                        phase = .idle
                    case .copiedOnly:
                        lastDelivery = .clipboardOnly
                        // Only a problem when the user asked for a paste and
                        // did not get one. With automatic pasting off this is
                        // simply how MicMyDay works, so naming a permission
                        // here would be nagging about a feature they declined.
                        // A file import never asked for a paste, so its
                        // clipboard-only outcome is the intended one whatever
                        // the permissions say.
                        if fileImport || !settings.automaticPasteEnabled || TextInjector.isAccessibilityTrusted {
                            endStep()
                            phase = .idle
                            beginCoachingIfNeeded()
                        } else {
                            enterFailedState(.accessibility)
                        }
                    }
                } catch {
                    // Words still on their way into someone's document are the
                    // first thing to stop: the dictation is over, and letting
                    // them land behind an error message is worse than an
                    // incomplete sentence.
                    stream.failed = true
                    await stream.drainQueue()
                    // Whatever had already been recognised survives the
                    // failure: a connection that died mid-stream used to take
                    // the words AND the recording (deleted by the defer) with
                    // it, leaving nothing at all. Only when the preview is
                    // still this dictation's, though — read or cleared across
                    // sessions, it was another recording's words being saved
                    // under this one's name and then erased from its overlay.
                    if dictationSession == session {
                        let partial = cancellationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !partial.isEmpty { keepTranscript(partial, from: session) }
                        clearStreamingTranscript(for: stream, session: session)
                    }
                    returnEditClipboard(edit, watcher: editWatcherOwned)
                    // The one cancellation that must still be reported: part of
                    // an edit reached the document before the stop, so the
                    // user's passage is now a fragment of the answer. Saying
                    // nothing would leave them to discover it later, when Undo
                    // is a dozen steps back.
                    if case TextInjectionError.partiallyTyped = error {
                        // Reported only where nothing newer is running:
                        // enterFailedState tears down live state, and a stale
                        // partial edit doing that mid-recording destroyed the
                        // dictation the user had already moved on to. With
                        // something newer under way the fragment is still in
                        // the document, but the newer dictation outranks the
                        // report.
                        if !capturingSelection, dictationSession == session || phase == .idle {
                            enterFailedState(RecoveryAdvice.advice(for: error))
                        }
                        return
                    }
                    // A cancelled dictation is not an error to report, and its
                    // phase belongs to whatever the user started next.
                    if stream.cancelled { return }
                    if error is CancellationError {
                        // Thrown by delivery itself — a target that quit, an
                        // edit whose paste was aborted — with no Escape ever
                        // pressed. The dictation is over either way, and the
                        // phase must not stay busy until the watchdog notices.
                        if dictationSession == session, phase.isBusy {
                            endStep()
                            // The idle transition on its own left a wireless
                            // headset held for the 90-second backstop.
                            finishWirelessDictation()
                            restoreOtherAudio()
                            phase = .idle
                            updateCancelHotKey()
                        }
                        return
                    }
                    // The user moved on. Reporting this would overwrite the
                    // phase of a dictation already under way.
                    if dictationSession != session { return }
                    if error is DataSharingError {
                        enterFailedState(RecoveryAdvice.advice(for: error))
                        return
                    }
                    // Voice-triggered segments must not break the hands-free
                    // cycle: a sneeze or cough that transcribes to nothing is
                    // routine. Only a persistent error (e.g. missing model)
                    // stops listening, so failures cannot loop invisibly.
                    guard isVoiceTriggered else {
                        enterFailedState(RecoveryAdvice.advice(for: error))
                        return
                    }
                    if case TranscriptionError.emptyResponse = error {
                        endStep()
                        phase = .idle
                    } else {
                        voiceFailureStreak += 1
                        if voiceFailureStreak >= 3 {
                            voiceFailureStreak = 0
                            enterFailedState(RecoveryAdvice.advice(for: error))
                        } else {
                            // Quiet retry; the streak above escalates to a
                            // visible failure if it keeps happening.
                            endStep()
                            phase = .idle
                        }
                    }
                }
            }
    }

    private func scheduleMaximumDurationStop() {
        maximumDurationTask?.cancel()
        let seconds = max(5, settings.maximumRecordingSeconds)
        let ticks = settings.countdownBeforeMaximum && settings.playFeedbackSounds
            ? Self.countdownTicks
            : 0
        maximumDurationTask = Task { [weak self] in
            // The quiet part first, then one tick a second through the last
            // few. Both are measured from the same start, so a tick can never
            // arrive after the stop it was warning about.
            if ticks > 0 {
                try? await Task.sleep(for: .seconds(Double(seconds - ticks)))
                guard !Task.isCancelled else { return }
                // The room comes back over the same seconds the ticks occupy.
                // Without it the ticks are inaudible: ducking sets the output
                // device's own volume, so at zero this app is silenced along
                // with everything else. Fading up makes each tick louder than
                // the one before, and the music returning is itself a sign
                // that the take is about to end.
                await MainActor.run { [weak self] in
                    guard let self, case .recording = self.phase else { return }
                    self.audioDucker.restoreGradually(over: .seconds(Double(ticks)))
                }
                for _ in 0 ..< ticks {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard let self, case .recording = self.phase else { return }
                        self.feedbackSoundPlayer.playCountdownTick()
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            } else {
                try? await Task.sleep(for: .seconds(Double(seconds)))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, case .recording = self.phase else { return }
                self.stopAndTranscribe()
            }
        }
    }

    /// How many seconds of warning the countdown gives, one tick each.
    private static let countdownTicks = 5

    private func registerHotKey(_ shortcut: KeyboardShortcut) {
        do {
            try hotKeyManager.register(shortcut)
            hotKeyError = nil
            hotKeyRegistered = true
        } catch {
            hotKeyError = error.localizedDescription
            hotKeyRegistered = false
        }
    }

    private func currentExternalApplicationPID() -> pid_t? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var pid = previousExternalPID
        if let current = NSWorkspace.shared.frontmostApplication, current.processIdentifier != ownPID {
            previousExternalPID = current.processIdentifier
            pid = current.processIdentifier
        }
        insertionTargetName = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        return pid
    }

    private static func microphoneDescription(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Granted"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }

    private static func speechDescription(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Granted"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }
}

/// Which pane the Settings sidebar has selected. Shared so that a recovery
/// card can open Settings straight on Permissions.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case voice
    case engine
    case rewrite
    case output
    case overlay
    case usage
    case permissions
    case licence
    case states

    /// The rail in two parts: the stages a dictation passes through, then the
    /// application itself. Nine flat items led with General, which is the one
    /// pane that has nothing to do with dictating.
    struct Section: Identifiable {
        let label: String
        let panes: [SettingsPane]
        var id: String { label }
    }

    static var sections: [Section] {
        var app: [SettingsPane] = [.general, .permissions, .usage, .licence]
        #if DEBUG
        app.append(.states)
        #endif
        return [
            Section(label: "Dictation", panes: [.voice, .engine, .rewrite, .output, .overlay]),
            Section(label: "App", panes: app),
        ]
    }

    var id: String { rawValue }

    static var visibleCases: [SettingsPane] {
        #if DEBUG
        allCases
        #else
        allCases.filter { $0 != .states }
        #endif
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .voice: return "Recording"
        case .engine: return "Transcription"
        case .output: return "Output"
        case .rewrite: return "Rewrite"
        case .overlay: return "Overlay"
        case .usage: return "Usage"
        case .licence: return "Licence"
        case .permissions: return "Permissions"
        case .states: return "States"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .voice: return "mic"
        case .engine: return "waveform"
        case .rewrite: return "wand.and.stars"
        case .output: return "arrow.turn.down.left"
        case .overlay: return "rectangle.dashed"
        case .usage: return "chart.bar"
        case .licence: return "key"
        case .permissions: return "lock.shield"
        case .states: return "largecircle.fill.circle"
        }
    }

    /// One or two sentences under the title: what the pane is for, and the
    /// fact worth knowing before touching anything in it.
    ///
    /// These absorbed the headlines that used to sit above them. The header
    /// was three lines, an uppercase pane name, a headline, then this; the
    /// name said what the rail already showed, and the headline said in other
    /// words what the title says, so both went and what they carried moved
    /// here.
    var lede: String {
        switch self {
        case .general:
            return "Adjust appearance, startup, sound cues and transcript history to suit your preferences."
        case .voice:
            return "Adjust recording controls to suit how you dictate."
        case .engine:
            return "Choose your transcription engine and adjust how your speech is turned into text."
        case .rewrite:
            return "An optional step after transcription that refines your text the way you want."
        case .output:
            return "Choose how transcripts are inserted and how the clipboard is used."
        case .overlay:
            return "Adjust the recording overlay’s appearance, position and live text preview."
        case .usage:
            return "View transcription and rewriting activity by model, profile and time period."
        case .permissions:
            return "Manage macOS permissions and sharing choices for the features you use."
        case .licence:
            return "Check your trial or licence status and manage activation on this Mac."
        case .states:
            return "Preview how the app looks during each stage of dictation."
        }
    }
}

@MainActor
final class SettingsSelection: ObservableObject {
    /// Recording, not General: the rail now opens on the first stage of a
    /// dictation rather than on the pane that has least to do with one, and
    /// what most people came to change is the shortcut or the microphone.
    @Published var pane: SettingsPane = .voice {
        didSet {
            guard pane != oldValue else { return }
            // The cached report belongs to the pane that made it. Keeping it
            // across a switch let a search be settled against the cards of
            // the pane just left, which could throw away a request the new
            // pane was about to satisfy.
            visibleAnchors = []
            reportingPane = nil
        }
    }
    /// The card a search result asked for, and which ask it was.
    ///
    /// The identity matters: choosing the same result twice in a row is two
    /// requests, and a card that only watched the name would see no change
    /// the second time and never scroll back to itself.
    struct HighlightRequest: Equatable {
        /// What was actually searched for. Kept for the life of the request
        /// even while something else is being shown, because a pane's first
        /// render is not always its final one: the rewrite pane, for one,
        /// settles a flag in `onAppear` and only then shows half its cards.
        /// Without remembering the real destination, that first incomplete
        /// render would redirect to the fallback permanently.
        let desired: String
        /// Where to go while `desired` is not on screen.
        let fallback: String?
        /// What is lit up right now: `desired` once it exists, else
        /// `fallback`.
        var shown: String
        let id: UUID
    }

    @Published var highlightRequest: HighlightRequest?
    private var clearHighlight: Task<Void, Never>?
    /// The cards the open pane last reported, and which pane reported them.
    /// Held so a search made while already standing in the right pane can be
    /// settled at once, rather than waiting for a change that will never
    /// come. Only ever trusted for the pane it came from.
    private var visibleAnchors: Set<String> = []
    private var reportingPane: SettingsPane?

    var highlightedCard: String? { highlightRequest?.shown }

    /// Points a search result at its card, and takes the pointer away again.
    ///
    /// The card scrolls itself into view and glows while this names it. The
    /// glow then goes, because it is an answer to a question that has been
    /// asked once: left on, it would still be lit the next time the pane was
    /// opened for some unrelated reason.
    /// `settleNow` for a search answered without changing pane: the cards on
    /// screen are already the right ones, so no report about them is coming.
    func highlight(_ card: String, fallback: String? = nil, settleNow: Bool = false) {
        let request = HighlightRequest(desired: card, fallback: fallback, shown: card, id: UUID())
        highlightRequest = request
        // Only against a report this pane actually made. Without the check a
        // request could be judged against the previous pane's cards and
        // thrown away before the right ones had a chance to speak.
        if settleNow, reportingPane == pane { resolveHighlight(against: visibleAnchors) }
        clearHighlight?.cancel()
        clearHighlight = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            // By identity, not by value: a request redirected to its fallback
            // is still this request, and comparing the whole thing left that
            // redirected glow lit for good.
            guard self?.highlightRequest?.id == request.id else { return }
            self?.highlightRequest = nil
        }
    }

    /// Forgets any pending request. Walking to a pane by hand is not an
    /// answer to a search, and a request left standing would light a card up
    /// on arrival for no reason the user can connect to anything.
    func forgetHighlight() {
        clearHighlight?.cancel()
        highlightRequest = nil
    }

    /// Settles a request against the cards that actually rendered.
    ///
    /// Which cards exist depends on switches, on a provider being connected,
    /// on a licence state, even on whether a picker happens to be open, and
    /// some of that lives in view state that nothing outside the view can
    /// read. So the question is not asked in advance: the cards report
    /// themselves as they lay out, and a request naming something that is not
    /// among them falls back, or gives up rather than glowing at nothing.
    func resolveHighlight(against visible: Set<String>) {
        visibleAnchors = visible
        reportingPane = pane
        guard var request = highlightRequest, !visible.isEmpty else { return }
        // What was asked for always wins the moment it exists, so a card that
        // only appears on a second pass takes the glow back from the fallback
        // it was standing in for.
        if visible.contains(request.desired) {
            guard request.shown != request.desired else { return }
            request.shown = request.desired
            highlightRequest = request
            return
        }
        if let fallback = request.fallback, visible.contains(fallback) {
            guard request.shown != fallback else { return }
            request.shown = fallback
            highlightRequest = request
            return
        }
        forgetHighlight()
    }
}

/// Both chromeless windows are owned by AppState, which has to learn about a
/// close driven by the red traffic light rather than by a Done button.
private final class AppWindowDelegate: NSObject, NSWindowDelegate {
    private weak var owner: AppState?

    init(owner: AppState) { self.owner = owner }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { @MainActor [weak owner] in owner?.cancelPermissionReturn(for: sender) }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor [weak owner] in owner?.windowDidClose(window) }
    }
}

enum PrivacyPane {
    case microphone
    case accessibility
    case speechRecognition
    case inputMonitoring
    case localNetwork

    var urlString: String {
        switch self {
        case .microphone:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .speechRecognition:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case .inputMonitoring:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .localNetwork:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        }
    }
}
