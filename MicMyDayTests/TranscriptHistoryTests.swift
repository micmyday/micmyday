import XCTest
@testable import MicMyDay

final class TranscriptHistoryTests: XCTestCase {
    private func entry(_ text: String, date: Date = Date()) -> TranscriptEntry {
        TranscriptEntry(
            date: date,
            spoken: text,
            pasted: text,
            profileName: nil,
            engineName: "Test",
            destinationApp: nil,
            clipboardOnly: false
        )
    }

    @MainActor
    func testNewestEntryComesFirstAndTheListCapsAtTheLimit() {
        let history = TranscriptHistory(storeURL: nil)
        let limit = history.limit
        for index in 0 ..< (limit + 5) {
            history.record(entry("entry \(index)"))
        }
        XCTAssertEqual(history.entries.count, limit)
        XCTAssertEqual(history.entries.first?.spoken, "entry \(limit + 4)")
        XCTAssertEqual(history.entries.last?.spoken, "entry 5")
    }

    @MainActor
    func testRemoveAndClear() {
        let history = TranscriptHistory(storeURL: nil)
        history.record(entry("keep"))
        history.record(entry("drop"))
        let dropID = history.entries.first { $0.spoken == "drop" }!.id
        history.remove(dropID)
        XCTAssertEqual(history.entries.map(\.spoken), ["keep"])
        history.clear()
        XCTAssertTrue(history.entries.isEmpty)
    }

    @MainActor
    func testGroupingBucketsTodayAndYesterdayByName() {
        let history = TranscriptHistory(storeURL: nil)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        history.record(entry("old", date: yesterday))
        history.record(entry("new"))

        let groups = history.grouped()
        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday"])
        XCTAssertEqual(groups[0].entries.map(\.spoken), ["new"])
        XCTAssertEqual(groups[1].entries.map(\.spoken), ["old"])
    }

    @MainActor
    func testRewriteFlagOnlyWhenTextActuallyChanged() {
        let unchanged = TranscriptEntry(
            date: Date(), spoken: "same", pasted: "same",
            profileName: "Clean up", engineName: "Test",
            destinationApp: nil, clipboardOnly: false
        )
        XCTAssertFalse(unchanged.wasRewritten)
        let changed = TranscriptEntry(
            date: Date(), spoken: "umm same", pasted: "same",
            profileName: "Clean up", engineName: "Test",
            destinationApp: nil, clipboardOnly: false
        )
        XCTAssertTrue(changed.wasRewritten)
    }

    @MainActor
    func testLoweringTheLimitTrimsImmediately() {
        let history = TranscriptHistory(storeURL: nil)
        history.limit = 100
        for index in 0 ..< 20 { history.record(entry("entry \(index)")) }
        XCTAssertEqual(history.entries.count, 20)

        history.limit = 5
        XCTAssertEqual(history.entries.count, 5, "Shrinking the limit must drop the oldest at once")
        XCTAssertEqual(history.entries.first?.spoken, "entry 19", "Newest is kept")
    }

    @MainActor
    func testALargerLimitKeepsMore() {
        let history = TranscriptHistory(storeURL: nil)
        history.limit = 1_000
        for index in 0 ..< 300 { history.record(entry("entry \(index)")) }
        XCTAssertEqual(history.entries.count, 300)
    }

    private func temporaryStore() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = base.appendingPathComponent("HistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("history.json")
    }

    @MainActor
    func testSavedHistoryReloadsWithTheConfiguredLimitAndStableIDs() throws {
        let url = try temporaryStore()
        let history = TranscriptHistory(storeURL: url, limit: 100)
        for index in 0 ..< 80 { history.record(entry("entry \(index)")) }
        history.flush()
        let saved = try JSONDecoder().decode([TranscriptEntry].self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.count, 80)

        let restored = TranscriptHistory(storeURL: url, limit: 100)
        XCTAssertEqual(restored.entries.map(\.id), history.entries.map(\.id))
        XCTAssertEqual(restored.entries.count, 80, "Apply the selected limit before loading saved history")
        XCTAssertEqual(restored.entries.first?.spoken, "entry 79")
        XCTAssertEqual(restored.entries.last?.spoken, "entry 0")
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    @MainActor
    func testStartingWithHistoryDisabledDoesNotLoadAndDeletesTheStore() throws {
        let url = try temporaryStore()
        let history = TranscriptHistory(storeURL: url)
        history.record(entry("previous session"))
        history.flush()

        let disabled = TranscriptHistory(storeURL: url, isPersistenceEnabled: false)
        XCTAssertTrue(disabled.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        disabled.record(entry("not persisted"))
        disabled.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testClearAndDisablingPersistenceCancelPendingSaves() async throws {
        for clear in [true, false] {
            let url = try temporaryStore()
            let history = TranscriptHistory(storeURL: url)
            history.record(entry("saved"))
            history.flush()
            history.record(entry("pending"))

            if clear { history.clear() } else { history.isPersistenceEnabled = false }
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
