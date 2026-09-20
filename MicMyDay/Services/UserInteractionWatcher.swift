import AppKit
import CoreGraphics
import OSLog

/// Notices the user touching the keyboard or mouse while text is being typed
/// into another app.
///
/// Streaming can only guarantee where its words land as long as focus does not
/// move. The App Sandbox rules out reading another app's focused element, so
/// the focus itself is not observable; what *is* observable, using the Input
/// Monitoring permission MicMyDay already needs, is the input that usually
/// causes the move. Treating any real key or mouse event as "focus may have
/// moved" narrows the window a process check leaves open.
///
/// It does not close it. This is a mitigation, not a guarantee, and two gaps
/// remain by construction: focus that moves with no user input at all, such as
/// a web page focusing another field itself, is invisible here; and the
/// monitor delivers asynchronously, so a click is noticed shortly after it
/// happens rather than before the next batch is posted. Under the sandbox
/// there is no way to close either without cooperation from the target app.
///
/// This deliberately over-triggers: typing a stray key during dictation stops
/// streaming even though focus did not actually move. Stopping is cheap, since
/// the rest of the transcript simply goes to the clipboard, while guessing
/// wrong in the other direction puts the user's words in someone else's
/// message.
@MainActor
final class UserInteractionWatcher {
    private static let logger = Logger(subsystem: "com.micmyday.app", category: "interaction")

    /// Stamped onto the events MicMyDay posts, so its own typing does not read
    /// as the user interrupting. Any value works as long as nothing else uses
    /// it; this one is arbitrary and specific enough not to collide.
    static let syntheticEventMarker: Int64 = 0x4D_46_41_49_52_59

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var onInteraction: (() -> Void)?
    private var origin: NSPoint?

    /// A window whose events never count as the user leaving. The recording
    /// overlay's stop button and profile picker live in one, and a click that
    /// exists to control the dictation must not read as abandoning it; the
    /// control's own action decides what happens instead.
    ///
    /// Resolved at event time, not at start: the overlay's panel is created
    /// lazily on its first present, which can be after the watcher starts.
    ///
    /// Deliberately narrow: pointer travel towards the panel still counts as
    /// leaving, because travel is indistinguishable from reaching for another
    /// window, and the phases that run a watcher are exactly the ones where
    /// moving away must cancel. In those phases the only overlay control that
    /// matters is the stop button, and there a cancellation is the intended
    /// outcome by either route.
    var exemptWindow: (() -> NSWindow?)?

    /// How far the pointer must travel before it counts as the user moving it.
    ///
    /// Movement matters because some terminals focus whichever window is under
    /// the pointer, which changes the destination with no click at all. Windows
    /// sit directly against each other, so crossing from one into the next can
    /// take only a few points; the threshold exists purely to ignore the jitter
    /// of a hand resting on the mouse, and is deliberately small.
    private static let pointerTravelThreshold: CGFloat = 6

    /// Starts watching. `onInteraction` is called at most once.
    func start(onInteraction: @escaping () -> Void) {
        stop()
        self.onInteraction = onInteraction
        origin = NSEvent.mouseLocation

        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .mouseMoved,
        ]
        // A global monitor sees events destined for other apps and cannot
        // consume them, which is what is wanted here: this observes, it never
        // interferes with what the user is doing.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.consider(event)
        }
        // Global monitors deliberately exclude the app that installs them, so
        // clicking MicMyDay's own menu or settings would go unseen without
        // this second monitor.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.consider(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        onInteraction = nil
        origin = nil
    }

    private func consider(_ event: NSEvent) {
        guard onInteraction != nil, !Self.isSynthetic(event) else { return }
        if let window = event.window, window === exemptWindow?() { return }
        if event.type == .mouseMoved {
            guard let origin else { return }
            let now = NSEvent.mouseLocation
            let travelled = hypot(now.x - origin.x, now.y - origin.y)
            guard travelled >= Self.pointerTravelThreshold else { return }
        }
        Self.logger.notice("User input during delivery; streaming stops here")
        let callback = onInteraction
        stop()
        callback?()
    }

    /// True for the events MicMyDay posted itself.
    private static func isSynthetic(_ event: NSEvent) -> Bool {
        guard let cgEvent = event.cgEvent else { return false }
        return cgEvent.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker
    }

    deinit {
        // Not `stop()`: deinit is nonisolated, and monitor tokens can be
        // removed from anywhere.
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
