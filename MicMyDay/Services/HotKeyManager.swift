import AppKit
import Carbon
import Foundation
import OSLog

enum HotKeyRegistrationError: LocalizedError {
    case eventHandlerInstallationFailed(OSStatus)
    case registrationFailed(OSStatus)
    case inputMonitoringRequired
    case eventMonitorUnavailable

    var errorDescription: String? {
        switch self {
        case let .eventHandlerInstallationFailed(status):
            return "The global shortcut listener could not be installed (macOS error \(status))."
        case let .registrationFailed(status):
            return "The shortcut could not be registered (macOS error \(status)). It may already be used by another app."
        case .inputMonitoringRequired:
            return "Allow Input Monitoring for a modifier-only shortcut, or choose a modifier plus a regular key."
        case .eventMonitorUnavailable:
            return "macOS could not start the modifier-key listener. Check Input Monitoring permission or choose a regular key combination."
        }
    }
}

final class HotKeyManager {
    private static let signature: OSType = 0x4D_49_43_54 // MICT
    private static let identifier: UInt32 = 1
    private static let logger = Logger(subsystem: "com.micmyday.app", category: "GlobalShortcut")

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var modifierEventTap: CFMachPort?
    private var modifierRunLoopSource: CFRunLoopSource?
    private var isPressedDown = false
    private(set) var registeredShortcut: KeyboardShortcut?
    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?

    var isRegistered: Bool {
        (hotKey != nil || modifierEventTap.map { CGEvent.tapIsEnabled(tap: $0) } == true)
            && registeredShortcut != nil
    }

    deinit {
        unregister()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func register(_ shortcut: KeyboardShortcut) throws {
        if isRegistered, registeredShortcut == shortcut {
            return
        }

        unregister()

        // A lone modifier key (right ⇧, fn, …) is not a Carbon hot key —
        // its press/release only surfaces as flagsChanged events.
        if shortcut.isModifierOnly {
            try installFlagsMonitor()
            registeredShortcut = shortcut
            Self.logger.notice("Watching lone modifier shortcut: keyCode=\(shortcut.keyCode)")
            return
        }

        try installEventHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: Self.identifier
        )
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            OptionBits(kEventHotKeyExclusive),
            &reference
        )

        guard status == noErr, let reference else {
            throw HotKeyRegistrationError.registrationFailed(status)
        }
        hotKey = reference
        registeredShortcut = shortcut
        Self.logger.notice(
            "Registered global shortcut: keyCode=\(shortcut.keyCode), modifiers=\(shortcut.modifiers)"
        )
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let source = modifierRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = modifierEventTap { CFMachPortInvalidate(tap) }
        modifierRunLoopSource = nil
        modifierEventTap = nil
        registeredShortcut = nil
        isPressedDown = false
    }

    /// A listen-only event tap uses the separate Input Monitoring permission,
    /// which is supported in sandboxed apps. It only observes modifier flags,
    /// never typed text, and doesn't consume or alter keyboard input.
    private func installFlagsMonitor() throws {
        guard CGPreflightListenEventAccess() else { throw HotKeyRegistrationError.inputMonitoringRequired }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1) << CGEventType.flagsChanged.rawValue,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if CGPreflightListenEventAccess(), let tap = manager.modifierEventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                } else if type == .flagsChanged {
                    // Check the key code straight off the CGEvent first. This
                    // callback runs for every modifier press anywhere on the
                    // system, and building an NSEvent for all of them just to
                    // discard it was needless work on the event tap thread.
                    let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
                    if manager.wantsModifierKeyCode(keyCode), let keyEvent = NSEvent(cgEvent: event) {
                        manager.handleFlagsChanged(keyEvent)
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { throw HotKeyRegistrationError.eventMonitorUnavailable }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw HotKeyRegistrationError.eventMonitorUnavailable
        }
        modifierEventTap = tap
        modifierRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Cheap pre-filter for the event tap: true only when this key code is the
    /// modifier-only shortcut we registered.
    fileprivate func wantsModifierKeyCode(_ keyCode: UInt32) -> Bool {
        guard let shortcut = registeredShortcut, shortcut.isModifierOnly else { return false }
        return shortcut.keyCode == keyCode
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard let shortcut = registeredShortcut, shortcut.isModifierOnly,
              UInt32(event.keyCode) == shortcut.keyCode else { return }
        let pressed = Self.isModifierPressed(event: event, keyCode: shortcut.keyCode)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if pressed {
                guard !self.isPressedDown else { return }
                self.isPressedDown = true
                self.onPressed?()
            } else {
                guard self.isPressedDown else { return }
                self.isPressedDown = false
                self.onReleased?()
            }
        }
    }

    /// The device-independent flags cannot tell left from right (releasing
    /// right ⇧ while left ⇧ is held still reports .shift), so the per-key
    /// device-dependent bits are checked instead. fn has no side variants and
    /// uses the generic flag.
    private static func isModifierPressed(event: NSEvent, keyCode: UInt32) -> Bool {
        if keyCode == 63 { return event.modifierFlags.contains(.function) }
        let deviceBits: [UInt32: UInt] = [
            59: 0x0001, 56: 0x0002, 60: 0x0004, 55: 0x0008,
            54: 0x0010, 58: 0x0020, 61: 0x0040, 62: 0x2000,
        ]
        guard let bit = deviceBits[keyCode] else { return false }
        return event.modifierFlags.rawValue & bit != 0
    }

    private func installEventHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]

        var reference: EventHandlerRef?
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            micMyDayHotKeyHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &reference
        )

        guard status == noErr, let reference else {
            throw HotKeyRegistrationError.eventHandlerInstallationFailed(status)
        }
        eventHandler = reference
    }

    /// Internal (not fileprivate) so tests can drive the press/release logic.
    ///
    /// While the shortcut is held, keyboard auto-repeat delivers additional
    /// `kEventHotKeyPressed` events. Without filtering, each repeat looks like
    /// a fresh press — which stopped a hold-to-talk recording mid-hold and
    /// instantly killed tap recordings whenever the keys were held a beat too
    /// long. Only the first press and the matching release are forwarded.
    /// Returns false when the hot key belongs to another handler, so the Carbon
    /// dispatcher keeps offering the event onwards instead of it being
    /// swallowed here.
    @discardableResult
    func receiveHotKey(_ id: EventHotKeyID, kind: UInt32) -> Bool {
        guard id.signature == Self.signature, id.id == Self.identifier else { return false }
        Self.logger.notice("Received global shortcut event kind=\(kind)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if kind == UInt32(kEventHotKeyReleased) {
                guard self.isPressedDown else { return }
                self.isPressedDown = false
                self.onReleased?()
            } else {
                guard !self.isPressedDown else { return } // key auto-repeat
                self.isPressedDown = true
                self.onPressed?()
            }
        }
        return true
    }
}

private func micMyDayHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

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

    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    return manager.receiveHotKey(hotKeyID, kind: GetEventKind(event)) ? noErr : OSStatus(eventNotHandledErr)
}
