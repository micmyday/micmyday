import Foundation
import OSLog

/// One completed dictation, as the History window shows it.
struct TranscriptEntry: Identifiable, Equatable, Codable {
    var id = UUID()
    let date: Date
    /// What the engine heard. Equal to `pasted` when nothing rewrote it.
    let spoken: String
    /// What was actually delivered.
    let pasted: String
    /// The rewrite profile's name, or nil when inserted as spoken.
    let profileName: String?
    let engineName: String
    let destinationApp: String?
    let clipboardOnly: Bool

    var wasRewritten: Bool { profileName != nil && spoken != pasted }

    /// `Cursor · AI agent prompt`, the mono sub-line in the list.
    var subtitle: String {
        let destination = destinationApp ?? "Clipboard"
        guard let profileName else { return destination }
        return "\(destination) \u{00B7} \(profileName)"
    }
}

/// The recent dictations, kept across launches.
///
/// Transcripts are the most sensitive thing this app touches, so the file is
/// written inside the sandbox container with owner-only permissions and
/// excluded from backups. It
/// holds only what History already displays, it never leaves the machine, and
/// turning off "Keep recent transcripts" deletes it rather than merely hiding
/// it.
@MainActor
final class TranscriptHistory: ObservableObject {
    /// Used when nothing has set a limit yet.
    nonisolated static let defaultLimit = 50
    static let selectableLimits = [10, 25, 50, 100, 500, 1_000, 5_000]

    @Published var limit: Int = defaultLimit {
        didSet { trim(); save() }
    }

    @Published private(set) var entries: [TranscriptEntry] = []

    /// Off means nothing is written and anything already on disk is removed.
    /// Set by the app from the matching setting.
    var isPersistenceEnabled = true {
        didSet {
            guard isPersistenceEnabled != oldValue else { return }
            isPersistenceEnabled ? save() : deleteStore()
        }
    }

    private let storeURL: URL?
    private var saveTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.micmyday.app", category: "TranscriptHistory")

    init(
        storeURL: URL? = TranscriptHistory.defaultStoreURL(),
        limit: Int = TranscriptHistory.defaultLimit,
        isPersistenceEnabled: Bool = true
    ) {
        self.storeURL = storeURL
        self.limit = limit
        self.isPersistenceEnabled = isPersistenceEnabled
        if isPersistenceEnabled { load() } else { deleteStore() }
    }

    func record(_ entry: TranscriptEntry) {
        entries.insert(entry, at: 0)
        trim()
        save()
    }

    private func trim() {
        guard entries.count > limit else { return }
        entries.removeLast(entries.count - limit)
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries.removeAll()
        deleteStore()
    }

    // MARK: - Storage

    nonisolated static func defaultStoreURL() -> URL? {
        // The test host also constructs AppState; never open the user's real
        // history there. Persistence tests supply their own temporary URL.
        guard NSClassFromString("XCTestCase") == nil else { return nil }
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let folder = base.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "com.micmyday.app", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        return folder.appendingPathComponent("history.json")
    }

    private func load() {
        guard let storeURL, let data = try? Data(contentsOf: storeURL) else { return }
        guard let stored = try? JSONDecoder().decode([TranscriptEntry].self, from: data) else {
            // A file we cannot read is a file we cannot honour a delete on
            // either, so it goes rather than lingering unreadable on disk.
            try? FileManager.default.removeItem(at: storeURL)
            return
        }
        entries = stored
        trim()
    }

    /// Writes immediately, skipping the coalescing delay. Called when the app is
    /// about to quit, so a dictation made in the last fraction of a second is
    /// not the one that gets lost.
    func flush() {
        guard isPersistenceEnabled, storeURL != nil else { return }
        saveTask?.cancel()
        write(entries)
    }

    /// Coalesced: a burst of dictations should not each rewrite the whole file.
    private func save() {
        guard isPersistenceEnabled, storeURL != nil else { return }
        saveTask?.cancel()
        let snapshot = entries
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.write(snapshot)
        }
    }

    private func write(_ snapshot: [TranscriptEntry]) {
        guard let storeURL else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            // Atomic replacement preserves the previous history if a write is
            // interrupted. The app-owned directory and file are owner-only.
            try data.write(to: storeURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
            var url = storeURL
            var resource = URLResourceValues()
            resource.isExcludedFromBackup = true
            try url.setResourceValues(resource)
        } catch {
            logger.error("Could not save local transcript history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deleteStore() {
        saveTask?.cancel()
        guard let storeURL else { return }
        try? FileManager.default.removeItem(at: storeURL)
    }

    /// Grouped for the list: Today, Yesterday, then the date.
    func grouped() -> [(title: String, entries: [TranscriptEntry])] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [TranscriptEntry]] = [:]

        for entry in entries {
            let title: String
            if calendar.isDateInToday(entry.date) {
                title = "Today"
            } else if calendar.isDateInYesterday(entry.date) {
                title = "Yesterday"
            } else {
                title = entry.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
            }
            if buckets[title] == nil {
                buckets[title] = []
                order.append(title)
            }
            buckets[title]?.append(entry)
        }

        return order.map { ($0, buckets[$0] ?? []) }
    }
}
