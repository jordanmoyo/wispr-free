import XCTest
@testable import WisprCore

/// Returns scripted strings in order, so map-reduce logic is testable
/// without a model. An actor because the generator is `Sendable`.
private actor ScriptedGenerator: MeetingTextGenerating {
    private var scripts: [String]
    private(set) var systems: [String] = []
    private(set) var users: [String] = []
    private let failAt: Int?

    init(scripts: [String], failAt: Int? = nil) {
        self.scripts = scripts
        self.failAt = failAt
    }

    func generate(system: String, user: String, maxTokens: Int) async throws -> String {
        let index = systems.count
        systems.append(system)
        users.append(user)
        if index == failAt { throw WisprError.modelNotLoaded }
        return index < scripts.count ? scripts[index] : ""
    }

    func recordedSystems() -> [String] { systems }
    func recordedUsers() -> [String] { users }
}

final class TranscriptOutputGeneratorTests: XCTestCase {
    private func segments(_ count: Int) -> [MeetingTranscriptSegment] {
        (0..<count).map {
            MeetingTranscriptSegment(speaker: .remote("1"),
                                     start: Double($0) * 10,
                                     end: Double($0) * 10 + 9,
                                     text: "Line number \($0) with enough words to matter.")
        }
    }

    // MARK: - mapNotes

    /// Named for what it checks: EVERY chunk is condensed, not just the
    /// first. The fixture is 200 segments, which really does cross
    /// `MeetingSummarizer.chunk`'s boundary — an earlier version used three
    /// segments, one chunk, and so could not tell a loop from a single call.
    func testMapNotesCondensesEveryChunk() async {
        let source = segments(200)
        XCTAssertEqual(
            MeetingSummarizer.chunk(MeetingSummarizer.render(source, names: [:])).count, 2,
            "fixture must span more than one chunk for this test to mean anything")
        let generator = ScriptedGenerator(scripts: ["- one", "- two"])
        let notes = await TranscriptOutputGenerator.mapNotes(
            segments: source, names: [:], using: generator, progress: nil)
        XCTAssertEqual(notes, ["- one", "- two"])
    }

    func testMapNotesCondensesAShortTranscriptInOneCall() async {
        let generator = ScriptedGenerator(scripts: ["- one", "- two"])
        let notes = await TranscriptOutputGenerator.mapNotes(
            segments: segments(3), names: [:], using: generator, progress: nil)
        XCTAssertEqual(notes, ["- one"])
    }

    func testMapNotesUsesTheSharedMapPrompt() async {
        let generator = ScriptedGenerator(scripts: ["- one"])
        _ = await TranscriptOutputGenerator.mapNotes(
            segments: segments(3), names: [:], using: generator, progress: nil)
        let systems = await generator.recordedSystems()
        XCTAssertEqual(systems.first, MeetingPrompt.mapSystem)
    }

    /// Enough segments to cross `MeetingSummarizer.chunk`'s 6,000-character
    /// boundary, so there really are two chunks: the first fails and the
    /// second must still be condensed. A single-chunk fixture cannot tell
    /// "skipped the chunk" apart from "aborted the whole pass" — both come
    /// back empty — which is the whole distinction this test exists for.
    func testMapNotesSkipsAFailedChunkRatherThanAborting() async {
        let source = segments(200)
        XCTAssertEqual(
            MeetingSummarizer.chunk(MeetingSummarizer.render(source, names: [:])).count, 2)
        let generator = ScriptedGenerator(scripts: ["", "- survived"], failAt: 0)
        let notes = await TranscriptOutputGenerator.mapNotes(
            segments: source, names: [:], using: generator, progress: nil)
        XCTAssertEqual(notes, ["- survived"])
    }

    func testMapNotesOfEmptySegmentsIsEmpty() async {
        let generator = ScriptedGenerator(scripts: ["- one"])
        let notes = await TranscriptOutputGenerator.mapNotes(
            segments: [], names: [:], using: generator, progress: nil)
        XCTAssertTrue(notes.isEmpty)
        let systems = await generator.recordedSystems()
        XCTAssertTrue(systems.isEmpty)   // nothing to condense costs no model call
    }

    func testMapNotesStripsThinkingBlocks() async {
        let generator = ScriptedGenerator(scripts: ["<think>plan</think>- real"])
        let notes = await TranscriptOutputGenerator.mapNotes(
            segments: segments(3), names: [:], using: generator, progress: nil)
        XCTAssertEqual(notes, ["- real"])
    }

    /// Records synchronously under a lock rather than spawning a `Task` per
    /// callback and sleeping to drain it: the callback is `@Sendable` and
    /// synchronous, so every value is already recorded by the time `mapNotes`
    /// returns. Same pattern as `MeetingSummarizerTests`, and it makes the
    /// assertion deterministic instead of dependent on a scheduler window.
    func testMapNotesReportsProgressReachingOne() async {
        let generator = ScriptedGenerator(scripts: ["- one"])
        let seen = Locked<[Double]>([])
        _ = await TranscriptOutputGenerator.mapNotes(
            segments: segments(3), names: [:], using: generator,
            progress: { value in seen.withLock { $0.append(value) } })
        let values = seen.withLock { $0 }
        XCTAssertEqual(values.last ?? 0, 1.0, accuracy: 0.001)
    }

