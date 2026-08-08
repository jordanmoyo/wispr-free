import XCTest
@testable import WisprCore

private struct StubAudio: AudioChunkProviding {
    let sampleCount: Int
    func samples(in range: Range<Int>) async throws -> [Float] {
        [Float](repeating: 0, count: range.count)
    }
}

private struct FailingAudio: AudioChunkProviding {
    let sampleCount: Int
    func samples(in range: Range<Int>) async throws -> [Float] {
        throw WisprError.audioFileUnreadable("stub")
    }
}

/// Decodes every chunk except one — a recording with a corrupt region in the
/// middle, which is the shape that produces a transcript with a hole in it.
private struct PartlyUnreadableAudio: AudioChunkProviding {
    let sampleCount: Int
    let failingChunkIndex: Int

    func samples(in range: Range<Int>) async throws -> [Float] {
        let ranges = MeetingTranscriber.chunkRanges(sampleCount: sampleCount)
        if range == ranges[failingChunkIndex] {
            throw WisprError.audioFileUnreadable("corrupt region")
        }
        return [Float](repeating: 0, count: range.count)
    }
}

private struct StubTranscriber: MeetingSegmentTranscribing {
    let text: String
    func transcribeSegments(samples: [Float], language: String?,
                            progress: (@Sendable (Double) -> Void)?) async throws
        -> [MeetingTranscriptSegment] {
        [MeetingTranscriptSegment(speaker: .others, start: 0, end: 5, text: text)]
    }
}

/// Transcribes to nothing without failing — silence, which is an honest empty
/// result rather than an error.
private struct SilentTranscriber: MeetingSegmentTranscribing {
    func transcribeSegments(samples: [Float], language: String?,
                            progress: (@Sendable (Double) -> Void)?) async throws
        -> [MeetingTranscriptSegment] {
        []
    }
}

private struct FailingTranscriber: MeetingSegmentTranscribing {
    func transcribeSegments(samples: [Float], language: String?,
                            progress: (@Sendable (Double) -> Void)?) async throws
        -> [MeetingTranscriptSegment] {
        throw WisprError.modelNotLoaded
    }
}

/// Counts how often it was asked to transcribe, so a test can assert the
/// pipeline never spent the (potentially hours-long) work at all.
private struct CountingTranscriber: MeetingSegmentTranscribing {
    let log: CallLog
    func transcribeSegments(samples: [Float], language: String?,
                            progress: (@Sendable (Double) -> Void)?) async throws
        -> [MeetingTranscriptSegment] {
        await log.record()
        return [MeetingTranscriptSegment(speaker: .others, start: 0, end: 5, text: "hello")]
    }
}

private struct StubDiarizer: MeetingDiarizing {
    let spans: [DiarizedSpan]
    func warmUp() async throws {}
    func diarize(samples: [Float],
                 progress: (@Sendable (Double) -> Void)?) async throws -> [DiarizedSpan] {
        spans
    }
}

private struct FailingDiarizer: MeetingDiarizing {
    func warmUp() async throws {}
    func diarize(samples: [Float],
                 progress: (@Sendable (Double) -> Void)?) async throws -> [DiarizedSpan] {
        throw DiarizationError.modelsUnavailable("stub")
    }
}

/// Parks inside `diarize` until the surrounding task is cancelled, so a test
/// can cancel a run at a known point rather than racing it.
private struct CancelObservingDiarizer: MeetingDiarizing {
    let entered: Signal
    func warmUp() async throws {}
    func diarize(samples: [Float],
                 progress: (@Sendable (Double) -> Void)?) async throws -> [DiarizedSpan] {
        await entered.fire()
        while !Task.isCancelled { await Task.yield() }
        return []
    }
}

