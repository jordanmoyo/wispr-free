import XCTest
@testable import WisprCore

/// The meetings half of the operation, which is the only part that can
/// refuse. `refuses = true` is a meeting recording or being stopped.
private final class StubMeetings: MeetingsCoordinating, @unchecked Sendable {
    let refuses: Bool
    private(set) var deleteAllCalls = 0

    init(refuses: Bool = false) { self.refuses = refuses }

    @MainActor func startMeeting() async -> Result<UUID, MeetingStartFailure> {
        .success(UUID())
    }
    @MainActor func stopMeeting() async {}
    @MainActor func reprocess(meetingID: UUID) async {}
    @MainActor func enhanceNotes(meetingID: UUID) async {}
    @MainActor func deleteMeeting(id: UUID) async {}
    @MainActor func deleteAllMeetings() async -> Bool {
        deleteAllCalls += 1
        return !refuses
    }
    @MainActor func enforceRetention(maxBytes: Int64, maxAgeDays: Int) async {}
    @MainActor func register(model: MeetingsViewModel) {}
}

/// Covers the body of Settings › Privacy › **Delete All Data… → Delete
/// Everything**, which `PrivacyPane` calls through `DeleteAllData.run`.
///
/// The guarantee under test is the one the button's own label makes: nothing
/// the app persists survives it. A store the app writes to and this function
/// does not clear is a promise the pane breaks silently — and `PRIVACY.md`
/// presents its file inventory as a complete accounting of what is on disk.
final class DeleteAllDataTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wispr-delete-all-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStores() -> (HistoryStore, CorrectionStore,
                                  AudioArchiveStore, TranscriptionJobStore) {
        (HistoryStore(fileURL: directory.appendingPathComponent("history.jsonl")),
         CorrectionStore(fileURL: directory.appendingPathComponent("corrections.json")),
         AudioArchiveStore(directoryURL: directory.appendingPathComponent("audio")),
         TranscriptionJobStore(directoryURL: directory))
    }

    private func entry() -> HistoryEntry {
        HistoryEntry(id: UUID(), date: Date(), appName: "Slack",
                     appBundleID: "com.tinyspeck.slackmacgap",
                     rawText: "hello there", cleanedText: "Hello there.",
                     durationSeconds: 2, wordCount: 2, delivered: true,
                     appliedCorrections: nil)
    }

    private func seedTranscription(_ store: TranscriptionJobStore) async {
        await store.upsert(TranscriptionJob(
            title: "confidential interview", createdAt: Date(),
            sourcePath: "/tmp/interview.m4a", durationSeconds: 7_200,
            status: .complete, transcriptionModelID: "base",
            enhancementModelID: "qwen3-4b", diarizationRequested: false,
            segments: [MeetingTranscriptSegment(speaker: .others, start: 0,
                                                end: 5, text: "off the record")],
            summary: "a summary"))
    }

    /// The transcription store holds the most sensitive content the app
    /// keeps: full transcripts of arbitrary uploaded audio, plus every
    /// summary and report generated from them. Someone clearing the machine
    /// before handing it over presses this button and is entitled to believe
    /// it.
    func testDeleteEverythingRemovesTranscriptions() async {
        let (history, corrections, archive, transcriptions) = makeStores()
        await seedTranscription(transcriptions)
        let before = await transcriptions.all()
        XCTAssertEqual(before.count, 1, "fixture must actually be there first")

        let ran = await DeleteAllData.run(
            meetings: StubMeetings(), history: history, corrections: corrections,
            archive: archive, transcriptions: transcriptions)

        XCTAssertTrue(ran)
        let after = await transcriptions.all()
        XCTAssertTrue(after.isEmpty, "\(after.count) transcription(s) survived")
    }

    func testDeleteEverythingRemovesHistoryAndCorrections() async {
        let (history, corrections, archive, transcriptions) = makeStores()
        await history.append(entry())
        await corrections.record(wrong: "wisper", right: "wispr")
        let seededHistory = await history.entries()
        let seededCorrections = await corrections.all()
        XCTAssertFalse(seededHistory.isEmpty)
        XCTAssertFalse(seededCorrections.isEmpty)

        _ = await DeleteAllData.run(
            meetings: StubMeetings(), history: history, corrections: corrections,
            archive: archive, transcriptions: transcriptions)

        let entries = await history.entries()
        let pairs = await corrections.all()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(pairs.isEmpty)
    }

    /// A refusal must leave EVERYTHING intact, not just meetings. The whole
    /// reason meetings are checked first is that a partial wipe — history
    /// gone, meetings surviving, one generic pill on screen — is worse than
    /// either outcome.
    func testARefusalFromMeetingsDeletesNothingAtAll() async {
        let (history, corrections, archive, transcriptions) = makeStores()
        await seedTranscription(transcriptions)
        await history.append(entry())

        let ran = await DeleteAllData.run(
            meetings: StubMeetings(refuses: true), history: history,
            corrections: corrections, archive: archive,
            transcriptions: transcriptions)

        XCTAssertFalse(ran)
        let survivors = await transcriptions.all()
        let entries = await history.entries()
        XCTAssertEqual(survivors.count, 1)
        XCTAssertEqual(entries.count, 1)
    }

    /// `PRIVACY.md`'s table presents itself as the complete accounting of
    /// what Wispr writes to disk. A store the app fills and the table omits
    /// is a privacy claim that is not true of the shipped code.
    func testPrivacyDocumentListsTheTranscriptionsFile() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WisprCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let text = try String(contentsOf: root.appendingPathComponent("PRIVACY.md"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("transcriptions.json"),
                      "PRIVACY.md's file inventory omits transcriptions.json")
        XCTAssertTrue(text.contains("meetings.json"),
                      "sanity: the inventory this test reads is the right one")
    }
}
