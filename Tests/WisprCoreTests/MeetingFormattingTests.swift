import XCTest
@testable import WisprCore

final class MeetingFormattingTests: XCTestCase {
    private func meeting() -> Meeting {
        var meeting = Meeting(id: UUID(), title: "Weekly sync",
                              startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                              durationSeconds: 1_845, status: .complete)
        meeting.summary = "We reviewed the release."
        meeting.actionItems = ["Marie: changelog", "Jordan: notarise"]
        meeting.decisions = ["Ship Friday"]
        meeting.speakerNames = ["1": "Marie"]
        meeting.segments = [
            MeetingTranscriptSegment(speaker: .you, start: 7, end: 9, text: "Morning."),
            MeetingTranscriptSegment(speaker: .remote("1"), start: 12, end: 14,
                                     text: "Morning!"),
            MeetingTranscriptSegment(speaker: .remote("2"), start: 20, end: 22,
                                     text: "Hello."),
        ]
        return meeting
    }

    // MARK: timestamp

    func testTimestampUnderAnHour() {
        XCTAssertEqual(MeetingFormatting.timestamp(0), "0:00")
        XCTAssertEqual(MeetingFormatting.timestamp(7.4), "0:07")
        XCTAssertEqual(MeetingFormatting.timestamp(605), "10:05")
    }

    func testTimestampOverAnHour() {
        XCTAssertEqual(MeetingFormatting.timestamp(3753), "1:02:33")
    }

    func testTimestampNegativeIsZero() {
        XCTAssertEqual(MeetingFormatting.timestamp(-3), "0:00")
    }

    func testTimestampInfiniteIsZero() {
        // Task 13 shipped a fatal trap on Int(.infinity); a segment's start
        // or end can carry a non-finite value from upstream, so this utility
        // must be safe against it rather than crash.
        XCTAssertEqual(MeetingFormatting.timestamp(.infinity), "0:00")
        XCTAssertEqual(MeetingFormatting.timestamp(-.infinity), "0:00")
        XCTAssertEqual(MeetingFormatting.timestamp(.nan), "0:00")
    }

    // MARK: speakerIDs

    func testSpeakerIDsAreDistinctInFirstAppearanceOrder() {
        XCTAssertEqual(MeetingFormatting.speakerIDs(in: meeting()), ["1", "2"])
    }

    func testSpeakerIDsExcludeYouAndOthers() {
        var m = meeting()
        m.segments = [
            MeetingTranscriptSegment(speaker: .you, start: 0, end: 1, text: "a"),
            MeetingTranscriptSegment(speaker: .others, start: 1, end: 2, text: "b"),
        ]
        XCTAssertTrue(MeetingFormatting.speakerIDs(in: m).isEmpty)
    }

    /// The `meeting()` fixture only ever has ids "1" then "2", where
    /// appearance order and sorted order coincide — that fixture alone
    /// can't distinguish "first-appearance order" from "sorted order" or
    /// from whatever a `Set` happens to iterate in. Use ids where the two
    /// orders diverge, and repeat the first one, so both "preserves
    /// appearance order" and "de-duplicates" are actually exercised.
    func testSpeakerIDsPreserveAppearanceOrderNotSortOrder() {
        var m = meeting()
        m.segments = [
            MeetingTranscriptSegment(speaker: .remote("9"), start: 0, end: 1, text: "a"),
            MeetingTranscriptSegment(speaker: .remote("2"), start: 1, end: 2, text: "b"),
            MeetingTranscriptSegment(speaker: .remote("9"), start: 2, end: 3, text: "c"),
        ]
        XCTAssertEqual(MeetingFormatting.speakerIDs(in: m), ["9", "2"])
    }

    // MARK: hasUnsavedNotes

    func testHasUnsavedNotesFalseWhenDraftMatchesSaved() {
        XCTAssertFalse(MeetingFormatting.hasUnsavedNotes(draft: "same",
                                                          savedUserNotes: "same"))
    }

    func testHasUnsavedNotesTrueWhenDraftDiverged() {
        XCTAssertTrue(MeetingFormatting.hasUnsavedNotes(draft: "typed but not saved",
                                                         savedUserNotes: "same"))
    }

    func testHasUnsavedNotesIgnoresSurroundingWhitespace() {
        XCTAssertFalse(MeetingFormatting.hasUnsavedNotes(draft: "  same \n",
                                                          savedUserNotes: "same"))
    }

    // MARK: markdown

    func testMarkdownIncludesEverySection() {
        let text = MeetingFormatting.markdown(meeting())
        XCTAssertTrue(text.hasPrefix("# Weekly sync"))
        XCTAssertTrue(text.contains("## Summary"))
        XCTAssertTrue(text.contains("We reviewed the release."))
        XCTAssertTrue(text.contains("## Action items"))
        XCTAssertTrue(text.contains("- Marie: changelog"))
        XCTAssertTrue(text.contains("## Decisions"))
        XCTAssertTrue(text.contains("- Ship Friday"))
        XCTAssertTrue(text.contains("## Transcript"))
        XCTAssertTrue(text.contains("[0:07] You: Morning."))
        XCTAssertTrue(text.contains("[0:12] Marie: Morning!"))
        XCTAssertTrue(text.contains("[0:20] Speaker 2: Hello."))
    }

    func testMarkdownIncludesDuration() {
        XCTAssertTrue(MeetingFormatting.markdown(meeting()).contains("30:45"))
    }

    func testMarkdownOmitsEmptySections() {
        var m = meeting()
        m.actionItems = []
        m.decisions = []
        m.segments = []
        let text = MeetingFormatting.markdown(m)
        XCTAssertFalse(text.contains("## Action items"))
        XCTAssertFalse(text.contains("## Decisions"))
        XCTAssertFalse(text.contains("## Transcript"))
        XCTAssertTrue(text.contains("## Summary"))
    }

    func testMarkdownFallsBackWhenNoSummary() {
        var m = meeting()
        m.summary = ""
        XCTAssertTrue(MeetingFormatting.markdown(m).contains("No summary available."))
    }

    func testMarkdownPrefersEnhancedNotes() {
        var m = meeting()
        m.userNotes = "raw shorthand"
        m.enhancedNotes = "Tidied prose."
        let text = MeetingFormatting.markdown(m)
        XCTAssertTrue(text.contains("## Notes"))
        XCTAssertTrue(text.contains("Tidied prose."))
        XCTAssertFalse(text.contains("raw shorthand"))
    }

    func testMarkdownFallsBackToRawNotes() {
        var m = meeting()
        m.userNotes = "raw shorthand"
        m.enhancedNotes = ""
        XCTAssertTrue(MeetingFormatting.markdown(m).contains("raw shorthand"))
    }

    func testMarkdownOmitsNotesSectionWhenThereAreNone() {
        XCTAssertFalse(MeetingFormatting.markdown(meeting()).contains("## Notes"))
    }
}
