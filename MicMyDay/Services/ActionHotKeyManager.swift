import AppKit
import Carbon
import os

/// Global shortcuts that fire a one-shot action, keyed by an action id.
///
/// Deliberately separate from `HotKeyManager`, which owns the dictation
/// shortcut and needs press/release semantics for push-to-talk. These only
/// need "it was pressed", and there can be any number of them, so keeping them
/// apart avoids complicating the one shortcut that must never misbehave.
///
/// A distinct Carbon signature from `HotKeyManager` keeps the two handlers from
/// claiming each other's events: both are installed on the same dispatcher
/// target, and a handler that reports "handled" stops the event reaching the
/// next one, which previously let a registered profile shortcut swallow the
/// dictation shortcut. Ids also start at 100 for good measure.
@MainActor
final class ActionHotKeyManager {
    nonisolated private static let signature: OSType = 0x4D_49_43_41 // MICA
    private static let firstIdentifier: UInt32 = 100
    private static let logger = Logger(subsystem: "com.micmyday.app", category: "ActionShortcuts")

    private var registrations: [UInt32: (action: String, ref: EventHotKeyRef)] = [:]
    private var eventHandler: EventHandlerRef?

    /// Called with the action id of whichever shortcut was pressed.
    var onTriggered: ((String) -> Void)?

    deinit {
        for (_, registration) in registrations {
            UnregisterEventHotKey(registration.ref)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    /// Replaces every registration with the given set. Shortcuts that macOS
    /// or another app already owns are skipped rather than failing the batch:
    /// one unavailable combination must not disarm the others.
    func register(_ shortcuts: [String: KeyboardShortcut]) {
        unregisterAll()
        guard !shortcuts.isEmpty else { return }
        installEventHandlerIfNeeded()

        var identifier = Self.firstIdentifier
        for (action, shortcut) in shortcuts.sorted(by: { $0.key < $1.key }) {
            // A lone modifier cannot be a Carbon hot key. Bare function keys
            // are fine: Carbon registers them with zero modifiers, and the
            // recorder only allows bare capture for keys that cannot collide
            // with typing.
            guard !shortcut.isModifierOnly else { continue }

            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers,
                EventHotKeyID(signature: Self.signature, id: identifier),
                GetEventDispatcherTarget(),
                OptionBits(kEventHotKeyExclusive),
                &reference
            )
            if status == noErr, let reference {
                registrations[identifier] = (action, reference)
                identifier += 1
            } else {
                Self.logger.error("Could not register \(action, privacy: .public): status \(status)")
            }
        }
    }

    func unregisterAll() {
        for (_, registration) in registrations {
            UnregisterEventHotKey(registration.ref)
        }
        registrations = [:]
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        ]
        var reference: EventHandlerRef?
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            actionHotKeyHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &reference
        )
        if status == noErr { eventHandler = reference }
    }

    /// False when the hot key is not ours, so the event still reaches other
    /// handlers rather than being swallowed.
    fileprivate nonisolated func receive(_ id: EventHotKeyID) -> Bool {
        guard id.signature == Self.signature else { return false }
        Task { @MainActor [weak self] in
            guard let self, let registration = self.registrations[id.id] else { return }
            self.onTriggered?(registration.action)
        }
        return true
    }
}

private func actionHotKeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<ActionHotKeyManager>.fromOpaque(context).takeUnretainedValue()

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    return manager.receive(hotKeyID) ? noErr : OSStatus(eventNotHandledErr)
}
