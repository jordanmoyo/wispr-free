import XCTest
@testable import WisprCore

final class CorrectionStoreTests: XCTestCase {
    private var tempDir: URL!
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispr-corrections-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("corrections.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testRecordTwiceIncrementsCount() async {
        let store = CorrectionStore(fileURL: fileURL)
        await store.record(wrong: "recete", right: "receipt")
        await store.record(wrong: "recete", right: "receipt")

        let all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.count, 2)
    }

    func testRecordSameKeyDifferentRightOverwritesRight() async {
        let store = CorrectionStore(fileURL: fileURL)
        await store.record(wrong: "recete", right: "receipt")
        await store.record(wrong: "RECETE", right: "receit")  // case-insensitive key

        let all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.wrong, "recete")
        XCTAssertEqual(all.first?.right, "receit")
        XCTAssertEqual(all.first?.count, 2)
    }

    func testTopPairsSortsByCountDescending() async {
        let store = CorrectionStore(fileURL: fileURL)
        await store.record(wrong: "a", right: "aa")
        await store.record(wrong: "b", right: "bb")
        await store.record(wrong: "b", right: "bb")
        await store.record(wrong: "b", right: "bb")

        let top = await store.topPairs(limit: 10)
        XCTAssertEqual(top.map(\.wrong), ["b", "a"])
    }

    func testTopPairsFiltersMultiWordPairs() async {
        let store = CorrectionStore(fileURL: fileURL)
        await store.record(wrong: "a", right: "aa")
        await store.record(wrong: "multi word", right: "fixed")

        let top = await store.topPairs(limit: 10)
        XCTAssertEqual(top.map(\.wrong), ["a"])
    }

    func testTopPairsRespectsLimit() async {
        let store = CorrectionStore(fileURL: fileURL)
        await store.record(wrong: "a", right: "aa")
        await store.record(wrong: "b", right: "bb")

        let top = await store.topPairs(limit: 1)
        XCTAssertEqual(top.count, 1)
    }

    func testCapAt200EvictsLeastRecentlyUsedFirst() async {
        let store = CorrectionStore(fileURL: fileURL)
        for i in 0..<200 {
            await store.record(wrong: "word\(i)", right: "fix\(i)")
        }
        var all = await store.all()
        XCTAssertEqual(all.count, 200)

        await store.record(wrong: "word200", right: "fix200")

        all = await store.all()
        XCTAssertEqual(all.count, 200)
        XCTAssertFalse(all.contains { $0.wrong == "word0" })  // oldest lastUsed, evicted
        XCTAssertTrue(all.contains { $0.wrong == "word200" })
    }

    func testPersistenceRoundtrip() async {
        let store = CorrectionStore(fileURL: fileURL)
        await store.record(wrong: "recete", right: "receipt")
        await store.record(wrong: "teh", right: "the")

        let reloaded = CorrectionStore(fileURL: fileURL)
        let all = await reloaded.all()
        XCTAssertEqual(Set(all.map(\.wrong)), ["recete", "teh"])
        XCTAssertEqual(all.first { $0.wrong == "recete" }?.right, "receipt")
    }

    func testRemoveDeletesEntry() async {
        let store = CorrectionStore(fileURL: fileURL)
        await store.record(wrong: "recete", right: "receipt")
        await store.remove(wrong: "RECETE")

        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testRemoveAllEmptiesStore() async {
        let store = CorrectionStore(fileURL: fileURL)
        await store.record(wrong: "recete", right: "receipt")
        await store.record(wrong: "teh", right: "the")
        await store.removeAll()

        let all = await store.all()
        XCTAssertTrue(all.isEmpty)

        // removeAll persists, so a fresh store over the same file also sees empty.
        let reloaded = CorrectionStore(fileURL: fileURL)
        let reloadedAll = await reloaded.all()
        XCTAssertTrue(reloadedAll.isEmpty)
    }

    func testFileCreatedWithSecurePermissions() async throws {
        let store = CorrectionStore(fileURL: fileURL)
        await store.record(wrong: "recete", right: "receipt")

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func testDuplicateKeysInFileLoadWithoutCrashingAndKeepBetterEntry() async throws {
        // A hand-edited or corrupted corrections.json can contain the same
        // `wrong` key twice. Dictionary(uniqueKeysWithValues:) would trap on
        // this; loading must instead keep the higher-count entry.
        let worse = Correction(wrong: "teh", right: "the", count: 1, lastUsed: Date(timeIntervalSince1970: 1_000))
        let better = Correction(wrong: "teh", right: "the-fixed", count: 5, lastUsed: Date(timeIntervalSince1970: 2_000))
        let data = try JSONEncoder().encode([worse, better])
        try data.write(to: fileURL)

        let store = CorrectionStore(fileURL: fileURL)
        let all = await store.all()

        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.right, "the-fixed")
        XCTAssertEqual(all.first?.count, 5)
    }

    func testFileExcludedFromBackup() async throws {
        let store = CorrectionStore(fileURL: fileURL)
        await store.record(wrong: "recete", right: "receipt")

        let values = try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}
