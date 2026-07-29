import XCTest
@testable import WisprCore

final class HistoryStoreTests: XCTestCase {
    private var tempDir: URL!
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispr-history-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("history.jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // Millisecond-aligned: HistoryStore persists `date` at millisecond
    // precision (see HistoryStore's Codable conformance), so a fixture built
    // from `Date()` would carry sub-millisecond jitter that can never
    // survive a round-trip through the store and would make equality
    // assertions spuriously fail after a reload.
    private func makeEntry(
        id: UUID = UUID(),
        date: Date = Date(timeIntervalSince1970: 1_700_000_000.123),
        rawText: String = "raw",
        cleanedText: String = "cleaned"
    ) -> HistoryEntry {
        HistoryEntry(
            id: id,
            date: date,
            appName: "TestApp",
            appBundleID: "com.test.app",
            rawText: rawText,
            cleanedText: cleanedText,
            durationSeconds: 1.5,
            wordCount: 2,
            delivered: true,
            appliedCorrections: nil)
    }

    func testAppendThenEntriesRoundtripsNewestFirst() async {
        let store = HistoryStore(fileURL: fileURL)
        let first = makeEntry(date: Date(timeIntervalSince1970: 100))
        let second = makeEntry(date: Date(timeIntervalSince1970: 200))
        await store.append(first)
        await store.append(second)

        let entries = await store.entries()
        XCTAssertEqual(entries.map(\.id), [second.id, first.id])
    }

    func testEntriesSurviveReinitFromSameFile() async {
        let entry = makeEntry()
        let store = HistoryStore(fileURL: fileURL)
        await store.append(entry)

        let reloaded = HistoryStore(fileURL: fileURL)
        let entries = await reloaded.entries()
        XCTAssertEqual(entries, [entry])
    }

    func testBadLineIsSkipped() async throws {
        let entry = makeEntry()
        let store = HistoryStore(fileURL: fileURL)
        await store.append(entry)

        // Manually append a garbage line to the underlying file.
        let handle = try FileHandle(forWritingTo: fileURL)
        handle.seekToEndOfFile()
        handle.write(Data("not valid json\n".utf8))
        try handle.close()

        let reloaded = HistoryStore(fileURL: fileURL)
        let entries = await reloaded.entries()
        XCTAssertEqual(entries, [entry])
    }

    func testUpdateReplacesById() async {
        var entry = makeEntry(rawText: "before")
        let store = HistoryStore(fileURL: fileURL)
        await store.append(entry)

        entry.cleanedText = "after edit"
        await store.update(entry)

        let entries = await store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.cleanedText, "after edit")
    }

    func testDeleteRemovesEntry() async {
        let first = makeEntry()
        let second = makeEntry()
        let store = HistoryStore(fileURL: fileURL)
        await store.append(first)
        await store.append(second)

        await store.delete(id: first.id)

        let entries = await store.entries()
        XCTAssertEqual(entries.map(\.id), [second.id])
    }

    func testClearEmptiesFile() async {
        let store = HistoryStore(fileURL: fileURL)
        await store.append(makeEntry())
        await store.append(makeEntry())

        await store.clear()

        let entries = await store.entries()
        XCTAssertTrue(entries.isEmpty)
    }

    func testCompactionKeepsNewest1000Of1250() async {
        // Compaction is lazy: it only fires once in-memory count exceeds
        // 1200 (see HistoryStore.compactionThreshold), which happens the
        // instant the 1201st entry is appended. That single compaction
        // trims to the newest 1000; the remaining 49 appends (index 1201
        // through 1249) then grow the store again without re-triggering
        // compaction (1000 + 49 = 1049 never exceeds 1200). So for exactly
        // 1250 sequential appends the store settles at 1049 entries, not a
        // flat 1000 — this amortizes the atomic file rewrite instead of
        // paying for it on every single append past the target.
        let totalAppended = 1250
        let threshold = 1200
        let target = 1000
        let triggerAt = threshold + 1
        let expectedCount = target + (totalAppended - triggerAt)
        let oldestKeptIndex = triggerAt - target

        let store = HistoryStore(fileURL: fileURL)
        var ids: [UUID] = []
        for i in 0..<totalAppended {
            let entry = makeEntry(date: Date(timeIntervalSince1970: Double(i)))
            ids.append(entry.id)
            await store.append(entry)
        }

        let entries = await store.entries()
        XCTAssertEqual(entries.count, expectedCount)
        XCTAssertEqual(entries.first?.id, ids[totalAppended - 1])
        XCTAssertEqual(entries.last?.id, ids[oldestKeptIndex])
        XCTAssertLessThanOrEqual(entries.count, threshold)
    }

    func testFileCreatedWithSecurePermissions() async throws {
        let store = HistoryStore(fileURL: fileURL)
        await store.append(makeEntry())

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func testFileExcludedFromBackup() async throws {
        let store = HistoryStore(fileURL: fileURL)
        await store.append(makeEntry())

        let values = try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}
