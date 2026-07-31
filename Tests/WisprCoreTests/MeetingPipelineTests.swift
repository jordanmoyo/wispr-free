import XCTest
@testable import WisprCore

private struct StubDiarizer: MeetingDiarizing {
    let spans: [DiarizedSpan]
    let error: Error?
    init(spans: [DiarizedSpan] = [], error: Error? = nil) {
        self.spans = spans
        self.error = error
    }
    func diarize(samples: [Float],
                 progress: (@Sendable (Double) -> Void)?) async throws -> [DiarizedSpan] {
        if let error { throw error }
        return spans
    }
}

private final class CountingTranscriber: MeetingSegmentTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[MeetingTranscriptSegment]]
    private(set) var callCount = 0
    var errorOnEveryCall = false

    init(scripts: [[MeetingTranscriptSegment]]) { self.scripts = scripts }

    /// Synchronous so the lock is never held across a suspension point — an
    /// `NSLock` taken directly inside an `async func` is a hard error under
    /// this toolchain's Swift 6 mode.
    private func nextScript() -> [MeetingTranscriptSegment] {
        lock.lock()
        defer { lock.unlock() }
        let index = callCount
        callCount += 1
        return index < scripts.count ? scripts[index] : []
    }

    func transcribeSegments(samples: [Float], language: String?,
                            progress: (@Sendable (Double) -> Void)?) async throws
        -> [MeetingTranscriptSegment] {
        let script = nextScript()
        if errorOnEveryCall { throw WisprError.modelNotLoaded }
        return script
    }
}

/// One-shot async rendezvous: `wait()` suspends until `fire()` is called
/// (from anywhere), or returns immediately if `fire()` already happened.
/// Lets a test park a pipeline run mid-stage and control exactly when it
/// resumes, instead of guessing at a `Task.sleep` duration.
private actor Signal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func fire() {
        guard !fired else { return }
        fired = true
        continuation?.resume()
        continuation = nil
    }
}

/// A transcriber whose FIRST call announces its own arrival (`arrived`) and
/// then blocks (`proceed`) until the test lets it continue — giving a test a
/// deterministic window in which `MeetingPipeline.process()` is genuinely
/// suspended mid-stage, i.e. actually in flight rather than merely started.
/// Only the first call (the mic stage, in every test that uses this) gates;
/// a later call (the system stage, if the run gets that far) returns empty
/// immediately, since gating both tracks on the very same script would make
/// the merged transcript reflect two tracks' worth of the same words.
private final class GatedTranscriber: MeetingSegmentTranscribing, @unchecked Sendable {
    private let arrived: Signal
    private let proceed: Signal
    private let script: [MeetingTranscriptSegment]
    private let lock = NSLock()
    private var callCount = 0

    init(arrived: Signal, proceed: Signal, script: [MeetingTranscriptSegment]) {
        self.arrived = arrived
        self.proceed = proceed
        self.script = script
    }

    /// Synchronous so the lock is never held across a suspension point —
    /// same reason as `CountingTranscriber.nextScript()` above.
    private func isFirstCall() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasFirst = callCount == 0
        callCount += 1
        return wasFirst
    }

    func transcribeSegments(samples: [Float], language: String?,
                            progress: (@Sendable (Double) -> Void)?) async throws
        -> [MeetingTranscriptSegment] {
        guard isFirstCall() else { return [] }
        await arrived.fire()
        await proceed.wait()
        return script
    }
}

