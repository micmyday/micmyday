import AppKit
import SwiftUI

@main
struct MicMyDayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: SettingsStore
    @StateObject private var appState: AppState

    init() {
        Self.yieldToExistingInstance()
        let settings = SettingsStore()
        _settings = StateObject(wrappedValue: settings)
        _appState = StateObject(wrappedValue: AppState(settings: settings))
    }

    /// True while XCTest is hosting this process.
    ///
    /// A test run must put nothing on screen. The suite runs dozens of times
    /// a day during development, and a menu bar item, a setup assistant and
    /// whatever else the app opens at launch appearing and vanishing each
    /// time is the developer's screen being taken over by a build.
    static let isRunningTests = NSClassFromString("XCTestCase") != nil

    /// Keep the oldest instance and exit only our own process. A sandboxed
    /// app must not terminate other processes, including an older copy.
    /// Quit an existing copy explicitly before trying a newly built version.
    private static func yieldToExistingInstance() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let own = NSRunningApplication.current
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where other.processIdentifier != own.processIdentifier {
            if Self.ranksBelow(other, own) {
                other.activate()
                exit(0)
            }
        }
    }

    /// Stable ordering: the older launch date, then the lower PID, wins.
    private static func ranksBelow(_ lhs: NSRunningApplication, _ rhs: NSRunningApplication) -> Bool {
        let lhsDate = lhs.launchDate ?? .distantPast
        let rhsDate = rhs.launchDate ?? .distantPast
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhs.processIdentifier < rhs.processIdentifier
    }

    var body: some Scene {
        // Not inserted while tests host this process: no menu bar item, and
        // nothing on screen that can take focus from whatever the developer
        // is doing. Tests drive their own AppState instances directly, so the
        // app's own scene has no part to play in them.
        MenuBarExtra(isInserted: .constant(!Self.isRunningTests)) {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(settings)
        } label: {
            MenuBarLabel()
                .environmentObject(appState.menuBar)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appState.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }

            // Keep ⌘Q alongside the panel's explicit Quit button. Disable the
            // shortcut during dictation so a stray keypress doesn't discard
            // it; the visible Quit button remains available deliberately.
            CommandGroup(replacing: .appTermination) {
                Button("Quit MicMyDay") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
                    .disabled(appState.phase.isBusy || appState.phase.isRecording)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // whisper.cpp's Metal backend asserts in an atexit destructor
        // (GGML_ASSERT in ggml-metal-device.m) if a context is still loaded,
        // turning an ordinary quit into an abort. Free the context explicitly
        // and let termination proceed normally, so UserDefaults and other
        // exit handlers are not skipped. If an inference is still running the
        // context cannot be freed in time; skip the exit handlers instead of
        // hanging the quit or tripping the assert.
        // Both engines sit on the same ggml runtime and both can be holding a
        // Metal context, so both have to be freed here.
        let rewriterUnloaded = LlamaCppEngine.shared.unloadForTermination()
        if !WhisperCppEngine.shared.unloadForTermination() || !rewriterUnloaded {
            // _exit skips the automatic preferences flush, so settings changed
            // moments before this quit would be lost.
            UserDefaults.standard.synchronize()
            _exit(0)
        }
    }
}
