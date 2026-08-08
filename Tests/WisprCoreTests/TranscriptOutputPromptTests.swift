import XCTest
@testable import WisprCore

final class TranscriptOutputPromptTests: XCTestCase {
    private func segment(_ start: Double, _ speaker: MeetingSpeaker,
                         _ text: String) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(speaker: speaker, start: start, end: start + 1, text: text)
    }

    func testTimestampedRenderPrefixesEachLineWithATimecode() {
        let rendered = TranscriptOutputPrompt.renderTimestamped(
            [segment(0, .remote("1"), "Hello"), segment(65, .remote("2"), "Hi")],
            names: [:])
        XCTAssertEqual(rendered, """
            [00:00:00] Speaker 1: Hello
            [00:01:05] Speaker 2: Hi
            """)
    }

    func testTimestampedRenderHonoursSpeakerNames() {
        let rendered = TranscriptOutputPrompt.renderTimestamped(
            [segment(0, .remote("1"), "Hello")], names: ["1": "Amara"])
        XCTAssertTrue(rendered.contains("Amara: Hello"))
    }

    func testTimestampedRenderOfEmptySegmentsIsEmpty() {
        XCTAssertEqual(TranscriptOutputPrompt.renderTimestamped([], names: [:]), "")
    }

    // MARK: - boundedTimestamped

    /// Ten lines, not two: with only two lines, keeping "first and last" and
    /// keeping "everything" look identical, so a guard that thinned even
    /// well-under-budget input could hide behind that coincidence. Ten lines
    /// makes needless thinning visible.
    func testBoundedTimestampedPassesThroughAShortTranscriptUnchanged() {
        let segments = (0..<10).map { segment(Double($0) * 10, .remote("1"), "Line \($0)") }
        XCTAssertEqual(
            TranscriptOutputPrompt.boundedTimestamped(segments, names: [:]),
            TranscriptOutputPrompt.renderTimestamped(segments, names: [:]))
    }

    /// Two hours of one-line-per-ten-seconds segments comfortably exceeds a
    /// small budget, forcing the thinning path.
    private func longSegments(count: Int = 720) -> [MeetingTranscriptSegment] {
        (0..<count).map { segment(Double($0) * 10, .remote("1"), "Line number \($0) of the recording") }
    }

    func testBoundedTimestampedOfAnOverBudgetTranscriptFitsTheBudget() {
        let segments = longSegments()
        let result = TranscriptOutputPrompt.boundedTimestamped(segments, names: [:], budget: 2_000)
        XCTAssertLessThanOrEqual(result.count, 2_000)
    }

    /// The coverage assertion. A "fix" that just truncates to the first N
    /// characters would pass the budget check above but drop the tail of the
    /// recording entirely — this is the test that catches that.
    func testBoundedTimestampedRetainsBothTheFirstAndLastTimecode() {
        let segments = longSegments()
        let firstTimecode = TranscriptChapters.timecode(segments.first!.start)
        let lastTimecode = TranscriptChapters.timecode(segments.last!.start)
        let result = TranscriptOutputPrompt.boundedTimestamped(segments, names: [:], budget: 2_000)
        XCTAssertTrue(result.contains(firstTimecode), "missing first timecode \(firstTimecode)")
        XCTAssertTrue(result.contains(lastTimecode), "missing last timecode \(lastTimecode)")
    }

    func testBoundedTimestampedLinesStayInAscendingTimestampOrder() {
        let segments = longSegments()
        let result = TranscriptOutputPrompt.boundedTimestamped(segments, names: [:], budget: 2_000)
        let timecodes = result.split(separator: "\n").compactMap { line -> TimeInterval? in
            guard let open = line.firstIndex(of: "["), let close = line.firstIndex(of: "]") else {
                return nil
            }
            return TranscriptChapters.parseTimestamp(String(line[line.index(after: open)..<close]))
        }
        XCTAssertEqual(timecodes, timecodes.sorted())
    }

    /// Thinning cannot always reach the budget: every stride keeps line 0,
    /// so a transcript whose FIRST segment is longer than the whole budget
    /// has no stride that fits. Before the final `prefix(budget)` clamp, the
    /// function returned that oversized string anyway — a "bounded" render
    /// that silently blew its bound, which downstream is a prompt larger than
    /// the context the chapter pass budgeted for.
    ///
    /// A single long-winded opening statement is exactly how this occurs in
    /// real recordings.
    func testBoundedTimestampedFitsTheBudgetEvenWhenThinningCannot() {
        let opening = segment(0, .remote("1"), String(repeating: "a", count: 2_000))
        let rest = (1..<20).map { segment(Double($0) * 10, .remote("1"), "Line \($0)") }
        let result = TranscriptOutputPrompt.boundedTimestamped(
            [opening] + rest, names: [:], budget: 500)
        XCTAssertLessThanOrEqual(result.count, 500,
                                 "bounded render exceeded its own budget")
    }

    // MARK: - Label agreement with the job

    /// The clean transcript is shown directly below the raw transcript, which
    /// is labelled by `TranscriptionJob.displayName`. Two renderers, one
    /// screen: if they disagree, the same words carry two different speaker
    /// names in the same window. Every speaker case is checked, including an
    /// unnamed remote, because the fallback strings are where the two
    /// implementations drifted before.
    func testRenderLabelsMatchTheJobDisplayNameForEverySpeakerCase() {
        let names = ["1": "Amara"]
        let job = TranscriptionJob(
            title: "t", createdAt: Date(), sourcePath: "/tmp/a.m4a",
            durationSeconds: 60, transcriptionModelID: "base",
            enhancementModelID: "qwen3-4b", diarizationRequested: true,
            speakerNames: names)
        let speakers: [MeetingSpeaker] = [.you, .others, .remote("1"), .remote("2")]
        let rendered = TranscriptOutputPrompt.render(
            speakers.map { segment(0, $0, "text") }, names: names)
        let labels = rendered.split(separator: "\n").map {
            String($0.prefix(while: { $0 != ":" }))
        }
        XCTAssertEqual(labels, speakers.map(job.displayName(for:)))
        // The fallbacks themselves, so a future rename of BOTH sides to
        // something wrong still fails here.
        XCTAssertEqual(labels, ["You", "Speaker", "Amara", "Speaker 2"])
    }

    func testBoundedTimestampedOfEmptySegmentsIsEmpty() {
        XCTAssertEqual(TranscriptOutputPrompt.boundedTimestamped([], names: [:]), "")
    }

    // MARK: - Clean-transcript guard

    func testAcceptsAModestlyTightenedRewrite() {
        let original = String(repeating: "word ", count: 100)
        let cleaned = String(repeating: "word ", count: 90)
        XCTAssertTrue(TranscriptOutputPrompt.plausibleCleanTranscript(
            original: original, cleaned: cleaned))
    }

    func testRejectsEmptyOutput() {
        XCTAssertFalse(TranscriptOutputPrompt.plausibleCleanTranscript(
            original: "some real words here", cleaned: "   \n  "))
    }

    /// Isolates the `isEmpty` guard from the floor/ceiling ratio checks: an
    /// empty `original` means 0-length cleaned output satisfies both ratio
    /// guards (0 is within [0.5x, 1.3x] of 0), so only the explicit
    /// `isEmpty` check can catch it. Without this, a fixture pairing empty
    /// output with non-empty original passes for the wrong reason — the
    /// floor guard already rejects it regardless of the `isEmpty` check.
    func testRejectsEmptyOutputEvenWhenOriginalIsAlsoEmpty() {
        XCTAssertFalse(TranscriptOutputPrompt.plausibleCleanTranscript(
            original: "", cleaned: "   \n  "))
    }

    /// Expansion is the dangerous direction: a longer "clean transcript" means
    /// the model added words nobody said.
    func testRejectsRunawayExpansion() {
        let original = String(repeating: "word ", count: 100)
        let cleaned = String(repeating: "word ", count: 200)
        XCTAssertFalse(TranscriptOutputPrompt.plausibleCleanTranscript(
            original: original, cleaned: cleaned))
    }

    func testRejectsOutputThatSummarisedInsteadOfCleaning() {
        let original = String(repeating: "word ", count: 100)
        let cleaned = "They talked about the budget."
        XCTAssertFalse(TranscriptOutputPrompt.plausibleCleanTranscript(
            original: original, cleaned: cleaned))
    }

    func testAcceptsExpansionExactlyAtTheCeiling() {
        let original = String(repeating: "a", count: 100)
        let cleaned = String(repeating: "a", count: 130)
        XCTAssertTrue(TranscriptOutputPrompt.plausibleCleanTranscript(
            original: original, cleaned: cleaned))
    }

    // MARK: - Prompts

    func testEveryPromptDeclaresItsInputToBeDataNotInstructions() {
        for prompt in [TranscriptOutputPrompt.cleanSystem,
                       TranscriptOutputPrompt.reportSystem,
                       TranscriptOutputPrompt.chapterSystem] {
            XCTAssertTrue(prompt.lowercased().contains("not instructions"),
                          "prompt is missing its injection guard: \(prompt.prefix(40))")
        }
    }

    func testCleanPromptForbidsAddingContent() {
        XCTAssertTrue(TranscriptOutputPrompt.cleanSystem.lowercased().contains("add no"))
    }

    func testChapterPromptSpecifiesTheTimestampFormat() {
        XCTAssertTrue(TranscriptOutputPrompt.chapterSystem.contains("[HH:MM:SS]"))
    }

    func testReportPromptNamesAllFiveSections() {
        for section in ["Overview", "Topics discussed", "Decisions",
                        "Action items", "Open questions"] {
            XCTAssertTrue(TranscriptOutputPrompt.reportSystem.contains(section),
                          "report prompt is missing the \(section) section")
        }
    }
}
