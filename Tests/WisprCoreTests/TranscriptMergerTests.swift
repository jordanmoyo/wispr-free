import XCTest
@testable import WisprCore

final class TranscriptMergerTests: XCTestCase {
    private func seg(_ text: String, _ start: TimeInterval, _ end: TimeInterval,
                     speaker: MeetingSpeaker = .others) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(speaker: speaker, start: start, end: end, text: text)
    }

    // MARK: attribute

    func testAttributePicksGreatestOverlap() {
        let spans = [DiarizedSpan(speakerID: "1", start: 0, end: 3),
                     DiarizedSpan(speakerID: "2", start: 3, end: 10)]
        // 2.5→9: overlaps span1 by 0.5, span2 by 6 → speaker 2
        XCTAssertEqual(TranscriptMerger.attribute(segment: seg("x", 2.5, 9), spans: spans),
                       .remote("2"))
    }

    func testAttributeFallsBackToOthersWithNoOverlap() {
        let spans = [DiarizedSpan(speakerID: "1", start: 0, end: 1)]
        XCTAssertEqual(TranscriptMerger.attribute(segment: seg("x", 5, 6), spans: spans),
                       .others)
    }

    func testAttributeFallsBackToOthersWithNoSpans() {
        XCTAssertEqual(TranscriptMerger.attribute(segment: seg("x", 0, 1), spans: []),
                       .others)
    }

    func testAttributeTieBreaksToEarlierSpan() {
        // Equal 1s overlap with both; earlier span wins.
        let spans = [DiarizedSpan(speakerID: "2", start: 1, end: 2),
                     DiarizedSpan(speakerID: "1", start: 0, end: 1)]
        XCTAssertEqual(TranscriptMerger.attribute(segment: seg("x", 0, 2), spans: spans),
                       .remote("1"))
    }

    func testAttributeHandlesTouchingSpansAsZeroOverlap() {
        let spans = [DiarizedSpan(speakerID: "1", start: 0, end: 5)]
        XCTAssertEqual(TranscriptMerger.attribute(segment: seg("x", 5, 6), spans: spans),
                       .others)
    }

    // MARK: merge

    func testMergeStampsMicAsYou() {
        let merged = TranscriptMerger.merge(
            mic: [seg("hello", 0, 1, speaker: .others)], system: [], diarization: [])
        XCTAssertEqual(merged.map(\.speaker), [.you])
    }

    func testMergeOrdersByStartTime() {
        let merged = TranscriptMerger.merge(
            mic: [seg("second", 5, 6)],
            system: [seg("first", 1, 2)],
            diarization: [])
        XCTAssertEqual(merged.map(\.text), ["first", "second"])
    }

    func testMergeBreaksEqualStartsMicFirst() {
        let merged = TranscriptMerger.merge(
            mic: [seg("mine", 3, 4)],
            system: [seg("theirs", 3, 5)],
            diarization: [])
        XCTAssertEqual(merged.map(\.text), ["mine", "theirs"])
    }

    func testMergeAttributesSystemSegmentsFromDiarization() {
        let merged = TranscriptMerger.merge(
            mic: [],
            system: [seg("a", 0, 2), seg("b", 4, 6)],
            diarization: [DiarizedSpan(speakerID: "1", start: 0, end: 2),
                          DiarizedSpan(speakerID: "2", start: 4, end: 6)])
        XCTAssertEqual(merged.map(\.speaker), [.remote("1"), .remote("2")])
    }

    func testMergeCoalescesSameSpeakerWithinGap() {
        let merged = TranscriptMerger.merge(
            mic: [seg("hello", 0, 1), seg("there", 1.4, 2)],
            system: [], diarization: [], coalesceGap: 1.5)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, "hello there")
        XCTAssertEqual(merged[0].start, 0)
        XCTAssertEqual(merged[0].end, 2)
    }

    func testMergeDoesNotCoalesceAcrossLongGap() {
        let merged = TranscriptMerger.merge(
            mic: [seg("hello", 0, 1), seg("there", 9, 10)],
            system: [], diarization: [], coalesceGap: 1.5)
        XCTAssertEqual(merged.count, 2)
    }

    func testMergeDoesNotCoalesceDifferentSpeakers() {
        let merged = TranscriptMerger.merge(
            mic: [seg("mine", 0, 1)],
            system: [seg("theirs", 1.1, 2)],
            diarization: [DiarizedSpan(speakerID: "1", start: 1.1, end: 2)],
            coalesceGap: 1.5)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.speaker), [.you, .remote("1")])
    }

    func testMergeCoalescesThreeInARun() {
        let merged = TranscriptMerger.merge(
            mic: [seg("a", 0, 1), seg("b", 1.2, 2), seg("c", 2.1, 3)],
            system: [], diarization: [], coalesceGap: 1.5)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, "a b c")
        XCTAssertEqual(merged[0].end, 3)
    }

    /// Whisper hands back segments with a leading space, so coalescing must trim
    /// the seam rather than concatenating the padding into a double space.
    func testMergeCoalescesPaddedSegmentsWithSingleSpace() {
        let merged = TranscriptMerger.merge(
            mic: [seg(" hello", 0, 1), seg(" there", 1.4, 2), seg(" you ", 2.1, 3)],
            system: [], diarization: [], coalesceGap: 1.5)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, "hello there you")
    }

    /// Coalescing is strictly "under the gap": a segment starting exactly one gap
    /// after the previous one ends stays separate. Pins the `<` against a `<=` regression.
    func testMergeDoesNotCoalesceAtExactlyTheGap() {
        let merged = TranscriptMerger.merge(
            mic: [seg("hello", 0, 1), seg("there", 2.5, 3)],
            system: [], diarization: [], coalesceGap: 1.5)
        XCTAssertEqual(merged.count, 2)
    }

    func testMergeDropsEmptyAndWhitespaceSegments() {
        let merged = TranscriptMerger.merge(
            mic: [seg("", 0, 1), seg("   ", 1, 2), seg("real", 2, 3)],
            system: [], diarization: [])
        XCTAssertEqual(merged.map(\.text), ["real"])
    }

    func testMergeOfNothingIsEmpty() {
        XCTAssertTrue(TranscriptMerger.merge(mic: [], system: [], diarization: []).isEmpty)
    }

    func testMergeKeepsFirstSegmentIDWhenCoalescing() {
        let first = seg("a", 0, 1)
        let merged = TranscriptMerger.merge(
            mic: [first, seg("b", 1.1, 2)], system: [], diarization: [])
        XCTAssertEqual(merged[0].id, first.id)
    }
}
