import XCTest
@testable import WisprCore

final class MeetingStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-store-\(UUID().uuidString)")
        return url
    }

    func testUpsertAndAllRoundTrip() async throws {
        let store = MeetingStore(directoryURL: tempDir())
        let meeting = Meeting(title: "Standup", startedAt: Date(timeIntervalSince1970: 1000))
        await store.upsert(meeting)
        let all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].title, "Standup")
    }

    func testUpsertReplacesSameID() async throws {
        let store = MeetingStore(directoryURL: tempDir())
        var meeting = Meeting(title: "Standup", startedAt: Date())
        await store.upsert(meeting)
        meeting.title = "Renamed"
        await store.upsert(meeting)
        let all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].title, "Renamed")
    }

    func testUpdateMutatesInPlaceAndReturnsTheMergedRow() async throws {
        let store = MeetingStore(directoryURL: tempDir())
        let meeting = Meeting(title: "Standup", startedAt: Date(), userNotes: "keep me")
        await store.upsert(meeting)
        let returned = await store.update(id: meeting.id) { $0.title = "Renamed" }
        XCTAssertEqual(returned?.title, "Renamed")
        XCTAssertEqual(returned?.userNotes, "keep me")
        let saved = await store.meeting(id: meeting.id)
        XCTAssertEqual(saved?.title, "Renamed")
        XCTAssertEqual(saved?.userNotes, "keep me")
    }

    /// An edit racing a delete must be dropped, not resurrect the row the
    /// user just deleted — `upsert` would have re-inserted it.
    func testUpdateOnAMissingMeetingReturnsNilAndInsertsNothing() async throws {
        let store = MeetingStore(directoryURL: tempDir())
        let returned = await store.update(id: UUID()) { $0.title = "Ghost" }
        XCTAssertNil(returned)
        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testAllReturnsNewestFirst() async throws {
        let store = MeetingStore(directoryURL: tempDir())
        await store.upsert(Meeting(title: "Older", startedAt: Date(timeIntervalSince1970: 100)))
        await store.upsert(Meeting(title: "Newer", startedAt: Date(timeIntervalSince1970: 200)))
        let all = await store.all()
        XCTAssertEqual(all.map(\.title), ["Newer", "Older"])
    }

    func testMeetingByID() async throws {
        let store = MeetingStore(directoryURL: tempDir())
        let meeting = Meeting(title: "Standup", startedAt: Date())
        await store.upsert(meeting)
        let found = await store.meeting(id: meeting.id)
        XCTAssertEqual(found?.title, "Standup")
        let none = await store.meeting(id: UUID())
        XCTAssertNil(none)
    }

    func testDelete() async throws {
        let store = MeetingStore(directoryURL: tempDir())
        let meeting = Meeting(title: "Standup", startedAt: Date())
        await store.upsert(meeting)
        await store.delete(id: meeting.id)
        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testDeleteAll() async throws {
        let store = MeetingStore(directoryURL: tempDir())
        await store.upsert(Meeting(title: "A", startedAt: Date()))
        await store.upsert(Meeting(title: "B", startedAt: Date()))
        await store.deleteAll()
        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testPersistsAcrossInstances() async throws {
        let dir = tempDir()
        let first = MeetingStore(directoryURL: dir)
        await first.upsert(Meeting(title: "Persisted", startedAt: Date()))
        let second = MeetingStore(directoryURL: dir)
        let titles = await second.all().map(\.title)
        XCTAssertEqual(titles, ["Persisted"])
    }

    func testCorruptJSONFailsOpenToEmpty() async throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("meetings.json"))
        let store = MeetingStore(directoryURL: dir)
        let allBeforeRecovery = await store.all()
        XCTAssertTrue(allBeforeRecovery.isEmpty)
        // Still writable after a corrupt read.
        await store.upsert(Meeting(title: "Recovered", startedAt: Date()))
        let allAfterRecovery = await store.all()
        XCTAssertEqual(allAfterRecovery.count, 1)
    }

    func testUnwritableDirectoryFailsOpen() async throws {
        let store = MeetingStore(directoryURL: URL(fileURLWithPath: "/dev/null/nope"))
        await store.upsert(Meeting(title: "Doomed", startedAt: Date()))
        let all = await store.all()
        XCTAssertTrue(all.isEmpty)  // no crash, no throw
    }

    /// Regression test for a data-loss bug: a transient write failure must
    /// invalidate the in-memory cache (nil) rather than empty it ([]).
    /// Emptying it would make `all()` report zero meetings even though the
    /// on-disk file still holds every previously-persisted meeting, AND
    /// make the next successful write atomically overwrite that file with
    /// just the newest meeting — permanently destroying the rest.
    func testFailedWriteInvalidatesCacheRatherThanLosingData() async throws {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let one = Meeting(title: "One", startedAt: Date(timeIntervalSince1970: 100))
        let two = Meeting(title: "Two", startedAt: Date(timeIntervalSince1970: 200))
        let three = Meeting(title: "Three", startedAt: Date(timeIntervalSince1970: 300))
        await store.upsert(one)
        await store.upsert(two)
        await store.upsert(three)
        let beforeFailure = await store.all()
        XCTAssertEqual(beforeFailure.count, 3)

        // Make the directory unwritable so the atomic write in the next
        // `upsert` fails (it needs to create a temp file alongside
        // meetings.json). Restored in `defer` regardless of outcome.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }

        await store.upsert(Meeting(title: "Four (fails)",
                                    startedAt: Date(timeIntervalSince1970: 400)))

        // The failed write must not make all() report an empty store: the
        // on-disk file is untouched, so a re-read must still find all three.
        let afterFailedWrite = await store.all()
        XCTAssertEqual(afterFailedWrite.count, 3,
                        "a failed write must not report an empty store")
        XCTAssertEqual(Set(afterFailedWrite.map(\.title)), ["One", "Two", "Three"])

        // Restore write access; a subsequent successful upsert must not
        // clobber the original three with just the newest meeting.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path)
        await store.upsert(Meeting(title: "Five", startedAt: Date(timeIntervalSince1970: 500)))
        let final = await store.all()
        XCTAssertEqual(final.count, 4)
        XCTAssertEqual(Set(final.map(\.title)), ["One", "Two", "Three", "Five"])
    }

    func testFilePermissionsAre0600() async throws {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        await store.upsert(Meeting(title: "Perms", startedAt: Date()))
        let attrs = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("meetings.json").path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
    }

    func testDisplayNameHonoursRenames() {
        var meeting = Meeting(title: "T", startedAt: Date())
        meeting.speakerNames = ["2": "Marie"]
        XCTAssertEqual(meeting.displayName(for: .you), "You")
        XCTAssertEqual(meeting.displayName(for: .others), "Others")
        XCTAssertEqual(meeting.displayName(for: .remote("2")), "Marie")
        XCTAssertEqual(meeting.displayName(for: .remote("3")), "Speaker 3")
    }

    func testDefaultTitle() {
        let date = Date(timeIntervalSince1970: 1_753_862_040)  // 30 July 2025 09:14 UTC
        // Matches "d MMMM, HH:mm": 1-2 digit day, space, month name, comma,
        // space, 2-digit hour, colon, 2-digit minute. A regex on the shape
        // (rather than rebuilding the string with the same DateFormatter,
        // which would be tautological) so a differently-formatted date
        // would fail this test even though it still starts with "Zoom — ".
        let datePattern = #"^\d{1,2} \p{L}+, \d{2}:\d{2}$"#

        let withApp = Meeting.defaultTitle(appName: "Zoom", startedAt: date)
        XCTAssertTrue(withApp.hasPrefix("Zoom — "))
        let withAppDatePart = String(withApp.dropFirst("Zoom — ".count))
        XCTAssertNotNil(withAppDatePart.range(of: datePattern, options: .regularExpression),
                         "expected date-like suffix, got \(withAppDatePart)")

        let withoutApp = Meeting.defaultTitle(appName: nil, startedAt: date)
        XCTAssertTrue(withoutApp.hasPrefix("Meeting — "))
        let withoutAppDatePart = String(withoutApp.dropFirst("Meeting — ".count))
        XCTAssertNotNil(withoutAppDatePart.range(of: datePattern, options: .regularExpression),
                         "expected date-like suffix, got \(withoutAppDatePart)")
    }
}
