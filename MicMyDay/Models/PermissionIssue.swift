import Foundation

/// Capability-specific guidance, separate from transcription failures.
enum PermissionIssue: String, Identifiable, Equatable {
    case microphone, speechRecognition, inputMonitoring, accessibility

    var id: String { rawValue }
    var name: String {
        switch self {
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        }
    }
    var title: String {
        switch self {
        case .microphone: return "Microphone access needed"
        case .speechRecognition: return "Speech Recognition access needed"
        case .inputMonitoring: return "Shortcut needs permission"
        case .accessibility: return "Automatic paste unavailable"
        }
    }
    var detail: String {
        switch self {
        case .microphone: return "MicMyDay cannot record until you allow microphone access."
        case .speechRecognition: return "Apple Speech needs Speech Recognition access. Local models and other providers do not."
        case .inputMonitoring: return "Your modifier-only shortcut needs Input Monitoring. You can still use Start dictation or choose a regular key combination."
        case .accessibility: return "Dictation still works, but text is copied instead of pasted automatically. Press ⌘V, or allow Accessibility for automatic pasting."
        }
    }
    var blocksRecording: Bool { self == .microphone || self == .speechRecognition }

    static func missing(
        microphone: Bool, speech: Bool, accessibility: Bool, inputMonitoring: Bool,
        provider: TranscriptionProviderKind, modifierOnlyShortcut: Bool,
        automaticPaste: Bool
    ) -> [Self] {
        var issues: [Self] = []
        if !microphone { issues.append(.microphone) }
        if provider == .appleSpeech, !speech { issues.append(.speechRecognition) }
        if modifierOnlyShortcut, !inputMonitoring { issues.append(.inputMonitoring) }
        // Accessibility exists only to paste. Reporting it missing while the
        // user has automatic pasting off would be asking for a permission
        // nothing is going to use.
        if automaticPaste, !accessibility { issues.append(.accessibility) }
        return issues
    }
}
