import XCTest
@testable import WisprCore

final class TranscriptionJobStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wispr-jobs-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeJob(title: String = "A", at date: Date = Date()) -> TranscriptionJob {
        TranscriptionJob(title: title, createdAt: date, sourcePath: "/tmp/\(title).m4a",
                         durationSeconds: 60, transcriptionModelID: "base",
                         enhancementModelID: "qwen3-4b", diarizationRequested: false)
    }

    func testUpsertThenReadBack() async {
        let store = TranscriptionJobStore(directoryURL: directory)
        let job = makeJob()
        await store.upsert(job)
        let read = await store.job(id: job.id)
        XCTAssertEqual(read, job)
    }

    func testAllReturnsNewestFirst() async {
        let store = TranscriptionJobStore(directoryURL: directory)
        let older = makeJob(title: "older", at: Date(timeIntervalSince1970: 1_000))
        let newer = makeJob(title: "newer", at: Date(timeIntervalSince1970: 2_000))
        await store.upsert(older)
        await store.upsert(newer)
        let all = await store.all()
        XCTAssertEqual(all.map(\.title), ["newer", "older"])
    }

    func testUpsertReplacesRatherThanDuplicates() async {
        let store = TranscriptionJobStore(directoryURL: directory)
        var job = makeJob()
        await store.upsert(job)
        job.title = "renamed"
        await store.upsert(job)
        let all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.title, "renamed")
    }

    func testUpdateMergesAgainstCurrentRow() async {
        let store = TranscriptionJobStore(directoryURL: directory)
        let job = makeJob()
        await store.upsert(job)
        await store.update(id: job.id) { $0.title = "renamed" }
        await store.update(id: job.id) { $0.summary = "done" }
        let read = await store.job(id: job.id)
        XCTAssertEqual(read?.title, "renamed")
        XCTAssertEqual(read?.summary, "done")
    }

    func testUpdateReturnsNilForMissingRow() async {
        let store = TranscriptionJobStore(directoryURL: directory)
        let result = await store.update(id: UUID()) { $0.title = "x" }
        XCTAssertNil(result)
    }

    func testDeleteRemovesOnlyTheNamedRow() async {
        let store = TranscriptionJobStore(directoryURL: directory)
        let keep = makeJob(title: "keep")
        let drop = makeJob(title: "drop")
        await store.upsert(keep)
        await store.upsert(drop)
        await store.delete(id: drop.id)
        let all = await store.all()
        XCTAssertEqual(all.map(\.title), ["keep"])
    }

    func testPersistsAcrossStoreInstances() async {
        let first = TranscriptionJobStore(directoryURL: directory)
        let job = makeJob()
        await first.upsert(job)
        let second = TranscriptionJobStore(directoryURL: directory)
        let all = await second.all()
        XCTAssertEqual(all.count, 1)
    }

    func testCorruptFileYieldsEmptyRatherThanCrashing() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent("transcriptions.json"))
        let store = TranscriptionJobStore(directoryURL: directory)
        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testFileIsOwnerReadWriteOnly() async throws {
        let store = TranscriptionJobStore(directoryURL: directory)
        await store.upsert(makeJob())
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("transcriptions.json").path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
    }
}
