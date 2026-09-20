import AppKit

struct DataSharingRequest: Equatable {
    enum Content: String { case audio, transcript }
    let recipient: String
    let content: Content

    var identifier: String { "\(content.rawValue):\(recipient)" }

    static func provider(_ baseURL: String, content: Content) throws -> Self {
        var components = try ProviderNetworking.validatedComponents(for: baseURL)
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return Self(recipient: components.string!, content: content)
    }

    static func transcription(_ configuration: TranscriptionConfiguration) throws -> Self? {
        switch configuration.provider {
        case .whisper, .parakeet, .nemotron: return nil
        case .appleSpeech:
            return configuration.preferOnDevice ? nil : Self(recipient: "Apple Speech", content: .audio)
        case .gemini:
            return try provider(GeminiAPI.baseURL, content: .audio)
        case .openAI, .custom:
            return try provider(configuration.baseURL, content: .audio)
        }
    }
}

enum DataSharingError: LocalizedError {
    case declined
    var errorDescription: String? { "Sharing was cancelled. Nothing was sent to this provider." }
}

/// Separate from macOS recording permission: approval is specific to both the
/// configured destination and whether it receives audio or rewritten text.
@MainActor
final class DataSharingConsent {
    static let shared = DataSharingConsent()
    private static let key = "approvedDataSharingDestinations.v1"
    private let defaults: UserDefaults
    private let decision: (DataSharingRequest) -> Bool

    init(defaults: UserDefaults = .standard, decision: ((DataSharingRequest) -> Bool)? = nil) {
        self.defaults = defaults
        self.decision = decision ?? Self.showPrompt
    }

    func requirePermission(for request: DataSharingRequest) throws {
        var approved = Set(defaults.stringArray(forKey: Self.key) ?? [])
        guard !approved.contains(request.identifier) else { return }
        guard decision(request) else { throw DataSharingError.declined }
        approved.insert(request.identifier)
        defaults.set(approved.sorted(), forKey: Self.key)
    }

    func reset() { defaults.removeObject(forKey: Self.key) }

    private static func showPrompt(_ request: DataSharingRequest) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow \(request.content == .audio ? "audio" : "text") sharing with this provider?"
        let data = request.content == .audio
            ? "Your recording and any vocabulary hints will be sent for speech recognition."
            : "Your transcript and rewrite instructions will be sent for AI rewriting."
        alert.informativeText = "Destination: \(request.recipient)\n\n\(data) This can include personal information you dictate. The provider or server operator handles this data under their own privacy and retention terms.\n\nOnly allow a destination you trust. This choice is remembered for this destination and type of data. Reset it in Settings → Permissions. Local speech models do not require audio sharing."
        // Default to cancellation, so a stray Return cannot approve an upload.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Allow for This Provider")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
