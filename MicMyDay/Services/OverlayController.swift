import AppKit
import SwiftUI

/// Owns the floating overlay's window.
///
/// A non-activating panel that never steals focus from whatever you are
/// dictating into. It ignores mouse events whenever the overlay is a pure
/// status light; while a dictation is running the pill carries a stop button
/// and a profile picker, so the panel accepts clicks then — without ever
/// becoming key or activating the app.
@MainActor
final class OverlayController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    /// True while any menu in this process is tracking, which during a
    /// recording means the pill's own profile picker. The panel drops to
    /// pop-up level only for exactly that long; see `present`.
    private var menuTracking = false
    /// The tokens for the menu-tracking registrations, removed in `deinit`.
    /// Holding them is not itself enough: a block-based observer stays
    /// registered until the centre is told to drop it, however the token is
    /// stored, which the comment here used to claim was handled.
    private var menuObservers: [NSObjectProtocol] = []

    deinit {
        menuObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// The panel is sized to its content, so the pill's outer glow had nothing
    /// to render into and was sliced off square at the window edge. The content
    /// is inset by this much on every side to give the glow room; the padding
    /// is transparent and clicks pass through it like the rest of the panel.
    private static let glowPadding: CGFloat = 34

    /// Bumped on every present, so a fade-out still in flight cannot order the
    /// panel out from under a recording that started meanwhile.
    private var generation = 0

    var isVisible: Bool { panel?.isVisible ?? false }

    /// For the interaction watcher's exemption; see `UserInteractionWatcher`.
    var window: NSWindow? { panel }

    /// Re-measures and moves, for live changes while the Settings pane is open.
    func update(
        _ view: some View,
        size: OverlaySize,
        position: OverlayPosition,
        opacity: Double,
        interactive: Bool = false
    ) {
        present(view, size: size, position: position, opacity: opacity, interactive: interactive)
    }

    /// Builds the panel and its hosting view, once.
    ///
    /// Separated from `present` so it can be paid for before it is needed.
    /// Creating an `NSPanel` with an `NSHostingView` inside it, and laying
    /// that view out for the first time, measured around 135 ms on this Mac,
    /// against roughly 4 ms for every later one: one-time AppKit and SwiftUI
    /// machinery, not the pill's own drawing. That first bill used to land on
    /// the first dictation of the session, which is the worst moment to pay
    /// it, because the user has already pressed the shortcut and started
    /// talking.
    func prepare() {
        // Only the call that builds it does any work. Laying out again on
        // later calls would cost a measurement for nothing, and those calls
        // can arrive while the real pill is on screen.
        guard hosting == nil else { return }
        makePanelIfNeeded()
        // A new window sits at the screen's origin, the bottom left corner.
        // It is ordered out so nothing shows there, but parking it in the
        // middle means nothing can paint from that corner either.
        if let panel, let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX, y: screen.frame.midY))
        }
        // One layout pass while nothing is waiting on it. The panel is never
        // ordered on screen here, so none of this is visible.
        _ = hosting?.fittingSize
    }

    private func makePanelIfNeeded() {
        guard hosting == nil else { return }
        let hostingView = FirstClickHostingView(rootView: AnyView(Color.clear.frame(width: 1, height: 1)))
        hostingView.autoresizingMask = [.width, .height]
        hosting = hostingView

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        // Above ordinary windows, floating panels and other status items.
        // At .statusBar the pill ended up buried behind whatever the user
        // was dictating into, which defeats the point of a status light.
        panel.level = .screenSaver
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        // Follows the user across Spaces and sits over full-screen apps,
        // which is exactly where dictation happens.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.panel = panel

        // The profile picker's menu draws at pop-up level, which sits
        // *below* this panel's usual screen-saver level, so it opened
        // behind the very pill it came from. Holding the panel at pop-up
        // level for the whole recording was no better: anything else at
        // that level could then cover the pill. So the panel steps down
        // only while a menu is actually tracking, and steps back up the
        // moment it closes.
        menuObservers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.menuTracking = true
                panel.level = .popUpMenu
            }
        })
        menuObservers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.menuTracking = false
                panel.level = .screenSaver
                if panel.isVisible { panel.orderFrontRegardless() }
            }
        })
}

    /// One path in and out.
    ///
    /// Showing and updating used to be separate, and the update path never
    /// restored `alphaValue` — so once a recording had faded the panel out, the
    /// next one ordered a fully transparent window to the front and nothing
    /// appeared from the second dictation onwards.
    private func present(
        _ view: some View,
        size: OverlaySize,
        position: OverlayPosition,
        opacity: Double,
        interactive: Bool
    ) {
        // Frozen while the pill's own menu is open: the recording ticker
        // replaces the view ten times a second, each replacement regenerates
        // the open menu's rows, and the row icons visibly re-render in a
        // loop. A meter that pauses for the moment a menu is open is not
        // noticeable; the flicker was.
        if menuTracking, panel?.isVisible == true { return }
        let root = AnyView(view.padding(Self.glowPadding))

        makePanelIfNeeded()
        hosting?.rootView = root

        guard let panel, let hosting else { return }
        generation += 1
        // Click-through except while the pill actually offers something to
        // click. SwiftUI's own hit testing keeps the transparent glow margin
        // and the gaps between views permeable even then.
        panel.ignoresMouseEvents = !interactive

        // Laid out before it is measured. `fittingSize` on a hosting view
        // whose root has just been replaced reports the previous layout, so
        // the first show sized the window from an empty view and placed it by
        // that size. The real size arriving a frame later then grew the panel
        // upward from a bottom-anchored origin, which looks exactly like it
        // rising out of the bottom edge of the screen.
        hosting.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.fittingSize)
        reposition(position)

        // Re-assert the front position every time: another app going
        // full-screen or a new window can otherwise leave it behind.
        // Compared against the chosen opacity, not against 1: at 70% the panel
        // rests below any fixed threshold, and every update would have read as
        // hidden and replayed the entry fade.
        let target = CGFloat(min(1, max(0.01, opacity)))
        let wasHidden = !panel.isVisible || panel.alphaValue < target - 0.01
        if !panel.isVisible { panel.alphaValue = 0 }
        // Not re-asserted while the pill's own menu is open: the recording
        // ticker updates this ten times a second, and each order-front pushed
        // the panel back above its menu the moment it opened. Every other
        // moment keeps the reassertion, which is what recovers the pill after
        // another app goes full screen mid-recording.
        if wasHidden || !menuTracking {
            panel.orderFrontRegardless()
        }

        guard wasHidden else {
            // Already up: a changed opacity applies at once, with no fade.
            panel.alphaValue = target
            return
        }
        // Position is a setting, so the entry is a plain fade: a directional
        // rise would be wrong for four of the six spots.
        //
        // The design specifies 260 ms, but this fires the instant you press the
        // shortcut and you are already talking — a fade you notice is a fade
        // that is in the way. Shortened to 150 ms.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = target
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        // The fade lasts 120 ms, and an interactive panel that kept accepting
        // clicks while fading swallowed one click aimed at whatever is behind
        // it.
        panel.ignoresMouseEvents = true
        generation += 1
        let token = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            // A recording may have started during the fade; only finish the
            // hide if nothing has presented since.
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                panel?.orderOut(nil)
            }
        }
    }

    /// Uses `visibleFrame` rather than `frame`, which is what keeps the insets
    /// honest when the Dock moves, hides, or changes size.
    /// Where the user has dragged it, for this dictation only.
    ///
    /// Held here rather than in the settings because it is not a preference:
    /// the indicator is in the way of this paragraph, in this window, right
    /// now. It is cleared the moment the overlay goes, so the next dictation
    /// starts from the position that was actually chosen.
    private(set) var dragOffset: CGSize = .zero

    func moveBy(_ translation: CGSize) {
        dragOffset.width += translation.width
        dragOffset.height += translation.height
        if let panel {
            panel.setFrameOrigin(NSPoint(
                x: (panel.frame.origin.x + translation.width).rounded(),
                y: (panel.frame.origin.y + translation.height).rounded()
            ))
        }
    }

    func clearDrag() { dragOffset = .zero }

    private func reposition(_ position: OverlayPosition) {
        guard let panel else { return }
        let screen = screenUnderCursor()
        let area = screen.visibleFrame
        let size = panel.frame.size
        // The window is larger than the pill by the transparent glow margin,
        // so the inset has to be measured from the pill's edge, not the
        // window's, or every position sits 34pt too far in.
        let bleed = Self.glowPadding

        let x: CGFloat
        switch position.horizontal {
        case .leading: x = area.minX + OverlayPosition.horizontalInset - bleed
        case .centre: x = area.midX - size.width / 2
        case .trailing: x = area.maxX - size.width + bleed - OverlayPosition.horizontalInset
        }

        let y: CGFloat
        switch position.vertical {
        case .top: y = area.maxY - size.height + bleed - position.verticalInset
        case .middle: y = area.midY - size.height / 2
        case .bottom: y = area.minY + position.verticalInset - bleed
        }

        panel.setFrameOrigin(NSPoint(
            x: (x + dragOffset.width).rounded(),
            y: (y + dragOffset.height).rounded()
        ))
    }

    /// On a multi-display Mac the overlay belongs on the screen the user is
    /// working on, which is the one holding the cursor.
    private func screenUnderCursor() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

/// The overlay is never the key window, so without this the first click on
/// its stop button would only bring the panel forward and the user would have
/// to click twice to stop the thing they can see running.
private final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
