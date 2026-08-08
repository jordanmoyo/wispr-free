import XCTest
@testable import WisprCore

final class TranscriptChaptersTests: XCTestCase {
    func testTimecodeFormatsHoursMinutesSeconds() {
        XCTAssertEqual(TranscriptChapters.timecode(0), "00:00:00")
        XCTAssertEqual(TranscriptChapters.timecode(75), "00:01:15")
        XCTAssertEqual(TranscriptChapters.timecode(3_725), "01:02:05")
    }

    func testParsesHoursMinutesSecondsAndMinutesSeconds() {
        XCTAssertEqual(TranscriptChapters.parseTimestamp("01:02:05"), 3_725)
        XCTAssertEqual(TranscriptChapters.parseTimestamp("02:05"), 125)
    }

    func testRejectsNonNumericTimestamps() {
        XCTAssertNil(TranscriptChapters.parseTimestamp("start"))
        XCTAssertNil(TranscriptChapters.parseTimestamp("1:2:3:4"))
        XCTAssertNil(TranscriptChapters.parseTimestamp(""))
        // Valid part count (2), but a non-numeric component — this is the
        // case that actually exercises the per-part `Int(part)` parse.
        XCTAssertNil(TranscriptChapters.parseTimestamp("ab:cd"))
    }

    /// A model that writes "05:70" has not named a real position — but the
    /// arithmetic still yields a number (370 s), and a number is accepted as
    /// a chapter start. The result is a chapter whose timestamp does not
    /// match the audio, seeking the user to the wrong place with no sign
    /// anything went wrong. Only the leading field may exceed 59: "90:00" is
    /// ninety minutes, which is a real position in a two-hour recording.
    func testRejectsOutOfRangeMinutesAndSeconds() {
        XCTAssertNil(TranscriptChapters.parseTimestamp("05:70"))
        XCTAssertNil(TranscriptChapters.parseTimestamp("01:75:00"))
        XCTAssertNil(TranscriptChapters.parseTimestamp("01:00:60"))
        XCTAssertEqual(TranscriptChapters.parseTimestamp("90:00"), 5_400)
        XCTAssertEqual(TranscriptChapters.parseTimestamp("00:59"), 59)
    }

    func testParsesWellFormedChapterList() {
        let raw = """
            - [00:00:00] Introductions
            - [00:04:30] Budget review
            - [00:12:00] Next steps
            """
        let chapters = TranscriptChapters.parse(raw, duration: 900)
        XCTAssertEqual(chapters.map(\.title),
                       ["Introductions", "Budget review", "Next steps"])
        XCTAssertEqual(chapters.map(\.start), [0, 270, 720])
    }

    func testDropsChaptersPastTheEndOfTheAudio() {
        let raw = """
            - [00:00:00] Real
            - [09:59:00] Invented
            """
        let chapters = TranscriptChapters.parse(raw, duration: 600)
        XCTAssertEqual(chapters.map(\.title), ["Real"])
    }

    func testDropsChaptersThatWalkBackwards() {
        let raw = """
            - [00:05:00] Second
            - [00:01:00] Backwards
            - [00:09:00] Third
            """
        let chapters = TranscriptChapters.parse(raw, duration: 900)
        XCTAssertEqual(chapters.map(\.title), ["Second", "Third"])
    }

    func testDropsDuplicateTimestamps() {
        let raw = """
            - [00:01:00] First
            - [00:01:00] Same time
            """
        let chapters = TranscriptChapters.parse(raw, duration: 900)
        XCTAssertEqual(chapters.map(\.title), ["First"])
    }

    func testDropsLinesWithoutATimestamp() {
        let raw = """
            Here are the chapters:
            - [00:01:00] Real
            - No timestamp here
            """
        let chapters = TranscriptChapters.parse(raw, duration: 900)
        XCTAssertEqual(chapters.map(\.title), ["Real"])
    }

    func testDropsChaptersWithEmptyTitles() {
        let chapters = TranscriptChapters.parse("- [00:01:00]   ", duration: 900)
        XCTAssertTrue(chapters.isEmpty)
    }

    func testStripsThinkingBlocksBeforeParsing() {
        let raw = """
            <think>The user wants chapters. Let me plan: [00:00:05] fake</think>
            - [00:01:00] Real
            """
        let chapters = TranscriptChapters.parse(raw, duration: 900)
        XCTAssertEqual(chapters.map(\.title), ["Real"])
    }

    func testAcceptsBulletlessAndAsteriskBullets() {
        let raw = """
            [00:00:10] Alpha
            * [00:00:20] Beta
            """
        let chapters = TranscriptChapters.parse(raw, duration: 900)
        XCTAssertEqual(chapters.map(\.title), ["Alpha", "Beta"])
    }

    func testGarbageYieldsNoChaptersRatherThanGuesses() {
        XCTAssertTrue(TranscriptChapters.parse("I cannot help with that.",
                                               duration: 900).isEmpty)
    }
}
