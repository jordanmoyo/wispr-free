import XCTest
@testable import WisprCore

final class MeetingAudioStoreTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-audio-\(UUID().uuidString)")
    }

    /// Writes `bytes` of filler to a track file so retention has something to weigh.
    private func writeDummy(_ url: URL, bytes: Int, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        if let modified {
            try FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    func testURLsAreDistinctAndNamedByID() async {
        let store = MeetingAudioStore(directoryURL: tempDir())
        let id = UUID()
        let mic = await store.micURL(for: id)
        let system = await store.systemURL(for: id)
        XCTAssertNotEqual(mic, system)
        XCTAssertTrue(mic.lastPathComponent.contains(id.uuidString))
        XCTAssertEqual(mic.pathExtension, "m4a")
        XCTAssertEqual(system.pathExtension, "m4a")
    }

    func testExistingURLsAreNilWhenAbsent() async {
        let store = MeetingAudioStore(directoryURL: tempDir())
        let id = UUID()
        let mic = await store.existingMicURL(for: id)
        let system = await store.existingSystemURL(for: id)
        XCTAssertNil(mic)
        XCTAssertNil(system)
    }

    func testExistingURLsFoundAfterWrite() async throws {
        let dir = tempDir()
        let store = MeetingAudioStore(directoryURL: dir)
        let id = UUID()
        try writeDummy(await store.micURL(for: id), bytes: 16)
        let mic = await store.existingMicURL(for: id)
        let system = await store.existingSystemURL(for: id)
        XCTAssertNotNil(mic)
        XCTAssertNil(system)
    }

    func testDeleteRemovesBothTracks() async throws {
        let dir = tempDir()
        let store = MeetingAudioStore(directoryURL: dir)
        let id = UUID()
        try writeDummy(await store.micURL(for: id), bytes: 16)
        try writeDummy(await store.systemURL(for: id), bytes: 16)
        await store.delete(id: id)
        let mic = await store.existingMicURL(for: id)
        let system = await store.existingSystemURL(for: id)
        XCTAssertNil(mic)
        XCTAssertNil(system)
    }

    func testDeleteAllClearsDirectory() async throws {
        let dir = tempDir()
        let store = MeetingAudioStore(directoryURL: dir)
        for _ in 0..<3 {
            try writeDummy(await store.micURL(for: UUID()), bytes: 16)
        }
        await store.deleteAll()
        let total = await store.totalBytes()
        XCTAssertEqual(total, 0)
    }

    func testTotalBytesSumsTracks() async throws {
        let dir = tempDir()
        let store = MeetingAudioStore(directoryURL: dir)
        let id = UUID()
        try writeDummy(await store.micURL(for: id), bytes: 100)
        try writeDummy(await store.systemURL(for: id), bytes: 50)
        let total = await store.totalBytes()
        XCTAssertEqual(total, 150)
    }

    func testRetentionEvictsOldestUntilUnderSizeCap() async throws {
        let dir = tempDir()
        let store = MeetingAudioStore(directoryURL: dir)
        let old = UUID(), mid = UUID(), new = UUID()
        let now = Date()
        try writeDummy(await store.micURL(for: old), bytes: 100,
                       modified: now.addingTimeInterval(-3000))
        try writeDummy(await store.micURL(for: mid), bytes: 100,
                       modified: now.addingTimeInterval(-2000))
        try writeDummy(await store.micURL(for: new), bytes: 100,
                       modified: now.addingTimeInterval(-1000))
        await store.enforceRetention(maxBytes: 250, maxAgeDays: 100_000)
        let oldURL = await store.existingMicURL(for: old)
        let midURL = await store.existingMicURL(for: mid)
        let newURL = await store.existingMicURL(for: new)
        XCTAssertNil(oldURL)
        XCTAssertNotNil(midURL)
        XCTAssertNotNil(newURL)
    }

    func testRetentionEvictsPastAgeCap() async throws {
        let dir = tempDir()
        let store = MeetingAudioStore(directoryURL: dir)
        let ancient = UUID(), fresh = UUID()
        try writeDummy(await store.micURL(for: ancient), bytes: 10,
                       modified: Date().addingTimeInterval(-100 * 86_400))
        try writeDummy(await store.micURL(for: fresh), bytes: 10,
                       modified: Date())
        await store.enforceRetention(maxBytes: .max, maxAgeDays: 90)
        let ancientURL = await store.existingMicURL(for: ancient)
        let freshURL = await store.existingMicURL(for: fresh)
        XCTAssertNil(ancientURL)
        XCTAssertNotNil(freshURL)
    }

    func testRetentionAppliesBothCapsTogether() async throws {
        let dir = tempDir()
        let store = MeetingAudioStore(directoryURL: dir)
        let ancient = UUID(), big = UUID(), keep = UUID()
        try writeDummy(await store.micURL(for: ancient), bytes: 10,
                       modified: Date().addingTimeInterval(-100 * 86_400))
        try writeDummy(await store.micURL(for: big), bytes: 100,
                       modified: Date().addingTimeInterval(-2000))
        try writeDummy(await store.micURL(for: keep), bytes: 100,
                       modified: Date())
        await store.enforceRetention(maxBytes: 150, maxAgeDays: 90)
        let ancientURL = await store.existingMicURL(for: ancient)
        let bigURL = await store.existingMicURL(for: big)
        let keepURL = await store.existingMicURL(for: keep)
        XCTAssertNil(ancientURL)
        XCTAssertNil(bigURL)
        XCTAssertNotNil(keepURL)
    }

    func testRetentionKeepsEverythingUnderBothCaps() async throws {
        let dir = tempDir()
        let store = MeetingAudioStore(directoryURL: dir)
        let id = UUID()
        try writeDummy(await store.micURL(for: id), bytes: 10)
        await store.enforceRetention(maxBytes: .max, maxAgeDays: 90)
        let url = await store.existingMicURL(for: id)
        XCTAssertNotNil(url)
    }

    /// C3, at the `MeetingAudioStore` layer (defense in depth alongside
    /// `SettingsStore`'s own getter clamp, which is what normally keeps an
    /// out-of-range value from ever reaching here): a negative `maxAgeDays`
    /// pushes `cutoff` into the FUTURE, which makes every file — including
    /// one written moments ago — look "older than the cutoff" and evicts it
    /// outright. Reverting the `max(1, maxAgeDays)` clamp inside
    /// `enforceRetention` fails this test: the fresh file gets deleted
    /// instead of surviving.
    func testEnforceRetentionClampsNegativeMaxAgeDaysRatherThanEvictingFreshAudio() async throws {
        let dir = tempDir()
        let store = MeetingAudioStore(directoryURL: dir)
        let id = UUID()
        try writeDummy(await store.micURL(for: id), bytes: 10, modified: Date())
        await store.enforceRetention(maxBytes: .max, maxAgeDays: -5)
        let url = await store.existingMicURL(for: id)
        XCTAssertNotNil(url,
            "a negative maxAgeDays must be clamped to a sane floor, not pushed into the "
                + "future — a file written moments ago must survive")
    }

    /// N2/N3 (round 2): `excludingMeetingIDs` is what lets
    /// `MeetingsCoordinatorImpl.enforceRetention`/`finishStopping` protect a
    /// busy meeting's audio from a sweep WITHOUT cancelling its pipeline run
    /// — see those call sites' doc comments for why exclusion replaced the
    /// round-1 drain-based fix. `excluded`'s file is old enough and small
    /// enough that BOTH caps below would otherwise evict it; `included`'s
    /// is identical in every way except its id isn't in the exclusion set.
    ///
    /// Reverting the `excludingMeetingIDs` filter (having `enforceRetention`
    /// ignore the parameter and consider all files, as it did before this
    /// round) fails this: `excludedURL` comes back nil instead of surviving.
    func testEnforceRetentionSkipsFilesBelongingToExcludedMeetingIDs() async throws {
        let dir = tempDir()
        let store = MeetingAudioStore(directoryURL: dir)
        let excludedID = UUID(), includedID = UUID()
        let ancient = Date().addingTimeInterval(-200 * 86_400)
        try writeDummy(await store.micURL(for: excludedID), bytes: 10, modified: ancient)
        try writeDummy(await store.micURL(for: includedID), bytes: 10, modified: ancient)

        await store.enforceRetention(maxBytes: 0, maxAgeDays: 90,
                                     excludingMeetingIDs: [excludedID])

        let excludedURL = await store.existingMicURL(for: excludedID)
        let includedURL = await store.existingMicURL(for: includedID)
        XCTAssertNotNil(excludedURL,
            "a file belonging to an excluded meeting id must survive a sweep that would "
                + "otherwise evict it under both caps")
        XCTAssertNil(includedURL,
            "a file belonging to a NON-excluded meeting id must still be evicted "
                + "normally — the exclusion must be specific to the given ids, not a "
                + "global bypass")
    }

    /// D2 (round 3): a review found the original exclusion filter dropped
    /// an excluded file's bytes from `total` entirely, before the size cap
    /// was even evaluated — so a big excluded file could make the sweep
    /// UNDER-report how much space was actually in use. Concretely: a 10 GB
    /// cap, one 9 GB busy meeting, and 3 GB of idle ones would sum to
    /// "3 GB, under cap" and evict nothing, silently leaving 12 GB on disk.
    ///
    /// `busy` (900 bytes, excluded) and `idle` (300 bytes, included) under a
    /// 1000-byte cap: `idle` alone (300) is under the cap, so the OLD
    /// accounting would evict nothing at all. Counting `busy`'s bytes toward
    /// `total` (900 + 300 = 1200, over the cap) must still evict `idle` to
    /// bring the total back under 1000 — while never touching `busy` itself,
    /// since it stays excluded from the eviction loop regardless.
    func testEnforceRetentionCountsExcludedBytesTowardTheCapWithoutEvictingThem() async throws {
        let dir = tempDir()
        let store = MeetingAudioStore(directoryURL: dir)
        let busyID = UUID(), idleID = UUID()
        try writeDummy(await store.micURL(for: busyID), bytes: 900)
        try writeDummy(await store.micURL(for: idleID), bytes: 300)

        await store.enforceRetention(maxBytes: 1_000, maxAgeDays: 90,
                                     excludingMeetingIDs: [busyID])

        let busyURL = await store.existingMicURL(for: busyID)
        let idleURL = await store.existingMicURL(for: idleID)
        XCTAssertNotNil(busyURL,
            "an excluded file must never be evicted, regardless of how it affects "
                + "the running total")
        XCTAssertNil(idleURL,
            "an excluded file's bytes must still count toward the size cap — "
                + "otherwise a large excluded file makes the sweep under-report usage "
                + "and evict nothing even when the real total is well over the cap")
    }

    func testUnwritableDirectoryFailsOpen() async {
        let store = MeetingAudioStore(directoryURL: URL(fileURLWithPath: "/dev/null/nope"))
        await store.deleteAll()
        await store.enforceRetention(maxBytes: 1, maxAgeDays: 1)
        let total = await store.totalBytes()
        XCTAssertEqual(total, 0)  // no crash
    }

    func testPrepareDirectorySetsPermissionsOnFiles() async throws {
        let dir = tempDir()
        let store = MeetingAudioStore(directoryURL: dir)
        try await store.prepareDirectory()
        let id = UUID()
        let url = await store.micURL(for: id)
        try Data(repeating: 0, count: 8).write(to: url)
        await store.secure(url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
    }
}
