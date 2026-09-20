import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorderView: View {
    @Binding var shortcut: KeyboardShortcut
    /// Lets the surrounding row change its explanation while capturing.
    var onCapturingChange: ((Bool) -> Void)?
    /// The dictation shortcut may be a lone modifier (right ⇧); action
    /// shortcuts may not, because Carbon cannot register them and a silently
    /// dead shortcut is worse than a beep at record time.
    var allowsModifierOnly = true
    @StateObject private var monitor = ShortcutCaptureMonitor()

    var body: some View {
        Button {
            if monitor.isCapturing {
                monitor.stop()
            } else {
                monitor.start(allowsModifierOnly: allowsModifierOnly) { shortcut = $0 }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: monitor.isCapturing ? "keyboard.badge.ellipsis" : "keyboard")
                    .font(.system(size: 12))
                    .foregroundStyle(monitor.isCapturing ? DS.accent : DS.textSecondary)
                Text(monitor.isCapturing ? "Press shortcut…" : shortcut.displayString)
                    .font(DSFont.mono(12, .medium))
                    .foregroundStyle(DS.textPrimary)
                Spacer(minLength: 8)
                // "Press shortcut…" and "Esc to cancel" have to fit on one
                // line, which is why this control is 290pt wide, not 220.
                Text(monitor.isCapturing ? "Esc to cancel" : "Change")
                    .font(DSFont.ui(11))
                    .foregroundStyle(DS.textSecondary)
            }
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(monitor.isCapturing ? DS.accentTint : DS.surfaceFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(monitor.isCapturing ? DS.accent : DS.borderStrong,
                              lineWidth: monitor.isCapturing ? 1.5 : 1)
        )
        .dsAnimation(DS.control, value: monitor.isCapturing)
        .accessibilityLabel("Keyboard shortcut")
        .accessibilityValue(monitor.isCapturing ? "Recording a new shortcut" : shortcut.displayString)
        .accessibilityHint("Activate, then press the shortcut you want")
        .onChange(of: monitor.isCapturing) { _, capturing in onCapturingChange?(capturing) }
        .onDisappear { monitor.stop() }
        // Capture used to stay armed after switching apps, so the first key
        // typed on returning was swallowed by the recorder.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            monitor.stop()
        }
    }
}

@MainActor
private final class ShortcutCaptureMonitor: ObservableObject {
    @Published private(set) var isCapturing = false
    private var allowsModifierOnly = true
    private var eventMonitor: Any?

    /// A lone modifier press observed during capture. Committed only when the
    /// modifier is released without any other key in between — pressing ⌘
    /// on the way to ⌘Ä must not capture "⌘ alone".
    private var pendingModifier: (keyCode: UInt16, label: String)?

    func start(allowsModifierOnly: Bool, onCapture: @escaping (KeyboardShortcut) -> Void) {
        stop()
        self.allowsModifierOnly = allowsModifierOnly
        isCapturing = true
        pendingModifier = nil
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }

            if event.type == .flagsChanged {
                self.handleFlagsChanged(event, onCapture: onCapture)
                return nil
            }

            if event.keyCode == 53 {
                self.stop()
                return nil
            }

            pendingModifier = nil
            let modifiers = Self.carbonModifiers(from: event.modifierFlags)
            guard modifiers != 0 || Self.allowsBareCapture(event.keyCode) else {
                NSSound.beep()
                return nil
            }

            let shortcut = KeyboardShortcut(
                keyCode: UInt32(event.keyCode),
                modifiers: modifiers,
                keyLabel: Self.keyLabel(for: event)
            )
            onCapture(shortcut)
            self.stop()
            return nil
        }
    }

    private func handleFlagsChanged(_ event: NSEvent, onCapture: (KeyboardShortcut) -> Void) {
        guard allowsModifierOnly else { return }
        guard let label = Self.modifierKeyLabels[event.keyCode] else { return }
        let isDown = Self.isModifierDown(event)
        if isDown {
            pendingModifier = (event.keyCode, label)
        } else if let pending = pendingModifier, pending.keyCode == event.keyCode {
            pendingModifier = nil
            onCapture(KeyboardShortcut(
                keyCode: UInt32(event.keyCode),
                modifiers: 0,
                keyLabel: pending.label
            ))
            stop()
        } else {
            pendingModifier = nil
        }
    }

    func stop() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        pendingModifier = nil
        isCapturing = false
    }

    private static let modifierKeyLabels: [UInt16: String] = [
        54: "Right ⌘", 55: "Left ⌘", 56: "Left ⇧", 58: "Left ⌥",
        59: "Left ⌃", 60: "Right ⇧", 61: "Right ⌥", 62: "Right ⌃",
        63: "fn",
    ]

    /// Bare keys are allowed only when pressing them cannot collide with
    /// typing: function keys, not letters or digits.
    private static func allowsBareCapture(_ keyCode: UInt16) -> Bool {
        let functionKeys: Set<UInt16> = [
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1–F12
            105, 107, 113, 106, 64, 79, 80, // F13–F19
        ]
        return functionKeys.contains(keyCode)
    }

    private static func isModifierDown(_ event: NSEvent) -> Bool {
        if event.keyCode == 63 { return event.modifierFlags.contains(.function) }
        let deviceBits: [UInt16: UInt] = [
            59: 0x0001, 56: 0x0002, 60: 0x0004, 55: 0x0008,
            54: 0x0010, 58: 0x0020, 61: 0x0040, 62: 0x2000,
        ]
        guard let bit = deviceBits[event.keyCode] else { return false }
        return event.modifierFlags.rawValue & bit != 0
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    private static func keyLabel(for event: NSEvent) -> String {
        let specialKeys: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
            115: "Home", 116: "Page Up", 117: "Forward Delete", 119: "End",
            121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
            79: "F18", 80: "F19"
        ]
        if let special = specialKeys[event.keyCode] { return special }
        let characters = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines)
        return characters?.isEmpty == false ? characters!.uppercased() : "Key \(event.keyCode)"
    }
}

