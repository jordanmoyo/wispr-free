import XCTest
@testable import WisprCore

/// Covers the pure dictation/meeting mutual-exclusion decision rules
/// (`AppController.meetingStartRefusal`/`dictationBlockedMessage`),
/// `AppController.withTimeout`, and `PipelineRunRegistry`'s chaining/
/// cancellation bookkeeping. The resurrection-race fix these all support —
/// why `MeetingPipeline.cancel()` alone cannot be trusted to make a delete
/// safe — used to be tested here directly against a standalone
/// `deleteMeetingSafely` helper; that helper had zero production callers (it
/// was superseded by `MeetingsCoordinatorImpl.deleteMeeting`'s own loop) and
/// was deleted along with its tests. The equivalent invariant is now tested
/// against the real `deleteMeeting`/`stopMeeting` methods directly — see
/// `MeetingsCoordinatorImplTests`.
final class MeetingMutualExclusionTests: XCTestCase {
    // MARK: - meetingStartRefusal / dictationBlockedMessage

    func testNoRefusalWhenEverythingIsReady() {
        XCTAssertNil(AppController.meetingStartRefusal(
            dictationPhaseIdle: true, meetingActive: false,
            micGranted: true, screenCapture: .granted))
    }

    func testDictationInProgressRefusesFirst() {
        // Dictation wins over every other reason: it is the one the user can
        // fix in a second.
        XCTAssertEqual(AppController.meetingStartRefusal(
            dictationPhaseIdle: false, meetingActive: false,
            micGranted: false, screenCapture: .denied), .dictationInProgress)
    }

    func testMicDenialRefuses() {
        XCTAssertEqual(AppController.meetingStartRefusal(
            dictationPhaseIdle: true, meetingActive: false,
            micGranted: false, screenCapture: .granted), .micDenied)
    }

    func testScreenRecordingDenialRefuses() {
        XCTAssertEqual(AppController.meetingStartRefusal(
            dictationPhaseIdle: true, meetingActive: false,
            micGranted: true, screenCapture: .denied), .screenRecordingDenied)
    }

    /// A capture stack that will not answer is not a missing permission.
    /// Reporting it as one sent the user to a Settings pane where Wispr Free
    /// was already enabled — nothing to change, and the meeting still would
    /// not start.
    func testAnUnavailableCaptureStackIsNotReportedAsADeniedPermission() {
        XCTAssertEqual(AppController.meetingStartRefusal(
            dictationPhaseIdle: true, meetingActive: false,
            micGranted: true, screenCapture: .unavailable), .screenCaptureUnavailable)
    }

    /// The two messages must not send the user to the same place: only a
    /// real denial is fixed in System Settings.
    func testOnlyADeniedPermissionPointsAtSystemSettings() {
        XCTAssertTrue(MeetingStartFailure.screenRecordingDenied.userMessage
            .contains("System Settings"))
        XCTAssertFalse(MeetingStartFailure.screenCaptureUnavailable.userMessage
            .contains("System Settings"))
    }

    /// Only `SCStreamError.userDeclined` means the user withheld the
    /// permission; every other failure is the capture stack.
    func testProbeErrorsAreClassified() {
        let domain = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
        XCTAssertEqual(
            SystemAudioSource.availability(forProbeError:
                NSError(domain: domain, code: -3801)), .denied)
        XCTAssertEqual(
            SystemAudioSource.availability(forProbeError:
                NSError(domain: domain, code: -3802)), .unavailable)
        XCTAssertEqual(
            SystemAudioSource.availability(forProbeError:
                NSError(domain: NSCocoaErrorDomain, code: 4099)), .unavailable)
    }

    func testActiveMeetingIsNotARefusal() {
        // An already-running meeting is handled by returning its id, not by
        // failing — so this must be nil.
        XCTAssertNil(AppController.meetingStartRefusal(
            dictationPhaseIdle: true, meetingActive: true,
            micGranted: true, screenCapture: .granted))
    }

