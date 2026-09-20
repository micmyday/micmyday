import Foundation

/// Holds the originating window until it is safe to restore it. A visit to
/// System Settings must finish before MicMyDay brings its window forward.
struct PermissionReturnFlow<Destination> {
    private enum Stage { case prompt, systemSettings, returningFromSystemSettings }
    private var stage: Stage = .prompt
    private(set) var destination: Destination?
    private(set) var requestID: UUID?

    mutating func begin(_ destination: Destination) -> UUID {
        let id = UUID()
        self.destination = destination
        requestID = id
        stage = .prompt
        return id
    }
    mutating func openedSystemSettings() {
        guard destination != nil else { return }
        stage = .systemSettings
    }
    mutating func externalAppActivated(bundleID: String?) {
        guard bundleID == "com.apple.systempreferences", stage == .systemSettings else { return }
        stage = .returningFromSystemSettings
    }
    mutating func promptFinished(_ id: UUID?) -> Destination? {
        guard let id, id == requestID, stage == .prompt else { return nil }
        return consume()
    }
    mutating func appBecameActive() -> Destination? {
        guard stage == .returningFromSystemSettings else { return nil }
        return consume()
    }
    mutating func cancel() {
        destination = nil
        requestID = nil
        stage = .prompt
    }
    private mutating func consume() -> Destination? {
        let result = destination
        cancel()
        return result
    }
}
