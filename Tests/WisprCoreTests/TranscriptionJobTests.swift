import XCTest
@testable import WisprCore

final class TranscriptionJobTests: XCTestCase {
    func testDefaultTitleUsesFilenameWithoutExtension() {
        XCTAssertEqual(
            TranscriptionJob.defaultTitle(sourcePath: "/Users/x/Recordings/team sync.m4a"),
            "team sync")
    }

    func testDefaultTitleFallsBackWhenPathHasNoFilename() {
        XCTAssertEqual(TranscriptionJob.defaultTitle(sourcePath: "/"), "Recording")
    }

    func testRoundTripsThroughJSON() throws {
        let job = TranscriptionJob(
            title: "Interview",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourcePath: "/tmp/a.m4a",
            durationSeconds: 3_720,
            transcriptionModelID: "large-v3-turbo",
            enhancementModelID: "qwen3-4b",
            diarizationRequested: true)

        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(TranscriptionJob.self, from: data)
        XCTAssertEqual(decoded, job)
    }

    func testChapterRoundTripsThroughJSON() throws {
        let chapter = TranscriptChapter(start: 90, title: "Budget")
        let data = try JSONEncoder().encode(chapter)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptChapter.self, from: data), chapter)
    }

    func testNewJobStartsProcessingWithNoGeneratedOutputs() {
        let job = TranscriptionJob(
            title: "x", createdAt: Date(), sourcePath: "/tmp/a.m4a",
            durationSeconds: 10, transcriptionModelID: "base",
            enhancementModelID: "qwen3-4b", diarizationRequested: false)
        XCTAssertEqual(job.status, .processing)
        XCTAssertTrue(job.segments.isEmpty)
        XCTAssertTrue(job.mapNotes.isEmpty)
        XCTAssertTrue(job.cleanTranscript.isEmpty)
        XCTAssertTrue(job.report.isEmpty)
        XCTAssertTrue(job.chapters.isEmpty)
    }
}