    // MARK: - cleanTranscript

    func testCleanTranscriptReturnsTheRewrite() async {
        let source = segments(3)
        let original = MeetingSummarizer.render(source, names: [:])
        let generator = ScriptedGenerator(scripts: [original + " cleaned."])
        let cleaned = await TranscriptOutputGenerator.cleanTranscript(
            segments: source, names: [:], using: generator, progress: nil)
        XCTAssertTrue(cleaned.contains("cleaned."))
    }

    /// The guard rail. An implausible rewrite must fall back to the user's
    /// own transcript rather than ship fabricated words.
    func testCleanTranscriptFallsBackWhenTheRewriteIsImplausible() async {
        let source = segments(6)
        let original = MeetingSummarizer.render(source, names: [:])
        let generator = ScriptedGenerator(scripts: ["They talked."])
        let cleaned = await TranscriptOutputGenerator.cleanTranscript(
            segments: source, names: [:], using: generator, progress: nil)
        XCTAssertEqual(cleaned, original)
    }

    func testCleanTranscriptFallsBackWhenGenerationThrows() async {
        let source = segments(3)
        let original = MeetingSummarizer.render(source, names: [:])
        let generator = ScriptedGenerator(scripts: [""], failAt: 0)
        let cleaned = await TranscriptOutputGenerator.cleanTranscript(
            segments: source, names: [:], using: generator, progress: nil)
        XCTAssertEqual(cleaned, original)
    }

    /// Also asserts the model was never called. Emptiness alone is too weak
    /// to pin this path: an implementation that handed the empty transcript
    /// to the model would still come back empty, because the plausibility
    /// guard rejects any rewrite of an empty original and falls back to it.
    /// "Nothing to clean" must cost nothing.
    func testCleanTranscriptOfEmptySegmentsIsEmpty() async {
        let generator = ScriptedGenerator(scripts: ["anything"])
        let cleaned = await TranscriptOutputGenerator.cleanTranscript(
            segments: [], names: [:], using: generator, progress: nil)
        XCTAssertTrue(cleaned.isEmpty)
        let systems = await generator.recordedSystems()
        XCTAssertTrue(systems.isEmpty)
    }

    // MARK: - report

    func testReportReducesFromTheSharedNotes() async {
        let generator = ScriptedGenerator(scripts: ["## Overview\nIt happened."])
        let report = await TranscriptOutputGenerator.report(
            notes: ["- a point"], transcript: "You: a point", using: generator)
        XCTAssertTrue(report.contains("It happened."))
        let systems = await generator.recordedSystems()
        XCTAssertEqual(systems.first, TranscriptOutputPrompt.reportSystem)
    }

    func testReportOfNoNotesIsEmpty() async {
        let generator = ScriptedGenerator(scripts: ["## Overview\nInvented."])
        let report = await TranscriptOutputGenerator.report(
            notes: [], transcript: "", using: generator)
        XCTAssertTrue(report.isEmpty)
    }

    func testReportIsEmptyWhenGenerationThrows() async {
        let generator = ScriptedGenerator(scripts: [""], failAt: 0)
        let report = await TranscriptOutputGenerator.report(
            notes: ["- a point"], transcript: "You: a point", using: generator)
        XCTAssertTrue(report.isEmpty)
    }

    func testReportStripsThinkingBlocks() async {
        let generator = ScriptedGenerator(scripts: ["<think>hmm</think>## Overview\nReal."])
        let report = await TranscriptOutputGenerator.report(
            notes: ["- a point"], transcript: "You: a point", using: generator)
        XCTAssertFalse(report.contains("hmm"))
        XCTAssertTrue(report.contains("Real."))
    }

    // MARK: - chapters

    func testChaptersParsesValidatedModelOutput() async {
        let generator = ScriptedGenerator(scripts: [
            "- [00:00:00] Opening\n- [00:00:20] Closing"])
        let chapters = await TranscriptOutputGenerator.chapters(
            segments: segments(3), names: [:], duration: 30, using: generator)
        XCTAssertEqual(chapters.map(\.title), ["Opening", "Closing"])
    }

    func testChaptersDropsFabricatedTimestamps() async {
        let generator = ScriptedGenerator(scripts: [
            "- [00:00:00] Real\n- [05:00:00] Invented"])
        let chapters = await TranscriptOutputGenerator.chapters(
            segments: segments(3), names: [:], duration: 30, using: generator)
        XCTAssertEqual(chapters.map(\.title), ["Real"])
    }

    func testChaptersSendsTheTimestampedRender() async {
        let generator = ScriptedGenerator(scripts: ["- [00:00:00] Opening"])
        _ = await TranscriptOutputGenerator.chapters(
            segments: segments(3), names: [:], duration: 30, using: generator)
        let users = await generator.recordedUsers()
        XCTAssertTrue(users.first?.contains("[00:00:00]") == true)
    }

    func testChaptersAreEmptyWhenGenerationThrows() async {
        let generator = ScriptedGenerator(scripts: [""], failAt: 0)
        let chapters = await TranscriptOutputGenerator.chapters(
            segments: segments(3), names: [:], duration: 30, using: generator)
        XCTAssertTrue(chapters.isEmpty)
    }
}