final class MeetingPipelineTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-\(UUID().uuidString)")
    }

    private func seg(_ text: String, _ start: TimeInterval) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(speaker: .others, start: start, end: start + 1, text: text)
    }

    private let summaryOutput = """
        ## Summary
        We shipped it.
        ## Action items
        - Jordan: notarise
        ## Decisions
        - Ship Friday
        """

    /// Builds a pipeline whose audio "files" are fabricated in memory, so no
    /// real AAC decoding is involved.
    private func makePipeline(
        transcriber: CountingTranscriber,
        diarizer: any MeetingDiarizing = StubDiarizer(),
        generator: any MeetingTextGenerating,
        micExists: Bool = true,
        systemExists: Bool = true
    ) async -> (MeetingPipeline, MeetingStore, UUID) {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()
        let id = UUID()
        if micExists {
            try? Data(repeating: 0, count: 8).write(to: await audioStore.micURL(for: id))
        }
        if systemExists {
            try? Data(repeating: 0, count: 8).write(to: await audioStore.systemURL(for: id))
        }
        await store.upsert(Meeting(id: id, title: "T", startedAt: Date(),
                                   durationSeconds: 10, status: .processing))
        let pipeline = MeetingPipeline(
            store: store, audioStore: audioStore, transcriber: transcriber,
            diarizer: diarizer, generator: generator,
            loadSamples: { _ in [Float](repeating: 0.1, count: 16_000 * 10) })
        return (pipeline, store, id)
    }

    func testProcessProducesMergedTranscriptAndSummary() async {
        let transcriber = CountingTranscriber(scripts: [[seg("mine", 0)], [seg("theirs", 2)]])
        let generator = FixedGeneratorForPipeline(outputs: ["- bullet", summaryOutput])
        let (pipeline, _, id) = await makePipeline(
            transcriber: transcriber, generator: generator)
        let meeting = await pipeline.process(meetingID: id, progress: nil)
        XCTAssertEqual(meeting?.segments.map(\.text), ["mine", "theirs"])
        XCTAssertEqual(meeting?.segments.first?.speaker, .you)
        XCTAssertEqual(meeting?.summary, "We shipped it.")
        XCTAssertEqual(meeting?.actionItems, ["Jordan: notarise"])
        XCTAssertEqual(meeting?.decisions, ["Ship Friday"])
        XCTAssertEqual(meeting?.status, .complete)
    }

    func testProcessPersistsResult() async {
        let transcriber = CountingTranscriber(scripts: [[seg("mine", 0)], []])
        let generator = FixedGeneratorForPipeline(outputs: ["- b", summaryOutput])
        let (pipeline, store, id) = await makePipeline(
            transcriber: transcriber, generator: generator)
        _ = await pipeline.process(meetingID: id, progress: nil)
        let saved = await store.meeting(id: id)
        XCTAssertEqual(saved?.segments.count, 1)
        XCTAssertEqual(saved?.status, .complete)
    }

    func testDiarizationAppliesSpeakerIDs() async {
        let transcriber = CountingTranscriber(scripts: [[], [seg("theirs", 0)]])
        let generator = FixedGeneratorForPipeline(outputs: ["- b", summaryOutput])
        let (pipeline, _, id) = await makePipeline(
            transcriber: transcriber,
            diarizer: StubDiarizer(spans: [DiarizedSpan(speakerID: "1", start: 0, end: 5)]),
            generator: generator)
        let meeting = await pipeline.process(meetingID: id, progress: nil)
        XCTAssertEqual(meeting?.segments.first?.speaker, .remote("1"))
    }

    func testDiarizationFailureDegradesToOthersAndPartialStatus() async {
        let transcriber = CountingTranscriber(scripts: [[], [seg("theirs", 0)]])
        let generator = FixedGeneratorForPipeline(outputs: ["- b", summaryOutput])
        let (pipeline, _, id) = await makePipeline(
            transcriber: transcriber,
            diarizer: StubDiarizer(error: DiarizationError.modelsUnavailable("no net")),
            generator: generator)
        let meeting = await pipeline.process(meetingID: id, progress: nil)
        XCTAssertEqual(meeting?.segments.first?.speaker, .others)
        XCTAssertEqual(meeting?.status, .partial)
    }

    func testMissingSystemTrackSkipsSystemStages() async {
        let transcriber = CountingTranscriber(scripts: [[seg("mine", 0)]])
        let generator = FixedGeneratorForPipeline(outputs: ["- b", summaryOutput])
        let (pipeline, _, id) = await makePipeline(
            transcriber: transcriber, generator: generator, systemExists: false)
        let meeting = await pipeline.process(meetingID: id, progress: nil)
        XCTAssertEqual(transcriber.callCount, 1)   // mic only
        XCTAssertEqual(meeting?.segments.map(\.text), ["mine"])
        XCTAssertEqual(meeting?.status, .partial)
    }

    func testMissingBothTracksFails() async {
        let transcriber = CountingTranscriber(scripts: [])
        let generator = FixedGeneratorForPipeline(outputs: [])
        let (pipeline, store, id) = await makePipeline(
            transcriber: transcriber, generator: generator,
            micExists: false, systemExists: false)
        let meeting = await pipeline.process(meetingID: id, progress: nil)
        XCTAssertEqual(meeting?.status, .failed)
        XCTAssertTrue(meeting?.segments.isEmpty ?? false)
        let stored = await store.meeting(id: id)
        XCTAssertNotNil(stored)   // still saved, not vanished
    }

    /// C2: a review found reprocessing a meeting whose audio has since been
    /// evicted (by retention, or a "both tracks failed" original recording)
    /// fell all the way through to the per-checkpoint upserts before
    /// reaching the final "no transcript" guard, so
    /// `meeting.segments = TranscriptMerger.merge(mic: [], system: [],
    /// diarization: [])` overwrote a PRIOR successful run's transcript with
    /// an empty one — "no audio to transcribe" was being treated the same
    /// as "the transcript is now empty". The pipeline must bail out before
    /// touching `segments` at all when neither track exists.
    ///
    /// Reverting the pipeline's early guard for missing tracks reproduces
    /// that: this test fails on the segments assertions.
    ///
    /// N5 (round 2): the status assertion below changed from `.failed` to
    /// the meeting's ORIGINAL status (`.complete`, unchanged). A review
    /// found `.failed` here was itself a second, smaller data-loss bug on
    /// top of the one C2 already fixed: the meeting's actual content
    /// (transcript, summary, action items, decisions) is fully intact and
    /// unchanged, so reporting `.failed` told the user a working meeting
    /// had just broken, when nothing about it had. `MeetingDetailView`
    /// renders `.failed` as a failure banner over an otherwise-complete
    /// transcript — misleading on its own, and reachable for real: Reprocess
    /// is gated on audio existing at selection time, but retention can evict
    /// a meeting's audio while its detail view stays open, so the button can
    /// still be clicked into this exact path.
    func testReprocessingWithNoAudioLeftPreservesAPriorTranscriptAndSummary() async {
        let transcriber = CountingTranscriber(scripts: [])
        let generator = FixedGeneratorForPipeline(outputs: [])
        let (pipeline, store, id) = await makePipeline(
            transcriber: transcriber, generator: generator,
            micExists: false, systemExists: false)

        // Seed the meeting with a prior successful run's data — a genuine
        // reprocess of an already-completed meeting, not a fresh recording.
        guard var meeting = await store.meeting(id: id) else {
            return XCTFail("expected the seeded meeting to exist")
        }
        meeting.segments = [seg("previously transcribed", 0)]
        meeting.summary = "A prior summary."
        meeting.actionItems = ["Do the thing"]
        meeting.decisions = ["Ship it"]
        meeting.status = .complete
        await store.upsert(meeting)

        let result = await pipeline.process(meetingID: id, progress: nil)

        XCTAssertEqual(result?.status, .complete,
            "a meeting with an intact prior transcript/summary must keep its original "
                + "status when a reprocess attempt finds no audio — nothing about its "
                + "content changed, so it must not be reported as failed")
        XCTAssertEqual(result?.segments.map(\.text), ["previously transcribed"],
            "a prior transcript must survive a reprocess attempt with no audio left")
        XCTAssertEqual(result?.summary, "A prior summary.")
        XCTAssertEqual(result?.actionItems, ["Do the thing"])
        XCTAssertEqual(result?.decisions, ["Ship it"])

        let stored = await store.meeting(id: id)
        XCTAssertEqual(stored?.segments.map(\.text), ["previously transcribed"],
            "the persisted row must also keep the prior transcript, not just the "
                + "in-memory return value")
    }

    func testTranscriptionFailureOnBothTracksFails() async {
        let transcriber = CountingTranscriber(scripts: [[], []])
        transcriber.errorOnEveryCall = true
        let generator = FixedGeneratorForPipeline(outputs: [])
        let (pipeline, _, id) = await makePipeline(
            transcriber: transcriber, generator: generator)
        let meeting = await pipeline.process(meetingID: id, progress: nil)
        XCTAssertEqual(meeting?.status, .failed)
    }

    func testEmptySummaryIsPartialNotFailed() async {
        let transcriber = CountingTranscriber(scripts: [[seg("mine", 0)], []])
        let generator = FixedGeneratorForPipeline(outputs: ["", ""])
        let (pipeline, _, id) = await makePipeline(
            transcriber: transcriber, generator: generator)
        let meeting = await pipeline.process(meetingID: id, progress: nil)
        XCTAssertEqual(meeting?.status, .partial)
        XCTAssertEqual(meeting?.segments.count, 1)
        XCTAssertTrue(meeting?.summary.isEmpty ?? false)
    }

    func testUnknownMeetingIDReturnsNil() async {
        let transcriber = CountingTranscriber(scripts: [])
        let generator = FixedGeneratorForPipeline(outputs: [])
        let (pipeline, _, _) = await makePipeline(
            transcriber: transcriber, generator: generator)
        let result = await pipeline.process(meetingID: UUID(), progress: nil)
        XCTAssertNil(result)
    }

    func testProgressIsMonotonicAcrossStagesAndEndsDone() async {
        let transcriber = CountingTranscriber(scripts: [[seg("a", 0)], [seg("b", 1)]])
        let generator = FixedGeneratorForPipeline(outputs: ["- b", summaryOutput])
        let (pipeline, _, id) = await makePipeline(
            transcriber: transcriber, generator: generator)
        let seen = Locked<[MeetingProgress]>([])
        _ = await pipeline.process(meetingID: id,
                                   progress: { p in seen.withLock { $0.append(p) } })
        let values = seen.withLock { $0 }
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(values.map(\.fraction), values.map(\.fraction).sorted())
        XCTAssertEqual(values.last?.stage, .done)
        XCTAssertEqual(values.last?.fraction ?? 0, 1.0, accuracy: 0.001)
    }

    func testCancelStopsAtStageBoundaryAndSavesPartial() async {
        let transcriber = CountingTranscriber(scripts: [[seg("a", 0)], [seg("b", 1)]])
        let generator = FixedGeneratorForPipeline(outputs: ["- b", summaryOutput])
        let (pipeline, store, id) = await makePipeline(
            transcriber: transcriber, generator: generator)
        await pipeline.cancel()
        let meeting = await pipeline.process(meetingID: id, progress: nil)
        XCTAssertEqual(meeting?.status, .partial)
        // The mic stage actually ran and produced real speech before the
        // cancellation boundary stopped the pipeline — that transcript must
        // be folded into the saved meeting, not discarded.
        XCTAssertEqual(meeting?.segments.map(\.text), ["a"])
        XCTAssertEqual(meeting?.segments.first?.speaker, .you)
        let stored = await store.meeting(id: id)
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.segments.map(\.text), ["a"])
    }

    func testCancelDoesNotPersistAcrossLaterProcessCalls() async {
        // Three scripted transcriptions: the mic call cancel() aborts after,
        // then a full mic+system pair for the second, uncancelled run.
        let transcriber = CountingTranscriber(
            scripts: [[seg("a", 0)], [seg("c", 0)], [seg("d", 1)]])
        let generator = FixedGeneratorForPipeline(outputs: ["- b", summaryOutput])
        let (pipeline, store, id) = await makePipeline(
            transcriber: transcriber, generator: generator)

        await pipeline.cancel()
        let first = await pipeline.process(meetingID: id, progress: nil)
        XCTAssertEqual(first?.status, .partial)

        // A second call on the same, long-lived pipeline instance must not
        // still be considered cancelled — one cancel() must not permanently
        // brick every future meeting processed by this instance.
        let second = await pipeline.process(meetingID: id, progress: nil)
        XCTAssertEqual(second?.status, .complete)
        XCTAssertEqual(second?.segments.map(\.text), ["c", "d"])
        let stored = await store.meeting(id: id)
        XCTAssertEqual(stored?.status, .complete)
    }

    /// Sets up a pipeline whose mic transcription genuinely suspends until
    /// the test releases it, so a second `process()` call attempted while
    /// the first is in flight is a real overlap, not just two sequential
    /// calls with no actual concurrency.
    private func makeGatedPipeline(
        script: [MeetingTranscriptSegment], outputs: [String]
    ) async -> (pipeline: MeetingPipeline, store: MeetingStore, id: UUID,
                arrived: Signal, proceed: Signal) {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()
        let id = UUID()
        try? Data(repeating: 0, count: 8).write(to: await audioStore.micURL(for: id))
        try? Data(repeating: 0, count: 8).write(to: await audioStore.systemURL(for: id))
        await store.upsert(Meeting(id: id, title: "T", startedAt: Date(),
                                   durationSeconds: 10, status: .processing))
        let arrived = Signal()
        let proceed = Signal()
        let transcriber = GatedTranscriber(arrived: arrived, proceed: proceed, script: script)
        let generator = FixedGeneratorForPipeline(outputs: outputs)
        let pipeline = MeetingPipeline(
            store: store, audioStore: audioStore, transcriber: transcriber,
            diarizer: StubDiarizer(), generator: generator,
            loadSamples: { _ in [Float](repeating: 0.1, count: 16_000 * 10) })
        return (pipeline, store, id, arrived, proceed)
    }

    func testOverlappingProcessCallIsRejectedAndDoesNotDisturbTheInFlightRun() async {
        let (pipeline, _, id, arrived, proceed) = await makeGatedPipeline(
            script: [seg("a", 0)], outputs: ["- b", summaryOutput])

        let runTask = Task { await pipeline.process(meetingID: id, progress: nil) }
        await arrived.wait()   // the first call is now genuinely suspended mid mic-stage

        // A second call while the first is in flight must be rejected
        // outright, never interleaved with it.
        let overlapping = await pipeline.process(meetingID: id, progress: nil)
        XCTAssertNil(overlapping)

        // Letting the in-flight run continue, uncancelled, must still reach
        // completion normally — the rejected call left no trace on it.
        await proceed.fire()
        let result = await runTask.value
        XCTAssertEqual(result?.status, .complete)
        XCTAssertEqual(result?.segments.map(\.text), ["a"])
    }

    func testCancelTargetsTheInFlightRunNotAnOverlappingRejectedCall() async {
        let (pipeline, _, id, arrived, proceed) = await makeGatedPipeline(
            script: [seg("a", 0)], outputs: ["- b", summaryOutput])

        let runTask = Task { await pipeline.process(meetingID: id, progress: nil) }
        await arrived.wait()   // the first call is now genuinely suspended mid mic-stage

        // An overlapping call is rejected before it ever touches `cancelled`
        // — if it were allowed to run, its own exit-path `defer` would clear
        // `cancelled` and swallow the cancel() below before the real,
        // in-flight run ever observed it.
        let overlapping = await pipeline.process(meetingID: id, progress: nil)
        XCTAssertNil(overlapping)

        await pipeline.cancel()
        await proceed.fire()

        let result = await runTask.value
        XCTAssertEqual(result?.status, .partial)
        XCTAssertEqual(result?.segments.map(\.text), ["a"])
    }

    func testEnhanceNotesWritesEnhancedNotes() async {
        let transcriber = CountingTranscriber(scripts: [[seg("mine", 0)], []])
        let enhanced = "Q3 numbers were reviewed and Marie pushed back on them."
        let generator = FixedGeneratorForPipeline(outputs: ["- b", summaryOutput, enhanced])
        let (pipeline, store, id) = await makePipeline(
            transcriber: transcriber, generator: generator)
        _ = await pipeline.process(meetingID: id, progress: nil)
        guard var meeting = await store.meeting(id: id) else {
            return XCTFail("expected meeting to have been saved by process()")
        }
        meeting.userNotes = "q3 numbers, marie pushback"
        await store.upsert(meeting)
        let result = await pipeline.enhanceNotes(meetingID: id)
        XCTAssertEqual(result?.enhancedNotes, enhanced)
        let stored = await store.meeting(id: id)
        XCTAssertEqual(stored?.enhancedNotes, enhanced)
    }

    /// A run reads the meeting row once and holds that snapshot across
    /// transcription, diarization and summarization — minutes of wall-clock,
    /// all of it with the detail pane open and editable. Writing that
    /// snapshot back whole at each checkpoint destroyed every field the user
    /// owns and had changed meanwhile: notes typed, the meeting renamed, a
    /// speaker relabelled. Silently, with no error and no undo, because the
    /// pipeline is always the last writer.
    func testUserEditsDuringProcessingSurviveTheRun() async {
        let (pipeline, store, id, arrived, proceed) = await makeGatedPipeline(
            script: [seg("a", 0)], outputs: ["- b", summaryOutput])

        let runTask = Task { await pipeline.process(meetingID: id, progress: nil) }
        await arrived.wait()   // genuinely suspended mid mic-stage

        // Exactly what `MeetingsViewModel.saveNotes`, `renameMeeting` and
        // `rename(speaker:to:in:)` do.
        await store.update(id: id) { meeting in
            meeting.userNotes = "MY IMPORTANT NOTES"
            meeting.title = "Renamed by user"
            meeting.speakerNames["1"] = "Alice"
        }

        await proceed.fire()
        let result = await runTask.value

        let saved = await store.meeting(id: id)
        XCTAssertEqual(saved?.userNotes, "MY IMPORTANT NOTES")
        XCTAssertEqual(saved?.title, "Renamed by user")
        XCTAssertEqual(saved?.speakerNames["1"], "Alice")
        // The run's own output still lands — the fix merges, it doesn't just
        // let the user's write win outright.
        XCTAssertEqual(saved?.segments.map(\.text), ["a"])
        XCTAssertEqual(saved?.summary, "We shipped it.")
        XCTAssertEqual(saved?.status, .complete)
        // And the returned meeting is the merged row, not the stale snapshot:
        // callers hand it straight to the UI.
        XCTAssertEqual(result?.userNotes, "MY IMPORTANT NOTES")
        XCTAssertEqual(result?.title, "Renamed by user")
    }

    /// The other half of the same race: a user edit landing after a
    /// checkpoint must not erase the transcript that checkpoint wrote.
    func testPipelineOutputSurvivesAUserEditThatFollowsIt() async {
        let (pipeline, store, id, arrived, proceed) = await makeGatedPipeline(
            script: [seg("a", 0)], outputs: ["- b", summaryOutput])

        let runTask = Task { await pipeline.process(meetingID: id, progress: nil) }
        await arrived.wait()
        await proceed.fire()
        _ = await runTask.value

        await store.update(id: id) { $0.userNotes = "typed afterwards" }

        let saved = await store.meeting(id: id)
        XCTAssertEqual(saved?.userNotes, "typed afterwards")
        XCTAssertEqual(saved?.segments.map(\.text), ["a"])
        XCTAssertEqual(saved?.summary, "We shipped it.")
    }

    func testEnhanceNotesWithEmptyNotesIsANoOp() async {
        let transcriber = CountingTranscriber(scripts: [[seg("mine", 0)], []])
        let generator = FixedGeneratorForPipeline(outputs: ["- b", summaryOutput])
        let (pipeline, _, id) = await makePipeline(
            transcriber: transcriber, generator: generator)
        _ = await pipeline.process(meetingID: id, progress: nil)
        let result = await pipeline.enhanceNotes(meetingID: id)
        XCTAssertEqual(result?.enhancedNotes, "")
    }
}

/// Sequential canned outputs. Named to avoid colliding with the generators in
/// the summarizer and enhancer test files, which live in the same target.
private final class FixedGeneratorForPipeline: MeetingTextGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String]
    private var index = 0

    init(outputs: [String]) { self.outputs = outputs }

    /// Synchronous so the lock is never held across a suspension point — same
    /// reason as `CountingTranscriber.nextScript()` above.
    private func nextOutput() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard index < outputs.count else { return "" }
        defer { index += 1 }
        return outputs[index]
    }

    func generate(system: String, user: String, maxTokens: Int) async throws -> String {
        nextOutput()
    }
}
