import Carbon.HIToolbox
import Foundation
import OSLog

/// The Space key, armed only while the dictation shortcut is being held.
///
/// Tapping it turns the hold into a hands-free recording: the shortcut can
/// be released and the take keeps running until it is stopped the ordinary
/// way. Registered as an exclusive Carbon hot key exactly like the Escape
/// cancel key next door, which is what consumes the keystroke — a stray
/// space must not land in the document under the cursor — without an event
/// tap and without any permission beyond what the app already holds. The
/// rest of the time Space is not intercepted at all.
@MainActor
final class HandsFreeKey {
    nonisolated private static let signature: OSType = 0x4D_49_43_43 // MICC
    nonisolated private static let identifier: UInt32 = 91

    private var reference: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    var onUpgrade: (() -> Void)?

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// `modifiers` is the Carbon mask of whatever the user is holding for
    /// the dictation shortcut itself. While that hold is down, the system
    /// sees Space AS modified — a plain-Space registration never matched
    /// and the upgrade silently did nothing.
    func arm(modifiers: UInt32) {
        guard reference == nil else { return }
        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            modifiers,
            EventHotKeyID(signature: Self.signature, id: Self.identifier),
            GetEventDispatcherTarget(),
            OptionBits(kEventHotKeyExclusive),
            &ref
        )
        if status == noErr {
            reference = ref
        } else {
            // Another app may hold Space exclusively. The gesture then
            // cannot work this session; said out loud here because its
            // symptom — a space landing in the document — looks like a bug
            // somewhere else entirely.
            Logger(subsystem: "com.micmyday.app", category: "HandsFree")
                .notice("Space could not be registered (status \(status)); hands-free upgrade unavailable")
        }
    }

    func disarm() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        ]
        var reference: EventHandlerRef?
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            handsFreeKeyHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &reference
        )
        if status == noErr { eventHandler = reference }
    }

    /// Returns false for hot keys that belong to someone else, so the Carbon
    /// dispatcher keeps offering the event to the next handler.
    fileprivate nonisolated func receive(_ id: EventHotKeyID) -> Bool {
        guard id.signature == Self.signature, id.id == Self.identifier else { return false }
        Task { @MainActor [weak self] in
            self?.onUpgrade?()
        }
        return true
    }
}

private func handsFreeKeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HandsFreeKey>.fromOpaque(context).takeUnretainedValue()

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