final class TranscriptionPipelineTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wispr-pipeline-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func seededStore() async -> (TranscriptionJobStore, TranscriptionJob) {
        let store = TranscriptionJobStore(directoryURL: directory)
        let job = TranscriptionJob(
            title: "test", createdAt: Date(), sourcePath: "/tmp/x.m4a",
            durationSeconds: 60, transcriptionModelID: "base",
            enhancementModelID: "qwen3-4b", diarizationRequested: false)
        await store.upsert(job)
        return (store, job)
    }

    func testStoresTranscriptAndMarksComplete() async {
        let (store, job) = await seededStore()
        await TranscriptionPipeline.transcribe(
            jobID: job.id, audio: StubAudio(sampleCount: 16_000 * 60),
            diarize: false, transcriber: StubTranscriber(text: "hello"),
            diarizer: nil, store: store, progress: nil)

        let saved = await store.job(id: job.id)
        XCTAssertEqual(saved?.status, .complete)
        XCTAssertEqual(saved?.segments.first?.text, "hello")
    }

    /// A run that lost a chunk is NOT complete. Spec §11 says `.partial`, and
    /// the stakes are the whole point of the status: a two-hour recording
    /// with ten silent minutes missing from the middle, shown as **Ready**
    /// with an empty failure note, is a transcript the user has no reason to
    /// distrust — and the Summary and Report generated from it will
    /// confidently omit whatever was discussed in those ten minutes.
    func testARunThatLosesAChunkIsPartialAndSaysSo() async {
        let (store, job) = await seededStore()
        let sampleCount = Int(16_000 * 1_500.0)   // 25 minutes → 3 chunks
        XCTAssertEqual(MeetingTranscriber.chunkRanges(sampleCount: sampleCount).count, 3,
                       "fixture must lose one chunk of several, not the only one")

        await TranscriptionPipeline.transcribe(
            jobID: job.id,
            audio: PartlyUnreadableAudio(sampleCount: sampleCount,
                                         failingChunkIndex: 1),
            diarize: false, transcriber: StubTranscriber(text: "hello"),
            diarizer: nil, store: store, progress: nil)

        let saved = await store.job(id: job.id)
        XCTAssertFalse(saved?.segments.isEmpty ?? true,
                       "the chunks that DID decode must still be kept")
        XCTAssertEqual(saved?.status, .partial)
        XCTAssertTrue(saved?.failureNote.contains("1 of 3") ?? false,
                      "the note must say how much was lost: "
                        + "\(saved?.failureNote ?? "")")
    }

    func testProgressReachesOne() async {
        let (store, job) = await seededStore()
        let recorder = ProgressCollector()
        await TranscriptionPipeline.transcribe(
            jobID: job.id, audio: StubAudio(sampleCount: 16_000 * 60),
            diarize: false, transcriber: StubTranscriber(text: "hello"),
            diarizer: nil, store: store,
            progress: { value in recorder.record(value) })
        let last = recorder.values.last
        XCTAssertEqual(last?.fraction ?? 0, 1.0, accuracy: 0.001)
        // The bar must also END on the final stage: with diarization off, the
        // transcription stage's own completion already reads 1.0, so fraction
        // alone cannot tell a finished run from one that never reported done.
        XCTAssertEqual(last?.stage, .done)
    }

    func testDiarizationLabelsSegments() async {
        let (store, job) = await seededStore()
        await TranscriptionPipeline.transcribe(
            jobID: job.id, audio: StubAudio(sampleCount: 16_000 * 60),
            diarize: true, transcriber: StubTranscriber(text: "hello"),
            diarizer: StubDiarizer(spans: [DiarizedSpan(speakerID: "7", start: 0, end: 10)]),
            store: store, progress: nil)

        let saved = await store.job(id: job.id)
        XCTAssertEqual(saved?.segments.first?.speaker, .remote("7"))
    }

    /// A diarization failure must degrade, not abort: the transcript is the
    /// valuable part and it survives.
    func testDiarizationFailureStillProducesATranscript() async {
        let (store, job) = await seededStore()
        await TranscriptionPipeline.transcribe(
            jobID: job.id, audio: StubAudio(sampleCount: 16_000 * 60),
            diarize: true, transcriber: StubTranscriber(text: "hello"),
            diarizer: FailingDiarizer(), store: store, progress: nil)

        let saved = await store.job(id: job.id)
        XCTAssertEqual(saved?.segments.first?.text, "hello")
        XCTAssertEqual(saved?.segments.first?.speaker, .others)
        XCTAssertEqual(saved?.status, .partial)
    }

    func testDiarizationSkippedAboveTheGate() async {
        let store = TranscriptionJobStore(directoryURL: directory)
        let job = TranscriptionJob(
            title: "long", createdAt: Date(), sourcePath: "/tmp/x.m4a",
            durationSeconds: DiarizationGate.maxSeconds + 60,
            transcriptionModelID: "base", enhancementModelID: "qwen3-4b",
            diarizationRequested: true)
        await store.upsert(job)

        await TranscriptionPipeline.transcribe(
            jobID: job.id, audio: StubAudio(sampleCount: 16_000 * 60),
            diarize: true, transcriber: StubTranscriber(text: "hello"),
            diarizer: StubDiarizer(spans: [DiarizedSpan(speakerID: "7", start: 0, end: 10)]),
            store: store, progress: nil)

        let saved = await store.job(id: job.id)
        XCTAssertEqual(saved?.segments.first?.speaker, .others)
    }

    /// The row must always survive. Losing a two-hour transcription to a
    /// vanished row is the worst outcome this feature can produce.
    func testTotalTranscriptionFailureSavesAFailedRowRatherThanDeletingIt() async {
        let (store, job) = await seededStore()
        await TranscriptionPipeline.transcribe(
            jobID: job.id, audio: StubAudio(sampleCount: 16_000 * 60),
            diarize: false, transcriber: FailingTranscriber(),
            diarizer: nil, store: store, progress: nil)

        let saved = await store.job(id: job.id)
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.status, .failed)
        XCTAssertFalse(saved?.failureNote.isEmpty ?? true)
    }

    func testUnreadableAudioSavesAFailedRow() async {
        let (store, job) = await seededStore()
        await TranscriptionPipeline.transcribe(
            jobID: job.id, audio: FailingAudio(sampleCount: 16_000 * 60),
            diarize: false, transcriber: StubTranscriber(text: "hello"),
            diarizer: nil, store: store, progress: nil)

        let saved = await store.job(id: job.id)
        XCTAssertEqual(saved?.status, .failed)
    }

    /// Cancelling before a single chunk finishes yields no segments — the same
    /// empty result silence produces. It must still be `.partial` (the row is
    /// intact, the work simply stopped), and it must say so: reporting
    /// "no speech" for a run the user cancelled is a lie about their audio.
    func testCancelBeforeAnyChunkSavesPartialAndSaysItWasCancelled() async {
        let (store, job) = await seededStore()
        let entered = Signal()
        let run = Task {
            await TranscriptionPipeline.transcribe(
                jobID: job.id, audio: StubAudio(sampleCount: 16_000 * 60),
                diarize: true, transcriber: StubTranscriber(text: "hello"),
                diarizer: CancelObservingDiarizer(entered: entered),
                store: store, progress: nil)
        }
        await entered.wait()
        run.cancel()
        await run.value

        let saved = await store.job(id: job.id)
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.segments.count, 0)
        XCTAssertEqual(saved?.status, .partial)
        XCTAssertTrue(saved?.failureNote.contains("Cancelled") ?? false,
                      "a cancelled run must not be reported as silence")
    }

    /// The other empty case: a file that really has no speech. Same empty
    /// segments, different truth, and not a failure — the row is saved
    /// `.partial` with an honest reason.
    func testSilentAudioSavesPartialWithAnHonestReason() async {
        let (store, job) = await seededStore()
        await TranscriptionPipeline.transcribe(
            jobID: job.id, audio: StubAudio(sampleCount: 16_000 * 60),
            diarize: false, transcriber: SilentTranscriber(),
            diarizer: nil, store: store, progress: nil)

        let saved = await store.job(id: job.id)
        XCTAssertEqual(saved?.status, .partial)
        XCTAssertTrue(saved?.failureNote.contains("No speech") ?? false)
        XCTAssertFalse(saved?.failureNote.contains("Cancelled") ?? true)
    }

    func testDeletedJobIsNotResurrected() async {
        let (store, job) = await seededStore()
        let log = CallLog()
        await store.delete(id: job.id)
        await TranscriptionPipeline.transcribe(
            jobID: job.id, audio: StubAudio(sampleCount: 16_000 * 60),
            diarize: false, transcriber: CountingTranscriber(log: log),
            diarizer: nil, store: store, progress: nil)

        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
        // Not merely "no row was written": a job deleted while queued must not
        // burn hours of transcription before discovering it has nowhere to go.
        let calls = await log.count
        XCTAssertEqual(calls, 0)
    }

    // MARK: - generate

    func testGenerateCachesTheCleanTranscript() async {
        let (store, job) = await seededStore()
        await store.update(id: job.id) {
            $0.segments = [MeetingTranscriptSegment(
                speaker: .others, start: 0, end: 5,
                text: "um so the the budget is fine you know")]
        }
        let generator = ScriptedOutputGenerator(scripts: ["Speaker: So the budget is fine."])
        await TranscriptionPipeline.generate(
            kind: .cleanTranscript, jobID: job.id, store: store,
            using: generator, progress: nil)

        let saved = await store.job(id: job.id)
        XCTAssertTrue(saved?.cleanTranscript.contains("budget is fine") ?? false)
    }

    func testGenerateReusesCachedMapNotesForReport() async {
        let (store, job) = await seededStore()
        await store.update(id: job.id) {
            $0.segments = [MeetingTranscriptSegment(
                speaker: .others, start: 0, end: 5, text: "We agreed the plan.")]
            $0.mapNotes = ["- agreed the plan"]
        }
        let generator = ScriptedOutputGenerator(scripts: ["## Overview\nAgreed."])
        await TranscriptionPipeline.generate(
            kind: .report, jobID: job.id, store: store, using: generator, progress: nil)

        let calls = await generator.callCount()
        XCTAssertEqual(calls, 1, "cached notes must skip the map pass")
        let saved = await store.job(id: job.id)
        XCTAssertTrue(saved?.report.contains("Agreed.") ?? false)
    }

    /// The Summary must reduce from the SAME cached map pass the Report
    /// reduces from. Three doc comments and the spec say so, and a two-hour
    /// transcript is ~25 map calls: a Summary that re-ran them after a Report
    /// would cost minutes of on-device generation the design says was already
    /// paid for.
    ///
    /// One scripted call, one call counted: any map pass here would push the
    /// count past 1.
    func testGenerateReusesCachedMapNotesForSummary() async {
        let (store, job) = await seededStore()
        await store.update(id: job.id) {
            $0.segments = [MeetingTranscriptSegment(
                speaker: .others, start: 0, end: 5, text: "We agreed the plan.")]
            $0.mapNotes = ["- agreed the plan"]
        }
        let generator = ScriptedOutputGenerator(
            scripts: ["## Summary\nThe plan was agreed."])
        await TranscriptionPipeline.generate(
            kind: .summary, jobID: job.id, store: store,
            using: generator, progress: nil)

        let calls = await generator.callCount()
        XCTAssertEqual(calls, 1, "cached notes must skip the map pass")
        let saved = await store.job(id: job.id)
        XCTAssertEqual(saved?.summary, "The plan was agreed.")
    }

    /// And the cache must be POPULATED by whichever document runs first, or
    /// "computed once" is only true in the order Report-then-Summary.
    func testASummaryWithNoCacheYetFillsItForTheReport() async {
        let (store, job) = await seededStore()
        await store.update(id: job.id) {
            $0.segments = [MeetingTranscriptSegment(
                speaker: .others, start: 0, end: 5, text: "We agreed the plan.")]
        }
        let generator = ScriptedOutputGenerator(
            scripts: ["- agreed the plan", "## Summary\nAgreed."])
        await TranscriptionPipeline.generate(
            kind: .summary, jobID: job.id, store: store,
            using: generator, progress: nil)

        let saved = await store.job(id: job.id)
        XCTAssertEqual(saved?.mapNotes, ["- agreed the plan"])
    }

    /// The Report's action items get the same fabricated-owner strip the
    /// Summary gets. `reportSystem` forbids inventing an owner and small
    /// local models do it anyway — this project has seen it live — and a
    /// report is the document most likely to be pasted into an email unread.
    func testGeneratedReportDropsAnOwnerWhoIsNotInTheTranscript() async {
        let (store, job) = await seededStore()
        await store.update(id: job.id) {
            $0.segments = [MeetingTranscriptSegment(
                speaker: .others, start: 0, end: 5,
                text: "We should revisit pricing next quarter.")]
            $0.mapNotes = ["- revisit pricing next quarter"]
        }
        let generator = ScriptedOutputGenerator(scripts: [
            "## Overview\nPricing came up.\n\n## Action items\n"
                + "- Revisit pricing next quarter – Sarah"])
        await TranscriptionPipeline.generate(
            kind: .report, jobID: job.id, store: store,
            using: generator, progress: nil)

        let report = await store.job(id: job.id)?.report ?? ""
        XCTAssertFalse(report.contains("Sarah"),
                       "Sarah is nowhere in the transcript: \(report)")
        XCTAssertTrue(report.contains("Revisit pricing next quarter"),
                      "the task itself was real and must survive: \(report)")
    }

    /// The other half: a name the transcript DOES contain is a real
    /// attribution and must be kept, or the strip would quietly delete
    /// correct information.
    func testGeneratedReportKeepsAnOwnerTheTranscriptNames() async {
        let (store, job) = await seededStore()
        await store.update(id: job.id) {
            $0.segments = [MeetingTranscriptSegment(
                speaker: .others, start: 0, end: 5,
                text: "Jordan will revisit pricing next quarter.")]
            $0.mapNotes = ["- Jordan revisits pricing"]
        }
        let generator = ScriptedOutputGenerator(scripts: [
            "## Action items\n- Revisit pricing next quarter – Jordan"])
        await TranscriptionPipeline.generate(
            kind: .report, jobID: job.id, store: store,
            using: generator, progress: nil)

        let report = await store.job(id: job.id)?.report ?? ""
        XCTAssertTrue(report.contains("Jordan"), report)
    }

    func testGenerateOnMissingJobDoesNothing() async {
        let store = TranscriptionJobStore(directoryURL: directory)
        let generator = ScriptedOutputGenerator(scripts: ["anything"])
        await TranscriptionPipeline.generate(
            kind: .summary, jobID: UUID(), store: store, using: generator, progress: nil)
        let calls = await generator.callCount()
        XCTAssertEqual(calls, 0)
        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - A failed generation must not destroy what is already there

    /// Regenerating is normal — a bigger model, a second opinion, or just a
    /// Summary asked for after a Report. If that run fails, the document
    /// already on the row is the only copy: it took minutes of on-device
    /// generation over audio that may be two hours long. Overwriting it with
    /// the empty string the generator fails closed to would lose it silently,
    /// and the pane would show an empty document with no error.
    func testAFailedReportRegenerationKeepsThePreviousReport() async {
        let (store, job) = await seededStore()
        await store.update(id: job.id) {
            $0.segments = [MeetingTranscriptSegment(
                speaker: .others, start: 0, end: 5, text: "We agreed the plan.")]
            $0.mapNotes = ["- agreed the plan"]
            $0.report = "## Overview\nThe report the user already has."
        }

        await TranscriptionPipeline.generate(
            kind: .report, jobID: job.id, store: store,
            using: FailingGenerator(), progress: nil)

        let saved = await store.job(id: job.id)
        XCTAssertEqual(saved?.report, "## Overview\nThe report the user already has.")
    }

    func testAFailedSummaryRegenerationKeepsThePreviousSummary() async {
        let (store, job) = await seededStore()
        await store.update(id: job.id) {
            $0.segments = [MeetingTranscriptSegment(
                speaker: .others, start: 0, end: 5, text: "We agreed the plan.")]
            $0.mapNotes = ["- agreed the plan"]
            $0.summary = "The plan was agreed."
            $0.actionItems = ["Send the plan round"]
            $0.decisions = ["Go with the plan"]
        }

        await TranscriptionPipeline.generate(
            kind: .summary, jobID: job.id, store: store,
            using: FailingGenerator(), progress: nil)

        let saved = await store.job(id: job.id)
        XCTAssertEqual(saved?.summary, "The plan was agreed.")
        XCTAssertEqual(saved?.actionItems, ["Send the plan round"])
        XCTAssertEqual(saved?.decisions, ["Go with the plan"])
    }

    func testAFailedChaptersRegenerationKeepsThePreviousChapters() async {
        let (store, job) = await seededStore()
        await store.update(id: job.id) {
            $0.segments = [MeetingTranscriptSegment(
                speaker: .others, start: 0, end: 5, text: "We agreed the plan.")]
            $0.chapters = [TranscriptChapter(start: 0, title: "Introductions")]
        }

        await TranscriptionPipeline.generate(
            kind: .chapters, jobID: job.id, store: store,
            using: FailingGenerator(), progress: nil)

        let saved = await store.job(id: job.id)
        XCTAssertEqual(saved?.chapters.map(\.title), ["Introductions"])
    }

    /// The guard must not become "never write anything": a run that DOES
    /// produce a document still has to replace the old one, or regeneration
    /// would be a no-op and the user could never improve a bad first pass.
    func testASuccessfulRegenerationStillReplacesTheOldDocument() async {
        let (store, job) = await seededStore()
        await store.update(id: job.id) {
            $0.segments = [MeetingTranscriptSegment(
                speaker: .others, start: 0, end: 5, text: "We agreed the plan.")]
            $0.mapNotes = ["- agreed the plan"]
            $0.report = "## Overview\nThe stale report."
        }
        let generator = ScriptedOutputGenerator(scripts: ["## Overview\nThe better report."])

        await TranscriptionPipeline.generate(
            kind: .report, jobID: job.id, store: store,
            using: generator, progress: nil)

        let saved = await store.job(id: job.id)
        XCTAssertEqual(saved?.report, "## Overview\nThe better report.")
    }
}

