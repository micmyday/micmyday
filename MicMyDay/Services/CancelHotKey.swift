import AppKit
import Carbon

/// Registers Escape as a global hot key only while a recording is live, so a
/// dictation can be abandoned from anywhere: no transcription, no paste,
/// nothing. Outside of recording the key is never claimed, so Escape keeps
/// its normal meaning in every app.
///
/// Separate from the other hot key managers for the same reason they are
/// separate from each other: this one's registration is tied to the recording
/// lifecycle, not to settings.
@MainActor
final class CancelHotKey {
    nonisolated private static let signature: OSType = 0x4D_49_43_43 // MICC
    nonisolated private static let identifier: UInt32 = 90

    private var reference: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    var onCancel: (() -> Void)?

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func arm() {
        guard reference == nil else { return }
        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            EventHotKeyID(signature: Self.signature, id: Self.identifier),
            GetEventDispatcherTarget(),
            OptionBits(kEventHotKeyExclusive),
            &ref
        )
        if status == noErr { reference = ref }
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
            cancelHotKeyHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &reference
        )
        if status == noErr { eventHandler = reference }
    }

    /// Returns false for hot keys that belong to someone else, so the Carbon
    /// dispatcher keeps offering the event to the next handler. Claiming every
    /// event here swallowed the dictation and profile shortcuts while a
    /// recording was running.
    fileprivate nonisolated func receive(_ id: EventHotKeyID) -> Bool {
        guard id.signature == Self.signature, id.id == Self.identifier else { return false }
        Task { @MainActor [weak self] in
            self?.onCancel?()
        }
        return true
    }
}

private func cancelHotKeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<CancelHotKey>.fromOpaque(context).takeUnretainedValue()

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