    func testDictationBlockedMessageMentionsMeeting() {
        let message = AppController.dictationBlockedMessage()
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(message.lowercased().contains("meeting"))
    }

    // MARK: - Shared test helpers

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("delete-race-\(UUID().uuidString)")
    }

    private func seg(_ text: String, _ start: TimeInterval) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(speaker: .others, start: start, end: start + 1, text: text)
    }

    /// Builds a pipeline whose mic transcription genuinely suspends until the
    /// test releases it, so `process()` is actually parked mid-run when the
    /// test races a delete against it — mirroring the pattern
    /// `MeetingPipelineTests.makeGatedPipeline` uses for the equivalent
    /// overlapping-call races (reimplemented here rather than imported since
    /// those helpers are private to that file).
    private func makeGatedPipeline() async -> (
        pipeline: MeetingPipeline, store: MeetingStore, audioStore: MeetingAudioStore,
        id: UUID, arrived: RaceSignal, proceed: RaceSignal
    ) {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()
        let id = UUID()
        try? Data(repeating: 0, count: 8).write(to: await audioStore.micURL(for: id))
        try? Data(repeating: 0, count: 8).write(to: await audioStore.systemURL(for: id))
        await store.upsert(Meeting(id: id, title: "T", startedAt: Date(),
                                   durationSeconds: 10, status: .processing))
        let arrived = RaceSignal()
        let proceed = RaceSignal()
        let transcriber = GatedRaceTranscriber(arrived: arrived, proceed: proceed,
                                               script: [seg("a", 0)])
        let generator = FixedRaceGenerator(outputs: ["- b", "## Summary\nDone.\n## Action items\n## Decisions"])
        let pipeline = MeetingPipeline(
            store: store, audioStore: audioStore, transcriber: transcriber,
            diarizer: RaceStubDiarizer(), generator: generator,
            loadSamples: { _ in [Float](repeating: 0.1, count: 16_000 * 10) })
        return (pipeline, store, audioStore, id, arrived, proceed)
    }

    // MARK: - PipelineRunRegistry (registration bookkeeping)
    //
    // A review found the real bug that survived round 1: with two
    // independent dictionaries (`activePipelines`/`pipelineTasks`) and no
    // coalescing, a second call for the same meeting id registered a
    // competing task under the same key, and whichever run finished first
    // wiped BOTH entries in its own `defer` — so a concurrent delete could
    // find nothing to await at all, even while the other run was still
    // writing. `PipelineRunRegistry` was extracted specifically so this
    // bookkeeping has its own test target; nothing exercised it before.

    /// The root-cause fix for the bug a SECOND review found: `begin`
    /// originally coalesced a concurrent call onto the existing run by
    /// returning its task UNCHANGED — meaning the second call's own `body`
    /// never ran AT ALL. That was fine when the second call was a duplicate
    /// of the first, but catastrophic when it wasn't: `stopMeeting` landing
    /// while an unrelated `enhanceNotes` run was in flight for the same id
    /// meant `stopMeeting`'s body — the code that actually calls
    /// `recorder.stop()` — silently never executed, leaving the recorder
    /// capturing forever. Chaining instead of coalescing means every `body`
    /// is guaranteed to run eventually — this test asserts BOTH halves:
    /// the second call must not run concurrently with the first (still only
    /// one pipeline instance touches the row at a time), AND it must
    /// eventually run once the first has finished (never silently dropped).
    @MainActor
    func testBeginChainsSecondCallToRunAfterFirstCompletes() async {
        let registry = PipelineRunRegistry()
        let id = UUID()
        let arrived = RaceSignal()
        let proceed = RaceSignal()
        let secondBodyCalls = CallCounter()

        _ = registry.begin(id: id) { _ in
            await arrived.fire()
            await proceed.wait()
        }
        await arrived.wait()   // the first run is now genuinely in flight

        let secondTask = registry.begin(id: id) { _ in await secondBodyCalls.increment() }
        // Deterministic, not a sleep-and-hope: the second run's task cannot
        // reach `body` until its own `await previous.value` resolves, and
        // `previous` (the first run) is still genuinely parked on
        // `proceed.wait()` at this point.
        let callsWhileFirstStillBlocked = await secondBodyCalls.count
        XCTAssertEqual(callsWhileFirstStillBlocked, 0,
            "the second call must not run while the first is still in "
                + "flight — two pipeline instances must never touch the same "
                + "meeting row concurrently")

        await proceed.fire()
        await secondTask.value
        let calls = await secondBodyCalls.count
        XCTAssertEqual(calls, 1,
            "the second call's body MUST eventually run, chained after the "
                + "first — this is the actual bug a review found: silently "
                + "never running it (the old coalescing behavior) could mean "
                + "stopMeeting's own recorder.stop() call never happened")
        XCTAssertNil(registry.run(for: id),
            "the registration must be cleared once the last-chained run completes")
    }

    /// Covers `PipelineRunRegistry`'s CHAINING SEMANTICS — that a run
    /// registered for an id while an earlier one is still in flight is
    /// reachable, cancellable, and awaitable through the registry's own API
    /// — which nothing else exercises at this level.
    ///
    /// What it does NOT cover, stated plainly because an earlier version of
    /// this comment claimed otherwise: it does not protect `deleteMeeting`.
    /// The `while` loop below is a hand-copied replica inlined in this test
    /// body; `coordinator.deleteMeeting` is never called, and the replica is
    /// instrumented with a `deleteLoopSawFirstRun` signal that has no analog
    /// in the real, uninstrumented method. Weakening the production loop
    /// cannot fail this test. The production loop's own regression coverage
    /// is `MeetingsCoordinatorImplTests
    /// .testDeleteMeetingWhileLoopStillCancelsAndAwaitsARunReRegisteredWhileAwaitingThePreviousOne`,
    /// which drives `deleteMeeting` itself.
    ///
    /// The instrumentation below is nonetheless worth keeping as written,
    /// because getting the registry-level assertion to distinguish a loop
    /// from a single pass AT ALL took three attempts, and the two failures
    /// are instructive about this whole family of tests:
    ///
    /// 1. Checking only "did the second run eventually happen" passes even
    ///    with a single-pass `if`: a run that is chained (rather than
    ///    dropped — see `begin`'s doc comment) completes on its own the
    ///    moment the run ahead of it finishes, entirely independent of
    ///    whether `deleteMeeting`'s loop happens to be the one awaiting it.
    /// 2. Registering the second run right after creating `deleteTask` (with
    ///    no synchronization) is ALSO indistinguishable: `begin()` replaces
    ///    the registry entry synchronously, and `deleteTask`'s `Task` body
    ///    does not get scheduled until this test body's own next suspension
    ///    point — so the loop's very FIRST check already observes the
    ///    SECOND registration, whether written as `if` or `while`. The
    ///    `deleteLoopSawFirstRun` signal below closes that: the test does
    ///    not register the second run until the loop has actually captured
    ///    the first one.
    ///
    /// With both of those closed, the distinguishing check itself avoids
    /// racing two independently-scheduled tasks' log writes against each
    /// other (which is what attempt 2 also tried and found non-deterministic
    /// order-of-actor-hops when both wake on the same event) — instead it
    /// asks a one-directional question via `withTimeout`: has `deleteTask`
    /// already finished, with nothing further from this test? A correct
    /// loop cannot have (it is genuinely parked on the re-registered run's
    /// own completion); a single-pass `if` already has, needing neither the
    /// second run's signal nor anything else.
    @MainActor
    func testCancelLoopDrainsARunReRegisteredWhileAwaitingThePreviousOne() async {
        let registry = PipelineRunRegistry()
        let id = UUID()
        let firstRunning = RaceSignal()
        let letFirstFinish = RaceSignal()
        let letSecondFinish = RaceSignal()
        let deleteLoopSawFirstRun = RaceSignal()
        let log = OrderLog()

        let firstTask = registry.begin(id: id) { _ in
            await firstRunning.fire()
            await letFirstFinish.wait()
        }
        await firstRunning.wait()
        guard let firstToken = registry.run(for: id)?.token else {
            return XCTFail("expected a registration after the first begin()")
        }

        let deleteTask = Task {
            while let run = registry.run(for: id) {
                if run.token == firstToken {
                    await deleteLoopSawFirstRun.fire()
                }
                await registry.requestCancel(id: id, token: run.token)
                await run.task.value
                registry.clear(id: id, token: run.token)
            }
            await log.record("loopFinished")
        }

        // Only now — once the loop has genuinely captured the first
        // registration — is it safe to register the second one without
        // racing ahead of `deleteTask`'s own scheduling (see note 2 above).
        await deleteLoopSawFirstRun.wait()

        // Registered for the same id while `deleteTask` is still awaiting
        // the first run — the exact race the loop exists to close.
        _ = registry.begin(id: id) { _ in
            await letSecondFinish.wait()
            await log.record("secondRan")
        }

        await letFirstFinish.fire()
        await firstTask.value

        // The distinguishing check (see doc comment above for why this
        // shape, not a log-event race): a correct loop re-read the registry
        // after the first run cleared and is now parked on the re-registered
        // run's own `task.value`, which cannot resolve without
        // `letSecondFinish` — so `deleteTask` must still be unresolved. A
        // single-pass `if` already finished right after the first run alone.
        let outcome = await AppController.withTimeout(seconds: 0.1) { await deleteTask.value }
        switch outcome {
        case .completed:
            XCTFail("the delete loop finished without waiting for the run "
                + "that was re-registered while it was still awaiting the "
                + "first one — this is the exact regression a single-pass "
                + "`if` reintroduces")
        case .timedOut:
            break
        }

        await letSecondFinish.fire()
        await deleteTask.value

        let events = await log.events
        XCTAssertEqual(events, ["secondRan", "loopFinished"],
            "the delete loop must not finish — letting a delete proceed to "
                + "remove the row — until a run registered mid-await has "
                + "actually completed; \"loopFinished\" landing first would "
                + "mean the delete raced ahead of still-in-flight work")
        XCTAssertNil(registry.run(for: id))
    }

    /// The fix for the last piece of the same bug: `attachPipeline` runs
    /// only after an async diarizer warm-up, so there is a real window in
    /// which `deleteMeeting` can request cancellation before any
    /// `MeetingPipeline` instance exists to cancel. Without `attachPipeline`
    /// checking `cancelRequested` itself, a pipeline attaching in that
    /// window would run to completion completely uncancelled, even though a
    /// cancellation was already requested for its run.
    @MainActor
    func testAttachPipelineCancelsImmediatelyIfCancelWasAlreadyRequested() async {
        let registry = PipelineRunRegistry()
        let (pipeline, _, _, id, arrived, proceed) = await makeGatedPipeline()
        let placeholderRunning = RaceSignal()

        // The run's own registered body is irrelevant to what's under test
        // here — only the token it's registered under matters.
        _ = registry.begin(id: id) { _ in await placeholderRunning.wait() }
        guard let token = registry.run(for: id)?.token else {
            return XCTFail("expected a registration after begin()")
        }

        // Cancellation requested BEFORE any pipeline is attached.
        await registry.requestCancel(id: id, token: token)
        // Attaching now, after the request, must cancel `pipeline` immediately.
        await registry.attachPipeline(id: id, token: token, pipeline: pipeline)

        let runTask = Task<Meeting?, Never> {
            await pipeline.process(meetingID: id, progress: nil)
        }
        await arrived.wait()
        await proceed.fire()
        let result = await runTask.value
        XCTAssertEqual(result?.status, .partial,
            "a pipeline already cancelled before process() even starts must "
                + "stop at its first checkpoint (`.partial`), proving "
                + "attachPipeline actually propagated the earlier cancel "
                + "request rather than leaving the pipeline to run to "
                + "completion (`.complete`) unobserved")

        await placeholderRunning.fire()
    }

    /// The fix for the cancellation-reach regression a third review found:
    /// `begin` used to (when `Run` was a struct) unconditionally overwrite
    /// `runs[id]`, discarding the predecessor's `Run` INCLUDING its
    /// `pipeline` reference. Concretely: Reprocess (pipeline attached,
    /// transcribing) → Tidy up notes (registers, chained; predecessor's
    /// pipeline handle dropped) → Delete — the delete could only reach the
    /// TAIL run (nothing to cancel yet), await it, which awaits the
    /// transcribe, which then ran UNCANCELLED to completion. `Run` is now a
    /// class with a `previous` link, and `requestCancel` walks the whole
    /// chain. This test proves that directly: cancelling via the tail
    /// (second) run's token must still reach the FIRST run's already-
    /// attached, genuinely in-flight pipeline.
    ///
    /// Reverting `Run` back to a struct (or `requestCancel` back to only
    /// touching the tail) makes this test fail: the predecessor's `process()`
    /// call would run to `.complete` uncancelled instead of stopping at its
    /// first checkpoint (`.partial`) — verified by hand while implementing
    /// this fix.
    @MainActor
    func testRequestCancelReachesAPredecessorsAlreadyAttachedPipeline() async {
        let registry = PipelineRunRegistry()
        let (pipeline, store, _, id, arrived, proceed) = await makeGatedPipeline()

        let firstTask = registry.begin(id: id) { _ in
            _ = await pipeline.process(meetingID: id, progress: nil)
        }
        guard let firstToken = registry.run(for: id)?.token else {
            return XCTFail("expected a registration after the first begin()")
        }
        await registry.attachPipeline(id: id, token: firstToken, pipeline: pipeline)
        await arrived.wait()   // process() is now genuinely parked mid mic-stage

        // Chained after the first — the exact scenario a review found broke
        // cancellation reach ("Tidy up my notes" landing while "Reprocess"
        // is still transcribing).
        let secondRan = CallCounter()
        let secondTask = registry.begin(id: id) { _ in await secondRan.increment() }
        guard let secondToken = registry.run(for: id)?.token else {
            return XCTFail("expected a registration after the second begin()")
        }
        XCTAssertNotEqual(firstToken, secondToken)

        // Cancel via the TAIL (second) token only — as `deleteMeeting` does,
        // reading only the CURRENT registration. Must still reach the first
        // run's already-attached pipeline.
        await registry.requestCancel(id: id, token: secondToken)
        await proceed.fire()
        await firstTask.value
        await secondTask.value

        let stored = await store.meeting(id: id)
        XCTAssertEqual(stored?.status, .partial,
            "requestCancel on the tail run must still reach a predecessor's "
                + "already-attached pipeline — losing the `previous` chain link "
                + "makes the predecessor's pipeline unreachable, so it runs to "
                + "`.complete` uncancelled instead")
        let secondCalls = await secondRan.count
        XCTAssertEqual(secondCalls, 1, "the second run's own body must still run, "
            + "chained after the first, once the chain has drained")
    }

    /// The other half of the same cancellation-reach hole, found by a fourth
    /// review: walking the `previous` chain in `requestCancel` only helps if
    /// the predecessor's pipeline was ever STORED, and `attachPipeline` still
    /// required `token` to match the TAIL. The window that exposes it is
    /// wider than the one the test above covers — that one needs the
    /// successor to arrive after the predecessor has already attached, this
    /// one only needs the predecessor to be mid-`warmUp()`:
    ///
    /// - Reprocess registers run 1; `runProcessing` suspends in
    ///   `meetingDiarizer.warmUp()`, a multi-second FluidAudio model load,
    ///   BEFORE it ever calls `attachPipeline`.
    /// - "Tidy up my notes" registers run 2, which becomes the tail.
    /// - Run 1 resumes and attaches — against a tail that is no longer it,
    ///   so the pipeline was silently dropped and cancellation reached
    ///   nothing. It transcribed and summarized to completion while a
    ///   `deleteMeeting` sat blocked on it.
    ///
    /// So: attach AFTER the successor has taken the tail, then cancel via
    /// the tail's token as `deleteMeeting` does, and the predecessor's
    /// genuinely in-flight pipeline must still stop at its first checkpoint
    /// (`.partial`, not `.complete`).
    @MainActor
    func testAttachPipelineFindsItsOwnRunByTokenAfterASuccessorTookTheTail() async {
        let registry = PipelineRunRegistry()
        let (pipeline, store, _, id, arrived, proceed) = await makeGatedPipeline()

        let firstTask = registry.begin(id: id) { _ in
            _ = await pipeline.process(meetingID: id, progress: nil)
        }
        guard let firstToken = registry.run(for: id)?.token else {
            return XCTFail("expected a registration after the first begin()")
        }

        // The successor registers BEFORE the first run gets to attach —
        // standing in for the `warmUp()` suspension in `runProcessing`.
        let secondRan = CallCounter()
        let secondTask = registry.begin(id: id) { _ in await secondRan.increment() }
        guard let secondToken = registry.run(for: id)?.token else {
            return XCTFail("expected a registration after the second begin()")
        }
        XCTAssertNotEqual(firstToken, secondToken)

        // The first run's own attach, arriving late — it is no longer the
        // tail, but its token is still unique and still identifies it.
        await registry.attachPipeline(id: id, token: firstToken, pipeline: pipeline)
        await arrived.wait()   // process() is now genuinely parked mid mic-stage

        await registry.requestCancel(id: id, token: secondToken)
        await proceed.fire()
        await firstTask.value
        await secondTask.value

        let stored = await store.meeting(id: id)
        XCTAssertEqual(stored?.status, .partial,
            "a pipeline attached after a successor took the tail must still be "
                + "stored against its own run — otherwise requestCancel walks the "
                + "chain, finds `pipeline == nil`, and the predecessor runs to "
                + "`.complete` uncancelled while a delete blocks on it")
    }

    /// Direct test of the token-checked clear that is the fix for the bug
    /// itself: a stale token — the exact thing an earlier-finishing run's
    /// own completion handler would present after a later run has replaced
    /// its entry — must not erase a newer registration. Reverting
    /// `PipelineRunRegistry.clear(id:token:)` back to an unconditional
    /// `runs[id] = nil` (the shape of the original bug) makes this test
    /// fail — verified by hand during this fix.
    @MainActor
    func testClearIgnoresStaleTokenAndDoesNotEraseANewerRegistration() async {
        let registry = PipelineRunRegistry()
        let id = UUID()
        let neverProceeds = RaceSignal()

        _ = registry.begin(id: id) { _ in await neverProceeds.wait() }
        guard let firstToken = registry.run(for: id)?.token else {
            return XCTFail("expected a registration after begin()")
        }

        // Simulate the first run having already been superseded — as if it
        // had finished and cleared itself, and a second, legitimate run had
        // then been registered under the same id with a fresh token.
        registry.clear(id: id, token: firstToken)
        let secondTask = registry.begin(id: id) { _ in await neverProceeds.wait() }
        guard let secondToken = registry.run(for: id)?.token else {
            return XCTFail("expected a registration after the second begin()")
        }
        XCTAssertNotEqual(firstToken, secondToken)

        // The bug: an earlier run's own completion handler, calling clear
        // with ITS (now stale) token, must not erase the second run's entry.
        registry.clear(id: id, token: firstToken)
        XCTAssertEqual(registry.run(for: id)?.token, secondToken,
            "a stale token must not clear a newer run's registration")

        // Let the still-parked second run finish so nothing is left hanging.
        await neverProceeds.fire()
        await secondTask.value
    }

    // MARK: - withTimeout (bounding the setup guards)
    //
    // A review flagged that `meetingSetupInProgress`/`startMeetingTask` had
    // no bounded lifetime: `SystemAudioSource.start()` goes through
    // `SCShareableContent`/`SCStream`, which can block indefinitely if
    // `replayd` is wedged, and neither guard would ever clear. `withTimeout`
    // is the fix; these two tests exercise the race directly rather than
    // real ScreenCaptureKit calls.

    func testWithTimeoutReturnsCompletedWhenOperationFinishesFirst() async {
        let outcome = await AppController.withTimeout(seconds: 5) { 42 }
        switch outcome {
        case .completed(let value):
            XCTAssertEqual(value, 42)
        case .timedOut:
            XCTFail("a same-thread, non-suspending operation must not time out "
                + "against a 5s bound")
        }
    }

    /// Reverting `withTimeout` to simply `await operation()` (no race against
    /// a timeout at all) makes this test hang instead of failing fast —
    /// confirmed by hand while implementing the fix.
    func testWithTimeoutReturnsTimedOutWhenOperationNeverResolves() async {
        let neverResolves = RaceSignal()
        let outcome = await AppController.withTimeout(seconds: 0.05) { () -> Int in
            await neverResolves.wait()
            return 1
        }
        switch outcome {
        case .completed:
            XCTFail("the operation deliberately never resolves; it must not "
                + "have been reported as completed")
        case .timedOut:
            break
        }
        // Release the abandoned operation so it doesn't stay parked forever.
        await neverResolves.fire()
    }
}