/// Records synchronously under a lock rather than hopping to an actor: the
/// progress callback is non-async, so an actor would need an unstructured
/// `Task` per reading and unstructured tasks have no ordering guarantee —
/// "the last value reported" would then be whichever task happened to land
/// last, which is not what the bar shows a user.
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TranscriptionProgress] = []

    func record(_ value: TranscriptionProgress) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [TranscriptionProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private actor CallLog {
    private(set) var count = 0
    func record() { count += 1 }
}

/// A one-shot latch, so a test can wait for a run to reach a known point
/// instead of sleeping and hoping.
private actor Signal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        fired = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// A model that is loaded but cannot produce — out of memory, a corrupt
/// weight file, a run cancelled underneath it. Every generator in
/// `TranscriptOutputGenerator` catches this and falls back to an empty
/// document, which is exactly the case the pipeline must not persist.
private actor FailingGenerator: MeetingTextGenerating {
    func generate(system: String, user: String, maxTokens: Int) async throws -> String {
        throw WisprError.modelNotLoaded
    }
}

private actor ScriptedOutputGenerator: MeetingTextGenerating {
    private let scripts: [String]
    private var calls = 0
    init(scripts: [String]) { self.scripts = scripts }
    func generate(system: String, user: String, maxTokens: Int) async throws -> String {
        defer { calls += 1 }
        return calls < scripts.count ? scripts[calls] : ""
    }
    func callCount() -> Int { calls }
}
