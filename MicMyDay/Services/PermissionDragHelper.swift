import AppKit
import SwiftUI

/// A small floating panel shown alongside System Settings: the app icon,
/// draggable straight into the Accessibility or Input Monitoring list.
///
/// The sandboxed build cannot register itself with TCC, so MicMyDay never
/// appears in those lists on its own and the user would otherwise have to
/// find the "+" button and dig the app out of a file dialog. Dragging the
/// icon carries the bundle's file URL, which the list accepts as a drop.
@MainActor
final class PermissionDragHelper {
    private var panel: NSPanel?
    private(set) var issue: PermissionIssue?
    var onDismiss: (() -> Void)?
    /// The red traffic light closes the panel without going through `dismiss`,
    /// which used to strand a permission-polling client for the app's lifetime.
    private lazy var closeObserver = PanelCloseObserver { [weak self] in self?.dismiss() }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(for issue: PermissionIssue) {
        hide()
        self.issue = issue
        let root = PermissionDragHelperView(issue: issue) { [weak self] in
            self?.dismiss()
        }
        let hosting = NSHostingController(rootView: root)
        hosting.safeAreaRegions = []
        let panel = NonKeyPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // The panel moves by its background everywhere except the icon,
        // which opts out (mouseDownCanMoveWindow) to keep its file drag.
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(srgbRed: 0.043, green: 0.039, blue: 0.078, alpha: 1)
        panel.setContentSize(hosting.view.fittingSize)
        panel.center()
        panel.delegate = closeObserver
        panel.orderFrontRegardless()
        self.panel = panel
        // System Settings usually hasn't finished opening its window yet, so
        // snap next to it once it exists (and again in case it moved).
        snapNextToSystemSettings()
        for delay in [0.8, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.snapNextToSystemSettings()
            }
        }
    }

    /// Places the panel directly beside the System Settings window, so the
    /// icon and the list it should be dropped into are both in view.
    private func snapNextToSystemSettings() {
        guard let panel, panel.isVisible, let target = Self.systemSettingsWindowFrame() else { return }
        let size = panel.frame.size
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        var x = target.minX - size.width - 20
        if x < screen.minX + 8 { x = target.maxX + 20 }
        let y = min(max(target.midY - size.height / 2, screen.minY + 8), screen.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static func systemSettingsWindowFrame() -> NSRect? {
        guard
            let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.systempreferences").first,
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]]
        else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for info in list {
            guard
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                pid == app.processIdentifier,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict),
                bounds.width > 300, bounds.height > 300
            else { continue }
            // CGWindowList uses a top-left origin; AppKit a bottom-left one.
            return NSRect(
                x: bounds.origin.x,
                y: primaryHeight - bounds.origin.y - bounds.height,
                width: bounds.width,
                height: bounds.height
            )
        }
        return nil
    }

    /// User-facing dismissal: also notifies the owner so it can stop polling.
    /// Idempotent, because the Close button and the window delegate can both
    /// arrive for a single dismissal and the owner's polling count must only
    /// be released once.
    func dismiss() {
        guard panel != nil else { return }
        hide()
        onDismiss?()
    }

    private func hide() {
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        issue = nil
    }
}

private struct PermissionDragHelperView: View {
    let issue: PermissionIssue
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Drag MicMyDay into the \(issue.name) list")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.mfTextPrimary)
                .multilineTextAlignment(.center)

            DraggableAppIcon()
                .frame(width: 84, height: 84)

            Text("Drop the icon anywhere in the app list in System Settings, then turn its switch on. This panel closes by itself once the permission is granted.")
                .font(.system(size: 11))
                .lineSpacing(2)
                .foregroundStyle(Color.mfTextPrimary.opacity(0.65))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Close", action: onDone)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.55))
        }
        .padding(20)
        .frame(width: 250)
        .background(Color.mfCanvas)
    }
}

/// Mouse-only: if the panel can become key it steals keyboard input from
/// whatever the user is really working in, including the macOS password
/// prompt shown while granting the permission.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// An AppKit dragging source: SwiftUI's onDrag inside a nonactivating panel
/// loses the gesture to window movement, so the file drag starts directly
/// on mouse-down here.
private struct DraggableAppIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> DragIconView { DragIconView() }
    func updateNSView(_ view: DragIconView, context: Context) {}
}

private final class DragIconView: NSView, NSDraggingSource {
    private let icon: NSImage = {
        let image = NSApp.applicationIconImage ?? NSImage()
        image.size = NSSize(width: 84, height: 84)
        return image
    }()

    override var intrinsicContentSize: NSSize { NSSize(width: 84, height: 84) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        [.copy, .generic]
    }
}

/// Routes a native window close through the helper's own cleanup.
private final class PanelCloseObserver: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