// MARK: - Test doubles (race-specific; deliberately not shared with
// MeetingPipelineTests' private doubles of the same shape, since those are
// private to that file).

private struct RaceStubDiarizer: MeetingDiarizing {
    func diarize(samples: [Float],
                 progress: (@Sendable (Double) -> Void)?) async throws -> [DiarizedSpan] {
        []
    }
}

private final class FixedRaceGenerator: MeetingTextGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String]
    private var index = 0

    init(outputs: [String]) { self.outputs = outputs }

    /// Synchronous so the lock is never held across a suspension point — an
    /// `NSLock` taken directly inside an `async func` is a hard error under
    /// this toolchain's Swift 6 mode.
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

/// A `Sendable` call counter for asserting a closure was (or was not)
/// invoked, without a data race — plain `var` capture in a `@escaping`
/// closure that may run on a different task is not safe under Swift 6.
private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// Records the order events happen in, for asserting ordering (not just
/// eventual occurrence) across racing tasks.
private actor OrderLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

/// One-shot async rendezvous: `wait()` suspends until `fire()` is called, or
/// returns immediately if `fire()` already happened.
private actor RaceSignal {
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

/// A transcriber whose first call announces its own arrival (`arrived`) and
/// then blocks (`proceed`) until the test lets it continue — giving the test
/// a deterministic window in which `MeetingPipeline.process()` is genuinely
/// suspended mid-stage. A later call (the system stage) returns empty
/// immediately.
private final class GatedRaceTranscriber: MeetingSegmentTranscribing, @unchecked Sendable {
    private let arrived: RaceSignal
    private let proceed: RaceSignal
    private let script: [MeetingTranscriptSegment]
    private let lock = NSLock()
    private var callCount = 0

    init(arrived: RaceSignal, proceed: RaceSignal, script: [MeetingTranscriptSegment]) {
        self.arrived = arrived
        self.proceed = proceed
        self.script = script
    }

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
