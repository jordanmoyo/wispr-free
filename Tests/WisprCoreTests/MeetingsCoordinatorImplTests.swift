import XCTest
@testable import WisprCore

/// Exercises `MeetingsCoordinatorImpl`'s riskiest paths for real — against a
/// standalone-constructed instance, a fake recorder, and controllably-gated
/// pipelines — rather than by inspection alone.
///
/// A third review found this was the actual gap left after two rounds of
/// fixes to `stopMeeting`/`deleteMeeting`: their correctness depends on
/// registry/actor state observed ACROSS suspension points, and the
/// while-vs-if distinction in `deleteMeeting`'s cancel loop is exactly the
/// kind of thing inspection already got wrong once (see
/// `MeetingMutualExclusionTests
/// .testCancelLoopDrainsARunReRegisteredWhileAwaitingThePreviousOne`, which
/// that same review found was a hand-copied replica of the production loop
/// that never actually calls it). `AppController` itself cannot be
/// constructed in a test — `StatusItemController.init()` calls
/// `NSStatusBar.system.statusItem(withLength:)`, a real, visible side effect
/// — which is exactly why `MeetingsCoordinatorImpl` exists as its own,
/// independently-constructible type: every collaborator it needs
/// (`MeetingStore`/`MeetingAudioStore`/`SettingsStore`, a fake recorder, a
/// stub-backed pipeline) is already test-injectable on its own.
@MainActor
final class MeetingsCoordinatorImplTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("coordinator-test-\(UUID().uuidString)")
    }

    private func makeSettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "wispr-coordinator-test-\(UUID().uuidString)")!)
    }

    private func seg(_ text: String, _ start: TimeInterval) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(speaker: .others, start: start, end: start + 1, text: text)
    }

    /// Builds a coordinator wired to real, temp-directory-backed stores, a
    /// no-op UI surface, and the given recorder/pipeline factories — the
    /// minimum needed to exercise `stopMeeting`/`deleteMeeting`/
    /// `reprocess`/`enhanceNotes` for real.
    private func makeCoordinator(
        store: MeetingStore, audioStore: MeetingAudioStore,
        recorder: @escaping (UUID, URL, URL) -> any MeetingRecording,
        pipeline: @escaping (any MeetingDiarizing) -> MeetingPipeline,
        errors: CoordinatorErrorLog = CoordinatorErrorLog(),
        settings: SettingsStore? = nil
    ) -> MeetingsCoordinatorImpl {
        MeetingsCoordinatorImpl(
            meetingStore: store,
            meetingAudioStore: audioStore,
            settings: settings ?? makeSettings(),
            meetingDiarizer: CoordinatorTestStubDiarizer(),
            recorderFactory: recorder,
            pipelineFactory: pipeline,
            dictationPhaseIdle: { true },
            showError: { errors.record($0) },
            setStatusIcon: { _ in },
            rebuildMenu: {},
            showMeetingsWindow: {})
    }

    // MARK: - Item 1: stopMeeting must not be stuck behind a chained run

    /// The exact scenario a review found broke privacy: "Tidy up my notes"
    /// is reachable while a meeting is `.recording` (nothing disables it for
    /// that status), so an `enhanceNotes` run can already be registered and
    /// in flight for a meeting's id by the time the user presses Stop.
    ///
    /// Reverting `stopMeeting()` to its previous shape — registering the
    /// whole stop-then-process sequence as ONE `pipelineRuns.begin` call,
    /// with `recorder.stop()` called only inside that chained body — makes
    /// this test hang: `recorder.stop()` would then only run once the
    /// already-in-flight `enhanceNotes` run (parked on `proceed.wait()`
    /// below) finishes, so `stopArrived.wait()` would never resolve until
    /// this test's own `proceed.fire()` call releases it — the exact
    /// "recorder keeps capturing after Stop is pressed" bug this fixes.
    func testStopMeetingTearsDownRecorderImmediatelyEvenWhileAnEnhanceNotesRunIsInFlight() async {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()
        let id = UUID()
        var meeting = Meeting(id: id, title: "T", startedAt: Date(), status: .recording)
        meeting.userNotes = "raw notes to expand"
        await store.upsert(meeting)

        let arrived = CoordinatorRaceSignal()
        let proceed = CoordinatorRaceSignal()
        let generator = CoordinatorGatedGenerator(arrived: arrived, proceed: proceed)
        let pipeline = MeetingPipeline(
            store: store, audioStore: audioStore,
            transcriber: CoordinatorTestStubTranscriber(),
            diarizer: CoordinatorTestStubDiarizer(),
            generator: generator)

        let recorder = CoordinatorFakeRecorder(result: MeetingRecordingResult(
            micURL: nil, systemURL: nil, durationSeconds: 5,
            micFailed: false, systemFailed: false))

        let coordinator = makeCoordinator(
            store: store, audioStore: audioStore,
            recorder: { _, _, _ in recorder },
            pipeline: { _ in pipeline })
        coordinator.seedActiveRecording(id: id, recorder: recorder)

        // Registers a run for `id` ahead of the stop — mirroring "Tidy up my
        // notes" clicked while the meeting is still recording.
        let enhanceTask = Task { await coordinator.enhanceNotes(meetingID: id) }
        await arrived.wait()   // the enhance run is now genuinely parked in the generator

        let stopTask = Task { await coordinator.stopMeeting() }
        // Deterministic, not a sleep-and-hope: `recorder.stop()` fires this
        // signal the instant it's entered, regardless of what else is
        // chained for this meeting id.
        //
        // BOUNDED, not a bare `wait()`: on regression this signal never
        // fires (that is precisely the bug — `recorder.stop()` stuck behind
        // the chained enhance run), and an unbounded wait here wedged the
        // whole test binary rather than failing. A review confirmed that by
        // killing a run at 240 s. Named failure beats a hang, always.
        switch await AppController.withTimeout(seconds: 5,
                                               operation: { await recorder.stopArrived.wait() }) {
        case .completed:
            break
        case .timedOut:
            XCTFail("recorder.stop() never ran — it is stuck behind the chained "
                + "enhanceNotes run, which means the recorder keeps capturing "
                + "after the user pressed Stop")
            await proceed.fire()
            await stopTask.value
            await enhanceTask.value
            return
        }
        let stopCalls = await recorder.stopCallCount
        XCTAssertEqual(stopCalls, 1, "recorder.stop() must have been called by now")

        // `stopMeeting()` itself must still be parked — its own chained
        // store/audio work (`finishStopping`) is legitimately serialized
        // behind the still-in-flight enhanceNotes run; only recorder.stop()
        // is exempt from that chain.
        let outcome = await AppController.withTimeout(seconds: 0.1) { await stopTask.value }
        switch outcome {
        case .completed:
            XCTFail("stopMeeting() must not finish before the chained enhanceNotes "
                + "run it's queued behind completes")
        case .timedOut:
            break
        }

        await proceed.fire()
        await stopTask.value
        await enhanceTask.value

        // `finishStopping` sets `.processing` and `durationSeconds` from the
        // recorder's result, then immediately chains into `runProcessing` as
        // part of the SAME registered run — so `.processing` itself is only
        // ever transient here, not a value this test can observe as final.
        // This fake recorder produced no mic/system audio (both URLs nil),
        // so `MeetingPipeline.process()` correctly finds both tracks empty
        // and lands on `.failed` (see `MeetingPipeline.process()`'s
        // `guard !(micSegments.isEmpty && systemSegments.isEmpty)` branch) —
        // that's the real, correct terminal status, not a bug. What proves
        // `finishStopping`'s own mutation actually ran, chained after the
        // earlier enhanceNotes run, is `durationSeconds`: only `finishStopping`
        // ever writes it, and `runProcessing`'s later upserts never clear it.
        let stored = await store.meeting(id: id)
        XCTAssertEqual(stored?.durationSeconds, 5,
            "finishStopping's own store mutation (from the recorder's result) "
                + "must still have run, chained after the earlier enhanceNotes run")
        XCTAssertEqual(stored?.status, .failed,
            "the full stop-to-process chain must have run to completion too — "
                + "not still .recording")
    }

    // MARK: - deleteMeeting, for real

    func testDeleteMeetingRefusesWhileRecordingSettingUpOrStopping() async {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()

        let recordingID = UUID()
        await store.upsert(Meeting(id: recordingID, title: "Recording", startedAt: Date(), status: .recording))
        let setupID = UUID()
        await store.upsert(Meeting(id: setupID, title: "Setup", startedAt: Date(), status: .recording))
        let stoppingID = UUID()
        await store.upsert(Meeting(id: stoppingID, title: "Stopping", startedAt: Date(), status: .recording))

        let recorder = CoordinatorFakeRecorder(result: MeetingRecordingResult(
            micURL: nil, systemURL: nil, durationSeconds: 0, micFailed: false, systemFailed: false))
        let pipeline = MeetingPipeline(
            store: store, audioStore: audioStore,
            transcriber: CoordinatorTestStubTranscriber(),
            diarizer: CoordinatorTestStubDiarizer(),
            generator: CoordinatorTestStubGenerator())
        let coordinator = makeCoordinator(
            store: store, audioStore: audioStore,
            recorder: { _, _, _ in recorder }, pipeline: { _ in pipeline })

        coordinator.seedActiveRecording(id: recordingID, recorder: recorder)
        coordinator.seedSetupInProgress(id: setupID)
        coordinator.seedStoppingInProgress(id: stoppingID)

        await coordinator.deleteMeeting(id: recordingID)
        await coordinator.deleteMeeting(id: setupID)
        await coordinator.deleteMeeting(id: stoppingID)

        let stillRecording = await store.meeting(id: recordingID)
        let stillSetup = await store.meeting(id: setupID)
        let stillStopping = await store.meeting(id: stoppingID)
        XCTAssertNotNil(stillRecording, "a live recording must not be deletable")
        XCTAssertNotNil(stillSetup, "a meeting still being set up must not be deletable")
        XCTAssertNotNil(stillStopping, "a meeting still being stopped must not be deletable")
    }

    /// The same stopping guard as above, reached WITHOUT the
    /// `seedStoppingInProgress` seam — through the real `stopMeeting()`.
    ///
    /// A review found that deleting `meetingStoppingID = id` from
    /// `stopMeeting()` passed the entire suite: every test that asserted the
    /// guard reached that state only through the seam, so nothing covered
    /// the production assignment. That is the same defect class as the
    /// `deleteMeetingSafely` tests deleted in round 3 — passing tests over a
    /// path nothing ships through.
    ///
    /// The real sequence: press Stop, then Delete while the recorder is
    /// still finalizing its AAC writers. `meetingRecordingID` is already
    /// nil, and no run is registered with `pipelineRuns` yet (that happens
    /// only once `recorder.stop()` resolves), so `meetingStoppingID` is the
    /// ONLY thing standing between the delete and a row/audio teardown
    /// underneath a still-running stop — after which `finishStopping` would
    /// secure and upsert a meeting that no longer exists.
    ///
    /// Removing `meetingStoppingID = id` from `stopMeeting()` fails this
    /// test on the row assertion, cleanly and without hanging: the delete
    /// finds nothing to refuse it and nothing registered to await, so it
    /// deletes immediately.
    func testDeleteMeetingIsRefusedDuringTheRealStopMeetingsRecorderTeardownWindow() async {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()
        let id = UUID()
        await store.upsert(Meeting(id: id, title: "Live", startedAt: Date(), status: .recording))

        let releaseStop = CoordinatorRaceSignal()
        let recorder = CoordinatorFakeRecorder(
            result: MeetingRecordingResult(micURL: nil, systemURL: nil, durationSeconds: 7,
                                           micFailed: false, systemFailed: false),
            stopProceed: releaseStop)
        let pipeline = MeetingPipeline(
            store: store, audioStore: audioStore,
            transcriber: CoordinatorTestStubTranscriber(),
            diarizer: CoordinatorTestStubDiarizer(),
            generator: CoordinatorTestStubGenerator())
        let errors = CoordinatorErrorLog()
        let coordinator = makeCoordinator(
            store: store, audioStore: audioStore,
            recorder: { _, _, _ in recorder }, pipeline: { _ in pipeline },
            errors: errors)
        coordinator.seedActiveRecording(id: id, recorder: recorder)

        let stopTask = Task { await coordinator.stopMeeting() }
        switch await AppController.withTimeout(seconds: 5,
                                               operation: { await recorder.stopArrived.wait() }) {
        case .completed:
            break
        case .timedOut:
            XCTFail("recorder.stop() never ran, so this test never reached the "
                + "window it exists to cover")
            await releaseStop.fire()
            await stopTask.value
            return
        }

        // `stopMeeting()` is now parked inside its bounded wait on
        // `recorder.stop()` — the genuine teardown window.
        await coordinator.deleteMeeting(id: id)

        let duringTeardown = await store.meeting(id: id)
        XCTAssertNotNil(duringTeardown,
            "a meeting whose recorder is still being torn down must not be "
                + "deletable — finishStopping would then secure and upsert a "
                + "meeting that no longer exists")
        XCTAssertTrue(errors.messages.contains("Still finishing this recording — try again in a moment"),
            "the refusal must tell the user why, not fail silently")

        await releaseStop.fire()
        await stopTask.value
    }

    /// Minor 8, on the exact path the finding named: the menu bar labels the
    /// item "Stop Meeting" for the whole teardown (`meetingRecordingActive`
    /// stays true), but `stopMeeting()`'s own `guard let id =
    /// meetingRecordingID` returns silently there. When no Meetings pane has
    /// ever been opened — or one was opened and deallocated, since the
    /// coordinator's reference is weak — `toggleRecording()` takes its
    /// fallback branch, and a banner written into a view model that does not
    /// exist is not feedback. The pill is the only surface left.
    ///
    /// Reverting `toggleRecording()`'s guard fails this on an empty pill log,
    /// bounded, with no hang: `stopMeeting()` simply returns.
    func testMenuStopWithNoPaneOpenReportsTheStopWindowInsteadOfSilentlyNoOpping() async {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()
        let id = UUID()
        await store.upsert(Meeting(id: id, title: "Live", startedAt: Date(), status: .recording))

        let releaseStop = CoordinatorRaceSignal()
        let recorder = CoordinatorFakeRecorder(
            result: MeetingRecordingResult(micURL: nil, systemURL: nil, durationSeconds: 7,
                                           micFailed: false, systemFailed: false),
            stopProceed: releaseStop)
        let pipeline = MeetingPipeline(
            store: store, audioStore: audioStore,
            transcriber: CoordinatorTestStubTranscriber(),
            diarizer: CoordinatorTestStubDiarizer(),
            generator: CoordinatorTestStubGenerator())
        let errors = CoordinatorErrorLog()
        // Deliberately no `register(model:)` call — this is the menu-only
        // path, which is what makes the pill the only reachable surface.
        let coordinator = makeCoordinator(
            store: store, audioStore: audioStore,
            recorder: { _, _, _ in recorder }, pipeline: { _ in pipeline },
            errors: errors)
        coordinator.seedActiveRecording(id: id, recorder: recorder)

        let stopTask = Task { await coordinator.stopMeeting() }
        switch await AppController.withTimeout(seconds: 5,
                                               operation: { await recorder.stopArrived.wait() }) {
        case .completed:
            break
        case .timedOut:
            XCTFail("recorder.stop() never ran, so this test never reached the "
                + "window it exists to cover")
            await releaseStop.fire()
            await stopTask.value
            return
        }

        // "Stop Meeting" clicked again from the menu, mid-teardown.
        await coordinator.toggleRecording()

        XCTAssertEqual(errors.messages, [MeetingsViewModel.stillStoppingMessage],
            "the menu-only Stop must say the meeting is already stopping — a "
                + "silent no-op is what the finding named, and \"still starting\" "
                + "would describe the opposite transition")
        let stopCalls = await recorder.stopCallCount
        XCTAssertEqual(stopCalls, 1, "the second click must not start a second teardown")

        await releaseStop.fire()
        await stopTask.value
    }

    // MARK: - deleteAllMeetings / enforceRetention

    /// C1: the brief's original "Delete All Meetings" wiring called
    /// `MeetingStore.deleteAll()`/`MeetingAudioStore.deleteAll()` straight
    /// from `PrivacyPane`, with no awareness of a meeting actively
    /// recording — deleting every OTHER meeting while one is live is safe on
    /// its own, but the live meeting's own row/audio being wiped out from
    /// under its still-running recorder is exactly the resurrection race
    /// `deleteMeeting`'s guards exist to close for a single meeting.
    /// `deleteAllMeetings` must refuse the whole operation outright while
    /// any meeting is actively recording, being set up, or being stopped —
    /// same as `meetingRecordingActive` already governs elsewhere — and say
    /// so with the same pill language `deleteMeeting` uses.
    ///
    /// Reverting `deleteAllMeetings`'s guard fails this on the row count:
    /// both meetings would be gone instead of both surviving.
    ///
    /// N8 (round 2): a review found this test built an `audioStore` and
    /// called `prepareDirectory()` but never actually wrote or asserted a
    /// file — so deleting `await meetingAudioStore.deleteAll()` from the
    /// implementation left this test, and the sibling one below it, fully
    /// green: "Delete All Meetings" could stop deleting audio entirely and
    /// nothing here would notice, while `PRIVACY.md` promises it does. Both
    /// meetings now get a real mic-track file, and both survival
    /// assertions include the file, not just the row.
    func testDeleteAllMeetingsRefusesWhileAMeetingIsActivelyRecording() async throws {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()

        let recordingID = UUID()
        await store.upsert(Meeting(id: recordingID, title: "Live", startedAt: Date(), status: .recording))
        try Data(repeating: 0, count: 8).write(to: await audioStore.micURL(for: recordingID))
        let otherID = UUID()
        await store.upsert(Meeting(id: otherID, title: "Old", startedAt: Date(), status: .complete))
        try Data(repeating: 0, count: 8).write(to: await audioStore.micURL(for: otherID))

        let recorder = CoordinatorFakeRecorder(result: MeetingRecordingResult(
            micURL: nil, systemURL: nil, durationSeconds: 0, micFailed: false, systemFailed: false))
        let pipeline = MeetingPipeline(
            store: store, audioStore: audioStore,
            transcriber: CoordinatorTestStubTranscriber(),
            diarizer: CoordinatorTestStubDiarizer(),
            generator: CoordinatorTestStubGenerator())
        let errors = CoordinatorErrorLog()
        let coordinator = makeCoordinator(
            store: store, audioStore: audioStore,
            recorder: { _, _, _ in recorder }, pipeline: { _ in pipeline },
            errors: errors)
        coordinator.seedActiveRecording(id: recordingID, recorder: recorder)

        let succeeded = await coordinator.deleteAllMeetings()

        XCTAssertFalse(succeeded, "a refused bulk delete must report failure to its caller")
        let allAfter = await store.all()
        XCTAssertEqual(allAfter.count, 2,
            "a bulk delete attempted while any meeting is actively recording must be "
                + "refused outright — even meetings unrelated to the live one must survive")
        let recordingAudio = await audioStore.existingMicURL(for: recordingID)
        let otherAudio = await audioStore.existingMicURL(for: otherID)
        XCTAssertNotNil(recordingAudio, "the live meeting's audio must survive a refused delete")
        XCTAssertNotNil(otherAudio, "the unrelated meeting's audio must survive a refused delete too")
        XCTAssertTrue(errors.messages.contains("Stop the recording before deleting all meetings"),
            "the refusal must tell the user why, using the same pill language the "
                + "single-meeting path uses")
    }

    /// The functional counterpart: with nothing recording, `deleteAllMeetings`
    /// must actually delete every row AND every audio file (N8 — see the
    /// doc comment on the test above for why the file assertion is the
    /// load-bearing addition here).
    func testDeleteAllMeetingsDeletesEveryRowWhenNotBusy() async throws {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()
        let idA = UUID()
        await store.upsert(Meeting(id: idA, title: "A", startedAt: Date(), status: .complete))
        try Data(repeating: 0, count: 8).write(to: await audioStore.micURL(for: idA))
        let idB = UUID()
        await store.upsert(Meeting(id: idB, title: "B", startedAt: Date(), status: .failed))
        try Data(repeating: 0, count: 8).write(to: await audioStore.micURL(for: idB))

        let recorder = CoordinatorFakeRecorder(result: MeetingRecordingResult(
            micURL: nil, systemURL: nil, durationSeconds: 0, micFailed: false, systemFailed: false))
        let pipeline = MeetingPipeline(
            store: store, audioStore: audioStore,
            transcriber: CoordinatorTestStubTranscriber(),
            diarizer: CoordinatorTestStubDiarizer(),
            generator: CoordinatorTestStubGenerator())
        let coordinator = makeCoordinator(
            store: store, audioStore: audioStore,
            recorder: { _, _, _ in recorder }, pipeline: { _ in pipeline })

        let succeeded = await coordinator.deleteAllMeetings()

        XCTAssertTrue(succeeded, "an unrefused bulk delete must report success to its caller")
        let allAfter = await store.all()
        XCTAssertTrue(allAfter.isEmpty, "with nothing recording, every meeting must be deleted")
        let audioA = await audioStore.existingMicURL(for: idA)
        let audioB = await audioStore.existingMicURL(for: idB)
        XCTAssertNil(audioA, "every meeting's audio must actually be deleted too, not just its row")
        XCTAssertNil(audioB, "every meeting's audio must actually be deleted too, not just its row")
    }

    /// N1 (round 2): the exact check-then-act gap a review found in
    /// `deleteAllMeetings` — the guard passes once, up front, then the drain
    /// blocks (a gated pipeline stands in for a meeting mid-transcription
    /// after stopping), and while blocked a SECOND, brand-new meeting starts
    /// recording. A single up-front check can never see that: it must be
    /// re-evaluated after the drain, immediately before the two
    /// `deleteAll()` calls.
    ///
    /// Reverting the re-check (restoring the single guard-then-drain-then-
    /// delete shape) fails this on the row count: the new recording's row
    /// would be gone, deleted right out from under its own live recorder.
    func testDeleteAllMeetingsReChecksBusyStateAfterTheDrainBeforeActuallyDeleting() async throws {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()

        // Meeting A: already stopped, genuinely mid-transcription via a
        // gated transcriber — this is what the drain inside
        // `deleteAllMeetings` will block on.
        let idA = UUID()
        try Data(repeating: 0, count: 8).write(to: await audioStore.micURL(for: idA))
        try Data(repeating: 0, count: 8).write(to: await audioStore.systemURL(for: idA))
        await store.upsert(Meeting(id: idA, title: "Transcribing", startedAt: Date(),
                                   durationSeconds: 5, status: .processing))

        let arrived = CoordinatorRaceSignal()
        let proceed = CoordinatorRaceSignal()
        let transcriber = CoordinatorGatedTranscriber(arrived: arrived, proceed: proceed,
                                                      script: [seg("a", 0)])
        let pipelineA = MeetingPipeline(
            store: store, audioStore: audioStore, transcriber: transcriber,
            diarizer: CoordinatorTestStubDiarizer(), generator: CoordinatorTestStubGenerator(),
            loadSamples: { _ in [Float](repeating: 0.1, count: 16_000) })

        let recorder = CoordinatorFakeRecorder(result: MeetingRecordingResult(
            micURL: nil, systemURL: nil, durationSeconds: 0, micFailed: false, systemFailed: false))
        let errors = CoordinatorErrorLog()
        let coordinator = makeCoordinator(
            store: store, audioStore: audioStore,
            recorder: { _, _, _ in recorder }, pipeline: { _ in pipelineA },
            errors: errors)

        // Registers A's run so `deleteAllMeetings`'s drain has something to
        // block on.
        let reprocessTask = Task { await coordinator.reprocess(meetingID: idA) }
        await arrived.wait()   // A's pipeline is now genuinely parked mid-transcription

        let deleteTask = Task { await coordinator.deleteAllMeetings() }
        // Deterministic handoff: `deleteAllMeetings`'s own first `await`
        // (inside `drainPipelineRuns`, on `run.task.value`) frees the main
        // actor, which is what lets this next line actually land before the
        // drain resolves — the same interleaving
        // `testDeleteMeetingWhileLoopStillCancelsAndAwaitsARunReRegisteredWhileAwaitingThePreviousOne`
        // relies on for the same reason.
        await Task.yield()

        // Meeting B: a brand-new meeting starts recording WHILE the drain
        // above is still blocked on A — mirrors the real sequence (user
        // opens Settings → Delete All Meetings… → confirm, while an earlier
        // meeting is still transcribing, then starts a new recording from
        // the menu bar before the delete resolves).
        let idB = UUID()
        await store.upsert(Meeting(id: idB, title: "Live", startedAt: Date(), status: .recording))
        coordinator.seedActiveRecording(id: idB, recorder: recorder)

        // Let A's transcription resume and the drain finally return.
        await proceed.fire()
        await reprocessTask.value

        let succeeded = await deleteTask.value

        XCTAssertFalse(succeeded,
            "deleteAllMeetings must refuse once it re-observes a meeting actively "
                + "recording, even though its ORIGINAL guard check — before the drain — "
                + "passed")
        let bAfter = await store.meeting(id: idB)
        XCTAssertNotNil(bAfter,
            "the meeting that started recording DURING the drain must survive — "
                + "deleting it out from under its own live recorder is the exact "
                + "resurrection race this whole method exists to prevent")
        XCTAssertTrue(errors.messages.contains("Stop the recording before deleting all meetings"),
            "the refusal must use the same pill language as the up-front guard")
    }

    /// N1's re-check in `deleteAllMeetings` is actually two independent
    /// conditions ANDed together (`!meetingRecordingActive` AND the
    /// before/after id-set compare). A round-3 review found the test above
    /// only ever trips both at once — meeting B is both newly-recording AND
    /// a new row — so deleting EITHER condition individually still leaves
    /// the whole suite green; only the pair together is covered.
    ///
    /// This isolates the id-set-compare half: meeting C appears mid-drain
    /// with its OWN genuinely in-flight, ungated pipeline run, but is never
    /// marked recording (`seedActiveRecording` is never called for it) — so
    /// `meetingRecordingActive` stays false for the entire test. Only the
    /// id-set compare can notice C at all. If it's the thing doing the
    /// work, `deleteAllMeetings` must loop back and drain C's run too
    /// before proceeding; if it's been deleted (or the `meetingRecordingActive`
    /// re-check alone is relied on), nothing stops the delete from wiping
    /// C's row and audio out from under its still-parked pipeline the
    /// instant A's drain returns.
    func testDeleteAllMeetingsReDrainsAMeetingThatAppearsMidDrainEvenWhenItIsNotRecording() async throws {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()

        // Meeting A: already stopped, genuinely mid-transcription — what the
        // drain's FIRST pass blocks on, same shape as the test above.
        let idA = UUID()
        try Data(repeating: 0, count: 8).write(to: await audioStore.micURL(for: idA))
        await store.upsert(Meeting(id: idA, title: "A", startedAt: Date(),
                                   durationSeconds: 5, status: .processing))

        let arrivedA = CoordinatorRaceSignal()
        let proceedA = CoordinatorRaceSignal()
        let transcriberA = CoordinatorGatedTranscriber(arrived: arrivedA, proceed: proceedA,
                                                        script: [seg("a", 0)])
        let pipelineA = MeetingPipeline(
            store: store, audioStore: audioStore, transcriber: transcriberA,
            diarizer: CoordinatorTestStubDiarizer(), generator: CoordinatorTestStubGenerator(),
            loadSamples: { _ in [Float](repeating: 0.1, count: 16_000) })

        // Meeting C: does not exist yet when `deleteAllMeetings` takes its
        // first `meetingStore.all()` snapshot. Gets its own genuinely
        // in-flight pipeline run once it appears — never marked recording.
        let idC = UUID()
        let arrivedC = CoordinatorRaceSignal()
        let proceedC = CoordinatorRaceSignal()
        let transcriberC = CoordinatorGatedTranscriber(arrived: arrivedC, proceed: proceedC,
                                                        script: [seg("c", 0)])
        let pipelineC = MeetingPipeline(
            store: store, audioStore: audioStore, transcriber: transcriberC,
            diarizer: CoordinatorTestStubDiarizer(), generator: CoordinatorTestStubGenerator(),
            loadSamples: { _ in [Float](repeating: 0.1, count: 16_000) })

        var pipelineCallCount = 0
        let recorder = CoordinatorFakeRecorder(result: MeetingRecordingResult(
            micURL: nil, systemURL: nil, durationSeconds: 0, micFailed: false, systemFailed: false))
        let coordinator = makeCoordinator(
            store: store, audioStore: audioStore,
            recorder: { _, _, _ in recorder },
            pipeline: { _ in
                pipelineCallCount += 1
                return pipelineCallCount == 1 ? pipelineA : pipelineC
            })

        let reprocessA = Task { await coordinator.reprocess(meetingID: idA) }
        await arrivedA.wait()   // A's run is registered and genuinely parked — drain's first target

        let deleteTask = Task { await coordinator.deleteAllMeetings() }
        // Same deterministic handoff as the test above: `deleteAllMeetings`'s
        // own first `await` (inside `drainPipelineRuns`, on A's `task.value`)
        // frees the main actor long enough for this to land before the
        // drain resolves.
        await Task.yield()

        // Meeting C appears mid-drain with its own in-flight run, but NEVER
        // recording — the only thing that changed is the store's id set.
        try Data(repeating: 0, count: 8).write(to: await audioStore.micURL(for: idC))
        await store.upsert(Meeting(id: idC, title: "C", startedAt: Date(), status: .complete))
        let reprocessC = Task { await coordinator.reprocess(meetingID: idC) }
        await arrivedC.wait()   // C's run is registered and genuinely parked too, before A resolves

        // Let A's drain resolve. If the id-set compare is doing its job,
        // `deleteAllMeetings` must now notice `after != before` (C wasn't in
        // the original snapshot) and loop back to drain C as well, before
        // ever reaching either `deleteAll()` call.
        await proceedA.fire()
        await reprocessA.value

        // Bounded, not unconditional: without the id-set compare,
        // `deleteAllMeetings` has nothing left to stop it from proceeding
        // straight to `deleteAll()` the moment A's drain (its only known
        // target) returns — deleting C's row and audio while C's own
        // pipeline run is still genuinely parked on `proceedC`, unaware.
        let outcome = await AppController.withTimeout(seconds: 0.1) { await deleteTask.value }
        switch outcome {
        case .completed:
            XCTFail("deleteAllMeetings finished without ever draining meeting C's "
                + "run — it appeared mid-drain, was never marked recording, and only "
                + "the before/after id-set compare could have caught it")
            await proceedC.fire()
            await reprocessC.value
            return
        case .timedOut:
            break
        }

        await proceedC.fire()
        await reprocessC.value
        let succeeded = await deleteTask.value

        XCTAssertTrue(succeeded,
            "once both A's and C's runs are fully drained and nothing is recording, "
                + "the delete must actually succeed, not refuse forever")
        let aAfter = await store.meeting(id: idA)
        let cAfter = await store.meeting(id: idC)
        XCTAssertNil(aAfter, "meeting A must be deleted once the delete actually proceeds")
        XCTAssertNil(cAfter, "meeting C must be deleted too, once ITS run was drained safely")
    }

    /// N9 (round 2): a review found the previous version of this test —
    /// `maxBytes: 0, maxAgeDays: 90` against one fresh 4 MB file — only
    /// proved `coordinator.enforceRetention` REACHES the audio store, not
    /// that it passes the caps through in the right order: a delegation
    /// that swapped the two arguments (`maxBytes: 90, maxAgeDays: 0`,
    /// clamped to 1) still evicts that one file, since 90 bytes is smaller
    /// than 4 MB either way — the test could not tell correct delegation
    /// from a swapped one.
    ///
    /// Two files distinguish them: `keep` is small and fresh (survives
    /// under the REAL caps below: 1 MB ceiling, 90-day age limit), `evict`
    /// is small but 200 days old (survives the size cap alone, but not the
    /// age cap). Under the real argument order, `keep` survives and `evict`
    /// is gone. Swap the two arguments internally and the age cutoff
    /// effectively disappears (turns into `maxAgeDays: 1_000_000`, ~2,700
    /// years) while the size cap collapses to 90 bytes — smaller than
    /// EITHER file — so both get evicted, including `keep`. `keep`
    /// surviving is what a swap cannot produce; `evict` being gone is what
    /// no delegation at all cannot produce — together they cover both
    /// failure modes.
    func testEnforceRetentionDelegatesToTheAudioStoreWithTheCapsInTheRightOrder() async throws {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()
        let keepID = UUID()
        try Data(repeating: 0, count: 100).write(to: await audioStore.micURL(for: keepID))
        let evictID = UUID()
        try Data(repeating: 0, count: 100).write(to: await audioStore.micURL(for: evictID))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-200 * 86_400)],
            ofItemAtPath: (await audioStore.micURL(for: evictID)).path)

        let recorder = CoordinatorFakeRecorder(result: MeetingRecordingResult(
            micURL: nil, systemURL: nil, durationSeconds: 0, micFailed: false, systemFailed: false))
        let pipeline = MeetingPipeline(
            store: store, audioStore: audioStore,
            transcriber: CoordinatorTestStubTranscriber(),
            diarizer: CoordinatorTestStubDiarizer(),
            generator: CoordinatorTestStubGenerator())
        let coordinator = makeCoordinator(
            store: store, audioStore: audioStore,
            recorder: { _, _, _ in recorder }, pipeline: { _ in pipeline })

        await coordinator.enforceRetention(maxBytes: 1_000_000, maxAgeDays: 90)

        let keepURL = await audioStore.existingMicURL(for: keepID)
        let evictURL = await audioStore.existingMicURL(for: evictID)
        XCTAssertNotNil(keepURL,
            "a fresh file well under the size cap must survive with the caps passed "
                + "through in the correct order — it would NOT survive a swap, where "
                + "maxBytes collapses to 90 bytes")
        XCTAssertNil(evictURL,
            "a 200-day-old file must still be evicted by the age cap — proving "
                + "delegation reaches the audio store at all")
    }

    /// N2 (round 2): a review rejected the round-1 fix for I3 — draining
    /// (cancelling) every in-flight pipeline run before sweeping — because
    /// it made a strictly non-destructive intent (raising a retention cap)
    /// destructive: it silently truncated whatever meeting happened to be
    /// transcribing the moment the cap changed. The replacement is
    /// exclusion, not cancellation — a meeting with a currently-registered
    /// run is left OUT of the sweep entirely, survives regardless of its
    /// age/size, and its run is never touched.
    ///
    /// One meeting (`busy`) has a gated, genuinely in-flight `reprocess` run
    /// and a small, ancient audio file that a size-0 cap would otherwise
    /// evict instantly. A second, unrelated meeting (`idle`) has an
    /// equally-evictable file but no in-flight run. `coordinator
    /// .enforceRetention(maxBytes: 0, ...)` must evict `idle`'s file (the
    /// cap is real) while leaving `busy`'s file untouched (excluded) AND
    /// its pipeline run un-cancelled (still parked on `proceed`, not
    /// resolved).
    ///
    /// Reverting the exclusion (having `enforceRetention` pass no
    /// `excludingMeetingIDs`, or reintroducing a drain) fails this: either
    /// `busy`'s file is gone too (no exclusion) or `busy`'s pipeline
    /// resolves without `proceed` ever being fired (a drain cancelled it).
    func testEnforceRetentionExcludesABusyMeetingsAudioWithoutCancellingItsRun() async throws {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()

        let busyID = UUID()
        try Data(repeating: 0, count: 8).write(to: await audioStore.micURL(for: busyID))
        try Data(repeating: 0, count: 8).write(to: await audioStore.systemURL(for: busyID))
        await store.upsert(Meeting(id: busyID, title: "Busy", startedAt: Date(),
                                   durationSeconds: 5, status: .processing))

        let idleID = UUID()
        try Data(repeating: 0, count: 8).write(to: await audioStore.micURL(for: idleID))
        await store.upsert(Meeting(id: idleID, title: "Idle", startedAt: Date(), status: .complete))

        let arrived = CoordinatorRaceSignal()
        let proceed = CoordinatorRaceSignal()
        let transcriber = CoordinatorGatedTranscriber(arrived: arrived, proceed: proceed,
                                                      script: [seg("a", 0)])
        let pipeline = MeetingPipeline(
            store: store, audioStore: audioStore, transcriber: transcriber,
            diarizer: CoordinatorTestStubDiarizer(), generator: CoordinatorTestStubGenerator(),
            loadSamples: { _ in [Float](repeating: 0.1, count: 16_000) })

        let recorder = CoordinatorFakeRecorder(result: MeetingRecordingResult(
            micURL: nil, systemURL: nil, durationSeconds: 0, micFailed: false, systemFailed: false))
        let coordinator = makeCoordinator(
            store: store, audioStore: audioStore,
            recorder: { _, _, _ in recorder }, pipeline: { _ in pipeline })

        let reprocessTask = Task { await coordinator.reprocess(meetingID: busyID) }
        await arrived.wait()   // busyID's pipeline is now genuinely parked mid-transcription

        await coordinator.enforceRetention(maxBytes: 0, maxAgeDays: 90)

        let busyAudio = await audioStore.existingMicURL(for: busyID)
        XCTAssertNotNil(busyAudio,
            "a meeting with a currently-registered pipeline run must be excluded from "
                + "the sweep entirely, regardless of the cap")
        let idleAudio = await audioStore.existingMicURL(for: idleID)
        XCTAssertNil(idleAudio,
            "an unrelated, non-busy meeting must still be evicted normally — the cap "
                + "itself must still be real")

        // Bounded, not a bare `wait()`: proves `reprocessTask` hasn't
        // resolved without risking a hang if some future regression made it
        // resolve unexpectedly.
        //
        // This is NOT what would catch a reintroduced drain, though (round
        // 3, D5 — a review found the comment previously claimed it was):
        // `CoordinatorGatedTranscriber` never checks `Task.isCancelled`, so
        // cancelling it does not unblock `await proceed.wait()` inside
        // `transcribeSegments` — a reintroduced drain would hang on its OWN
        // `await run.task.value` inside the `enforceRetention(...)` call
        // above, before this line is ever reached, not let `reprocessTask`
        // resolve early via `savePartial`. Confirmed directly: reverting to
        // the round-1 drain-based `enforceRetention` hangs this test past
        // 600s rather than failing cleanly — independent evidence the
        // round-1 drain was worse than N2's original description of it.
        // What this bound actually guards is the assertion immediately
        // above surviving to be checked at all, rather than the test itself
        // wedging if some other regression made `busyAudio` resolve `nil`
        // through a path that also somehow completed `reprocessTask`.
        let outcome = await AppController.withTimeout(seconds: 0.1) { await reprocessTask.value }
        switch outcome {
        case .completed:
            XCTFail("enforceRetention must not cancel a busy meeting's in-flight run — "
                + "it resolved without this test ever firing `proceed`, meaning "
                + "something cancelled it")
        case .timedOut:
            break
        }

        await proceed.fire()
        await reprocessTask.value
    }

    /// N3 (round 2/3): `finishStopping` bypasses the coordinator's own
    /// `enforceRetention(maxBytes:maxAgeDays:)` and calls
    /// `meetingAudioStore.enforceRetention` directly instead — draining
    /// THIS meeting's own just-finished run from inside that run's own body
    /// would self-deadlock. It still passes `excludingMeetingIDs:`, the
    /// same protection the coordinator method applies. A round-2 report
    /// claimed this one line had no dedicated end-to-end test because
    /// `SettingsStore`'s minimum-1 clamp on `meetingRetentionDays` made real
    /// eviction pressure impractical to force through production settings
    /// in a unit test. A round-3 review found that reasoning false: the
    /// 1-day floor doesn't block eviction at all — a file older than one day
    /// is evicted by the age cutoff regardless of how low the floor is —
    /// and `makeCoordinator`'s settings already come from an isolated
    /// `UserDefaults` suite this test can write `meetingRetentionDays = 1`
    /// into directly. No new seam was needed; this is the actual end-to-end
    /// test through the real `stopMeeting` → `finishStopping` path.
    ///
    /// Meeting B is unrelated to A's stop: a genuinely in-flight `reprocess`
    /// run (parked mid-transcription, ignoring cooperative cancellation,
    /// same as the test above) plus a 200-day-old track file that
    /// `meetingRetentionDays = 1` would otherwise evict outright. Stopping A
    /// for real must run `finishStopping`'s own `enforceRetention` sweep
    /// after A's processing completes — B's file must survive it because B
    /// is excluded, not because the cap happens not to apply.
    func testFinishStoppingExcludesABusyMeetingsAudioFromItsOwnPostProcessingSweep() async throws {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()
        let settings = makeSettings()
        settings.meetingRetentionDays = 1

        // Meeting B: busy (in-flight reprocess) with an ancient track file
        // that a 1-day retention floor would otherwise evict outright.
        let idB = UUID()
        try Data(repeating: 0, count: 8).write(to: await audioStore.micURL(for: idB))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-200 * 86_400)],
            ofItemAtPath: (await audioStore.micURL(for: idB)).path)
        await store.upsert(Meeting(id: idB, title: "Busy", startedAt: Date(), status: .complete))

        let arrivedB = CoordinatorRaceSignal()
        let proceedB = CoordinatorRaceSignal()
        let transcriberB = CoordinatorGatedTranscriber(arrived: arrivedB, proceed: proceedB,
                                                        script: [seg("b", 0)])
        let pipelineB = MeetingPipeline(
            store: store, audioStore: audioStore, transcriber: transcriberB,
            diarizer: CoordinatorTestStubDiarizer(), generator: CoordinatorTestStubGenerator(),
            loadSamples: { _ in [Float](repeating: 0.1, count: 16_000) })

        // Meeting A: about to be stopped for real. Its own pipeline is
        // deliberately NOT gated — this test needs A's whole stop-to-process
        // chain (including `finishStopping`'s own `enforceRetention` call)
        // to run to completion promptly, while B stays parked throughout.
        let idA = UUID()
        await store.upsert(Meeting(id: idA, title: "A", startedAt: Date(), status: .recording))
        let pipelineA = MeetingPipeline(
            store: store, audioStore: audioStore,
            transcriber: CoordinatorTestStubTranscriber(),
            diarizer: CoordinatorTestStubDiarizer(),
            generator: CoordinatorTestStubGenerator())

        // Dispatch by call order: B's `reprocess` registers (and its
        // `pipelineFactory` call lands) strictly before A's `stopMeeting`
        // does, below.
        var pipelineCallCount = 0
        let recorder = CoordinatorFakeRecorder(result: MeetingRecordingResult(
            micURL: nil, systemURL: nil, durationSeconds: 3, micFailed: false, systemFailed: false))
        let coordinator = makeCoordinator(
            store: store, audioStore: audioStore,
            recorder: { _, _, _ in recorder },
            pipeline: { _ in
                pipelineCallCount += 1
                return pipelineCallCount == 1 ? pipelineB : pipelineA
            },
            settings: settings)
        coordinator.seedActiveRecording(id: idA, recorder: recorder)

        let reprocessB = Task { await coordinator.reprocess(meetingID: idB) }
        await arrivedB.wait()   // B's run is registered and genuinely parked mid-transcription

        // Real stop, real finishStopping, real post-processing enforceRetention
        // sweep — no test seam standing in for any of it.
        await coordinator.stopMeeting()

        let survivingB = await audioStore.existingMicURL(for: idB)
        XCTAssertNotNil(survivingB,
            "meeting B's 200-day-old track must survive finishStopping's own "
                + "post-processing retention sweep (meetingRetentionDays = 1) because "
                + "B has a currently-registered pipeline run — excluding it, not "
                + "cancelling it, is the whole point of N3")

        await proceedB.fire()
        await reprocessB.value
    }

    /// A track that dies mid-meeting leaves its file behind, and the pipeline
    /// derives degradation from track *absence* — a present file counts as a
    /// good track. So a recorder that captured five minutes before the
    /// interface was unplugged produced a `.complete` meeting reading "Ready",
    /// whose transcript just stopped, with nothing indicating anything was
    /// lost. `micFailed`/`systemFailed` had no production reader at all.
    func testATrackThatDiedMidMeetingMarksTheTranscriptIncompleteNotReady() async throws {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()

        let id = UUID()
        // Both tracks present on disk — the writer died only after capturing
        // real audio, which is exactly what makes this case invisible.
        let micURL = await audioStore.micURL(for: id)
        try Data(repeating: 0, count: 8).write(to: micURL)
        try Data(repeating: 0, count: 8).write(to: await audioStore.systemURL(for: id))
        await store.upsert(Meeting(id: id, title: "Cut short", startedAt: Date(),
                                   status: .recording))

        let recorder = CoordinatorFakeRecorder(result: MeetingRecordingResult(
            micURL: micURL, systemURL: nil, durationSeconds: 300,
            micFailed: true, systemFailed: false))
        // Ungated: both signals pre-fired, so this transcriber just returns
        // its script and never parks.
        let openGate = CoordinatorRaceSignal()
        await openGate.fire()
        let coordinator = makeCoordinator(
            store: store, audioStore: audioStore,
            recorder: { _, _, _ in recorder },
            pipeline: { _ in MeetingPipeline(
                store: store, audioStore: audioStore,
                transcriber: CoordinatorGatedTranscriber(
                    arrived: openGate, proceed: openGate, script: [self.seg("a", 0)]),
                diarizer: CoordinatorTestStubDiarizer(),
                generator: CoordinatorSummaryGenerator(),
                loadSamples: { _ in [Float](repeating: 0.1, count: 16_000) }) })
        coordinator.seedActiveRecording(id: id, recorder: recorder)

        await coordinator.stopMeeting()

        let saved = await store.meeting(id: id)
        XCTAssertFalse(saved?.segments.isEmpty ?? true,
            "sanity: the pipeline did produce a transcript from the audio that "
                + "was captured before the track died")
        XCTAssertEqual(saved?.status, .partial,
            "a meeting whose track died mid-recording must not read Ready — its "
                + "transcript is truncated and only .partial says so")
    }

    // MARK: - Item 3: reconcileAtLaunch must not touch this
    // coordinator's own in-flight ids

    /// A review found that `AppController.start()` calls `buildMenu()` —
    /// making Record Meeting clickable — before `bootstrap()` even begins,
    /// and `bootstrap()` awaits `loadSelectedModel()` (a Whisper load that
    /// can take many seconds) before calling `reconcileAtLaunch()`.
    /// A meeting started by the user in that window is genuinely live, but
    /// its row's `status` is indistinguishable from a truly orphaned one
    /// (both `.recording`) to anything that only looks at the store. This
    /// exercises the three ids `reconcileAtLaunch` must recognize
    /// as "mine, not orphaned" — the active recording, a meeting still being
    /// set up, and one still being stopped — alongside a genuinely orphaned
    /// row with none of those ids, proving only the truly orphaned one flips
    /// to `.failed`.
    func testReconcileOrphanedRecordingsSkipsThisCoordinatorsOwnLiveRecordingSetupAndStopping() async {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()

        let recordingID = UUID()
        await store.upsert(Meeting(id: recordingID, title: "Recording", startedAt: Date(), status: .recording))
        let setupID = UUID()
        await store.upsert(Meeting(id: setupID, title: "Setup", startedAt: Date(), status: .recording))
        let stoppingID = UUID()
        await store.upsert(Meeting(id: stoppingID, title: "Stopping", startedAt: Date(), status: .recording))
        let orphanedID = UUID()
        await store.upsert(Meeting(id: orphanedID, title: "Orphaned", startedAt: Date(), status: .recording))

        let recorder = CoordinatorFakeRecorder(result: MeetingRecordingResult(
            micURL: nil, systemURL: nil, durationSeconds: 0, micFailed: false, systemFailed: false))
        let pipeline = MeetingPipeline(
            store: store, audioStore: audioStore,
            transcriber: CoordinatorTestStubTranscriber(),
            diarizer: CoordinatorTestStubDiarizer(),
            generator: CoordinatorTestStubGenerator())
        let coordinator = makeCoordinator(
            store: store, audioStore: audioStore,
            recorder: { _, _, _ in recorder }, pipeline: { _ in pipeline })

        coordinator.seedActiveRecording(id: recordingID, recorder: recorder)
        coordinator.seedSetupInProgress(id: setupID)
        coordinator.seedStoppingInProgress(id: stoppingID)

        await coordinator.reconcileAtLaunch()

        let recordingAfter = await store.meeting(id: recordingID)
        let setupAfter = await store.meeting(id: setupID)
        let stoppingAfter = await store.meeting(id: stoppingID)
        let orphanedAfter = await store.meeting(id: orphanedID)
        XCTAssertEqual(recordingAfter?.status, .recording,
            "a live recording this coordinator itself owns must not be reconciled to .failed")
        XCTAssertEqual(setupAfter?.status, .recording,
            "a meeting still being set up must not be reconciled to .failed")
        XCTAssertEqual(stoppingAfter?.status, .recording,
            "a meeting still being stopped must not be reconciled to .failed")
        XCTAssertEqual(orphanedAfter?.status, .failed,
            "a genuinely orphaned .recording row (none of this coordinator's own "
                + "ids) must still be reconciled to .failed")
    }

    /// A quit or crash between `finishStopping` writing `.processing` and the
    /// pipeline's final checkpoint left the row `.processing` forever —
    /// nothing reconciled that status. `MeetingDetailView` disables Reprocess
    /// for `.processing`, so the meeting was wedged: stuck label, no recovery
    /// action, audio and partial transcript still on disk and still good.
    /// A row that got as far as a transcript resolves to `.partial`; one that
    /// didn't resolves to `.failed`. Both re-enable Reprocess.
    func testReconcileAtLaunchResolvesOrphanedProcessingRowsByWhatTheyContain() async {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()

        let withTranscript = UUID()
        await store.upsert(Meeting(id: withTranscript, title: "Got somewhere",
                                   startedAt: Date(), status: .processing,
                                   segments: [seg("a", 0)]))
        let empty = UUID()
        await store.upsert(Meeting(id: empty, title: "Got nowhere",
                                   startedAt: Date(), status: .processing))

        let recorder = CoordinatorFakeRecorder(result: MeetingRecordingResult(
            micURL: nil, systemURL: nil, durationSeconds: 0, micFailed: false, systemFailed: false))
        let coordinator = makeCoordinator(
            store: store, audioStore: audioStore,
            recorder: { _, _, _ in recorder },
            pipeline: { _ in MeetingPipeline(
                store: store, audioStore: audioStore,
                transcriber: CoordinatorTestStubTranscriber(),
                diarizer: CoordinatorTestStubDiarizer(),
                generator: CoordinatorTestStubGenerator()) })

        await coordinator.reconcileAtLaunch()

        let withTranscriptAfter = await store.meeting(id: withTranscript)
        let emptyAfter = await store.meeting(id: empty)
        XCTAssertEqual(withTranscriptAfter?.status, .partial,
            "an orphaned .processing row that already has a transcript must resolve "
                + "to .partial, not stay wedged at .processing with Reprocess disabled")
        XCTAssertEqual(withTranscriptAfter?.segments.count, 1,
            "reconciling must not touch the transcript the dead run had persisted")
        XCTAssertEqual(emptyAfter?.status, .failed,
            "an orphaned .processing row with nothing to show must resolve to .failed")
    }

    /// `secure` (0600 + backup exclusion) runs in `finishStopping`, which a
    /// crash or force-quit never reaches — the tracks of an orphaned meeting
    /// stayed at the writer's default 0644 and Time-Machine-eligible for
    /// good. Launch is the first moment after the crash that anything looks
    /// at them.
    func testReconcileAtLaunchSecuresTheTracksOfAnOrphanedRecording() async throws {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()

        let id = UUID()
        let micURL = await audioStore.micURL(for: id)
        try Data(repeating: 0, count: 8).write(to: micURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: micURL.path)
        await store.upsert(Meeting(id: id, title: "Crashed", startedAt: Date(),
                                   status: .recording))

        let recorder = CoordinatorFakeRecorder(result: MeetingRecordingResult(
            micURL: nil, systemURL: nil, durationSeconds: 0, micFailed: false, systemFailed: false))
        let coordinator = makeCoordinator(
            store: store, audioStore: audioStore,
            recorder: { _, _, _ in recorder },
            pipeline: { _ in MeetingPipeline(
                store: store, audioStore: audioStore,
                transcriber: CoordinatorTestStubTranscriber(),
                diarizer: CoordinatorTestStubDiarizer(),
                generator: CoordinatorTestStubGenerator()) })

        await coordinator.reconcileAtLaunch()

        let perms = try FileManager.default.attributesOfItem(atPath: micURL.path)[.posixPermissions]
        XCTAssertEqual(perms as? NSNumber, 0o600,
            "a crash-orphaned track must be tightened to 0600 at the next launch")
        let excluded = try micURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
            .isExcludedFromBackup
        XCTAssertEqual(excluded, true,
            "and excluded from Time Machine, like every other meeting track")
    }

    /// Retention's only other triggers are the end of a recording and a
    /// change to either cap in Settings → Privacy. A user who records nothing
    /// and changes nothing therefore never swept, and audio past the caps
    /// they had already set survived indefinitely — the Privacy pane says
    /// those caps delete it. Launch is the one moment guaranteed to come
    /// around.
    func testReconcileAtLaunchAppliesRetention() async throws {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()
        let settings = makeSettings()
        settings.meetingRetentionDays = 1

        let stale = UUID()
        let staleURL = await audioStore.micURL(for: stale)
        try Data(repeating: 0, count: 8).write(to: staleURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-200 * 86_400)],
            ofItemAtPath: staleURL.path)
        await store.upsert(Meeting(id: stale, title: "Old", startedAt: Date(), status: .complete))

        let recorder = CoordinatorFakeRecorder(result: MeetingRecordingResult(
            micURL: nil, systemURL: nil, durationSeconds: 0, micFailed: false, systemFailed: false))
        let coordinator = makeCoordinator(
            store: store, audioStore: audioStore,
            recorder: { _, _, _ in recorder },
            pipeline: { _ in MeetingPipeline(
                store: store, audioStore: audioStore,
                transcriber: CoordinatorTestStubTranscriber(),
                diarizer: CoordinatorTestStubDiarizer(),
                generator: CoordinatorTestStubGenerator()) },
            settings: settings)

        await coordinator.reconcileAtLaunch()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path),
            "launch must sweep audio already past the retention caps — otherwise a "
                + "user who never records again never sweeps at all")
    }

    /// The production replacement for the coverage lost when
    /// `deleteMeetingSafely` (and its two tests) were deleted — it had zero
    /// production callers, so its passing tests covered code nothing shipped
    /// through while the real `deleteMeeting` loop went untested. This
    /// exercises the same resurrection-race invariant — cancel, then AWAIT,
    /// then delete, never delete first — through `coordinator.deleteMeeting`
    /// itself.
    func testDeleteMeetingCancelsAndAwaitsAnInFlightReprocessRunBeforeDeletingForReal() async {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()
        let id = UUID()
        try? Data(repeating: 0, count: 8).write(to: await audioStore.micURL(for: id))
        try? Data(repeating: 0, count: 8).write(to: await audioStore.systemURL(for: id))
        await store.upsert(Meeting(id: id, title: "T", startedAt: Date(),
                                   durationSeconds: 10, status: .processing))

        let arrived = CoordinatorRaceSignal()
        let proceed = CoordinatorRaceSignal()
        let transcriber = CoordinatorGatedTranscriber(arrived: arrived, proceed: proceed,
                                                      script: [seg("a", 0)])
        let generator = CoordinatorFixedGenerator(
            outputs: ["- b", "## Summary\nDone.\n## Action items\n## Decisions"])
        let pipeline = MeetingPipeline(
            store: store, audioStore: audioStore, transcriber: transcriber,
            diarizer: CoordinatorTestStubDiarizer(), generator: generator,
            loadSamples: { _ in [Float](repeating: 0.1, count: 16_000 * 10) })

        let recorder = CoordinatorFakeRecorder(result: MeetingRecordingResult(
            micURL: nil, systemURL: nil, durationSeconds: 0, micFailed: false, systemFailed: false))
        let coordinator = makeCoordinator(
            store: store, audioStore: audioStore,
            recorder: { _, _, _ in recorder }, pipeline: { _ in pipeline })

        let reprocessTask = Task { await coordinator.reprocess(meetingID: id) }
        await arrived.wait()   // process() is now genuinely parked mid mic-stage

        let deleteTask = Task { await coordinator.deleteMeeting(id: id) }
        // Let the parked transcription resume now — racing deleteTask's own
        // cancel-then-await-then-delete sequence.
        await proceed.fire()
        await deleteTask.value
        await reprocessTask.value

        let stored = await store.meeting(id: id)
        XCTAssertNil(stored, "delete must win: a checkpoint upsert from the "
            + "cancelled run reaching the store after the row was deleted must "
            + "not resurrect it — reverting deleteMeeting's `await run.task.value` "
            + "back to a bare cancel-and-delete-immediately reopens this")
    }

    /// The `while`-vs-`if` distinction in `deleteMeeting`'s cancel loop,
    /// exercised through the real coordinator rather than the hand-copied
    /// registry-level replica in `MeetingMutualExclusionTests
    /// .testCancelLoopDrainsARunReRegisteredWhileAwaitingThePreviousOne` — a
    /// review flagged that replica as the exact kind of thing inspection
    /// already got wrong once: it proves `PipelineRunRegistry`'s own chaining
    /// is correct, but not that `deleteMeeting`'s loop actually re-reads the
    /// registry after each await, since it never calls `coordinator
    /// .deleteMeeting` at all.
    ///
    /// Two independently-gated pipelines (selected by call order from
    /// `pipelineFactory`) stand in for two genuinely separate `reprocess`
    /// runs for the same id, chained back to back: the second is registered
    /// only after `deleteMeeting` has already captured the first as `run` —
    /// while `deleteMeeting` is off on its own first suspension (the
    /// cross-actor `pipeline.cancel()` hop inside `requestCancel`) — so a
    /// single-pass `if` would never see it.
    func testDeleteMeetingWhileLoopStillCancelsAndAwaitsARunReRegisteredWhileAwaitingThePreviousOne() async {
        let dir = tempDir()
        let store = MeetingStore(directoryURL: dir)
        let audioStore = MeetingAudioStore(directoryURL: dir.appendingPathComponent("audio"))
        try? await audioStore.prepareDirectory()
        let id = UUID()
        try? Data(repeating: 0, count: 8).write(to: await audioStore.micURL(for: id))
        try? Data(repeating: 0, count: 8).write(to: await audioStore.systemURL(for: id))
        await store.upsert(Meeting(id: id, title: "T", startedAt: Date(),
                                   durationSeconds: 10, status: .processing))

        let arrived1 = CoordinatorRaceSignal()
        let proceed1 = CoordinatorRaceSignal()
        let transcriber1 = CoordinatorGatedTranscriber(arrived: arrived1, proceed: proceed1,
                                                        script: [seg("a", 0)])
        let generator1 = CoordinatorFixedGenerator(
            outputs: ["- b", "## Summary\nDone.\n## Action items\n## Decisions"])
        let pipeline1 = MeetingPipeline(
            store: store, audioStore: audioStore, transcriber: transcriber1,
            diarizer: CoordinatorTestStubDiarizer(), generator: generator1,
            loadSamples: { _ in [Float](repeating: 0.1, count: 16_000 * 10) })

        let arrived2 = CoordinatorRaceSignal()
        let proceed2 = CoordinatorRaceSignal()
        let transcriber2 = CoordinatorGatedTranscriber(arrived: arrived2, proceed: proceed2,
                                                        script: [seg("c", 0)])
        let generator2 = CoordinatorFixedGenerator(
            outputs: ["- d", "## Summary\nDone2.\n## Action items\n## Decisions"])
        let pipeline2 = MeetingPipeline(
            store: store, audioStore: audioStore, transcriber: transcriber2,
            diarizer: CoordinatorTestStubDiarizer(), generator: generator2,
            loadSamples: { _ in [Float](repeating: 0.1, count: 16_000 * 10) })

        var pipelineCallCount = 0
        let recorder = CoordinatorFakeRecorder(result: MeetingRecordingResult(
            micURL: nil, systemURL: nil, durationSeconds: 0, micFailed: false, systemFailed: false))
        let coordinator = MeetingsCoordinatorImpl(
            meetingStore: store, meetingAudioStore: audioStore, settings: makeSettings(),
            meetingDiarizer: CoordinatorTestStubDiarizer(),
            recorderFactory: { _, _, _ in recorder },
            pipelineFactory: { _ in
                pipelineCallCount += 1
                return pipelineCallCount == 1 ? pipeline1 : pipeline2
            },
            dictationPhaseIdle: { true }, showError: { _ in }, setStatusIcon: { _ in },
            rebuildMenu: {}, showMeetingsWindow: {})

        let firstTask = Task { await coordinator.reprocess(meetingID: id) }
        await arrived1.wait()   // the first run is registered and genuinely parked

        let deleteTask = Task { await coordinator.deleteMeeting(id: id) }
        // Registered on the very next actor turn: `deleteMeeting`'s own
        // first await — the cross-actor `pipeline.cancel()` hop inside
        // `requestCancel`, since the first run's pipeline is already
        // attached by the time `arrived1` fired — frees the main actor just
        // long enough for this to land and chain onto the still-current
        // first registration before `deleteMeeting` reads the registry
        // again.
        let secondTask = Task { await coordinator.reprocess(meetingID: id) }

        await proceed1.fire()
        await firstTask.value

        // Bounded, not unconditional: a single-pass `if` would let
        // `deleteMeeting` delete the row right after the first run alone —
        // before the re-registered run's own `process()` ever gets to check
        // whether the meeting still exists — so its very first guard
        // (`guard var meeting = await store.meeting(id:) else return nil`)
        // fires instead, and it silently returns without ever reaching
        // `transcribe()`. `arrived2` would then never fire at all, which is
        // itself the distinguishing signal, worse than just a slow delete:
        // the re-registered run's work is silently dropped with no trace,
        // not merely raced.
        let arrivedOutcome = await AppController.withTimeout(seconds: 2) { await arrived2.wait() }
        switch arrivedOutcome {
        case .completed:
            break
        case .timedOut:
            XCTFail("the re-registered run never reached transcribe() at all — "
                + "deleteMeeting deleted the row before it got a chance to see "
                + "the meeting still existed, silently dropping its work; this "
                + "is what a single-pass `if` reintroduces")
            await proceed2.fire()
            await secondTask.value
            await deleteTask.value
            return
        }

        // The re-registered run is now genuinely parked too. A correct
        // `while` loop re-read the registry after the first run cleared and
        // is now parked on this run's own `task.value`, which cannot
        // resolve without `proceed2` — so `deleteTask` must still be
        // unresolved.
        let outcome = await AppController.withTimeout(seconds: 0.1) { await deleteTask.value }
        switch outcome {
        case .completed:
            XCTFail("deleteMeeting finished without waiting for the run that was "
                + "re-registered while it was still awaiting the first one — this "
                + "is the exact regression a single-pass `if` reintroduces")
        case .timedOut:
            break
        }

        await proceed2.fire()
        await secondTask.value
        await deleteTask.value

        let stored = await store.meeting(id: id)
        XCTAssertNil(stored, "delete must win here too: the re-registered run's own "
            + "checkpoint/completion upsert reaching the store after the row was "
            + "deleted must not resurrect it")
    }
}

// MARK: - Test doubles (deliberately not shared with other files' private
// doubles of the same shape — see e.g. MeetingMutualExclusionTests' own note
// on this).

/// Captures what the coordinator would have shown in the pill. The pill is
/// the ONLY feedback surface the menu-bar path can reach when no Meetings
/// pane has ever registered, so "did it say anything at all" is a real
/// assertion, not decoration.
private final class CoordinatorErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String] = []

    func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        _messages.append(message)
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _messages
    }
}

private struct CoordinatorTestStubDiarizer: MeetingDiarizing {
    func diarize(samples: [Float],
                 progress: (@Sendable (Double) -> Void)?) async throws -> [DiarizedSpan] {
        []
    }
}

private struct CoordinatorTestStubTranscriber: MeetingSegmentTranscribing {
    func transcribeSegments(samples: [Float], language: String?,
                            progress: (@Sendable (Double) -> Void)?) async throws
        -> [MeetingTranscriptSegment] {
        []
    }
}

private struct CoordinatorTestStubGenerator: MeetingTextGenerating {
    func generate(system: String, user: String, maxTokens: Int) async throws -> String { "" }
}

/// Produces a real, parseable summary, so a run that reaches the end lands on
/// `.complete` rather than the `.partial` an empty summary degrades to. Tests
/// that assert on degradation from some OTHER cause need that distinction:
/// against `CoordinatorTestStubGenerator` every completed run is `.partial`
/// already, and the assertion proves nothing.
private struct CoordinatorSummaryGenerator: MeetingTextGenerating {
    func generate(system: String, user: String, maxTokens: Int) async throws -> String {
        """
        ## Summary
        We covered the agenda.
        ## Action items
        - None
        ## Decisions
        - None
        """
    }
}

private final class CoordinatorFixedGenerator: MeetingTextGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String]
    private var index = 0

    init(outputs: [String]) { self.outputs = outputs }

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

/// Fires `arrived` and blocks on `proceed` the first time `generate` is
/// called (`MeetingNotesEnhancer.enhance` calls it once, given non-empty
/// notes) — gives a test a deterministic window in which `enhanceNotes` is
/// genuinely suspended.
private final class CoordinatorGatedGenerator: MeetingTextGenerating, @unchecked Sendable {
    private let arrived: CoordinatorRaceSignal
    private let proceed: CoordinatorRaceSignal

    init(arrived: CoordinatorRaceSignal, proceed: CoordinatorRaceSignal) {
        self.arrived = arrived
        self.proceed = proceed
    }

    func generate(system: String, user: String, maxTokens: Int) async throws -> String {
        await arrived.fire()
        await proceed.wait()
        return "expanded notes"
    }
}

/// A transcriber whose first call announces its own arrival (`arrived`) and
/// then blocks (`proceed`) until the test lets it continue.
private final class CoordinatorGatedTranscriber: MeetingSegmentTranscribing, @unchecked Sendable {
    private let arrived: CoordinatorRaceSignal
    private let proceed: CoordinatorRaceSignal
    private let script: [MeetingTranscriptSegment]
    private let lock = NSLock()
    private var callCount = 0

    init(arrived: CoordinatorRaceSignal, proceed: CoordinatorRaceSignal,
         script: [MeetingTranscriptSegment]) {
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

/// A `MeetingRecording` fake with a controllable, instrumented `stop()`:
/// counts calls, and fires `stopArrived` the instant it's entered —
/// deterministically signalling "recorder.stop() has started" without
/// depending on real hardware or a sleep-and-hope poll.
private final class CoordinatorFakeRecorder: MeetingRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var _stopCallCount = 0
    let stopArrived = CoordinatorRaceSignal()
    let result: MeetingRecordingResult
    /// When set, `stop()` parks on it after announcing its arrival — holding
    /// the coordinator inside its real stop window (AAC finalization, in
    /// production) for as long as the test needs to act on it.
    private let stopProceed: CoordinatorRaceSignal?

    init(result: MeetingRecordingResult, stopProceed: CoordinatorRaceSignal? = nil) {
        self.result = result
        self.stopProceed = stopProceed
    }

    func start() async throws {}

    /// Synchronous so the lock is never held across a suspension point — an
    /// `NSLock` taken directly inside an `async func` is a hard error under
    /// this toolchain's Swift 6 mode.
    private func recordStopCall() {
        lock.lock()
        defer { lock.unlock() }
        _stopCallCount += 1
    }

    private func readStopCallCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return _stopCallCount
    }

    func stop() async -> MeetingRecordingResult {
        recordStopCall()
        await stopArrived.fire()
        await stopProceed?.wait()
        return result
    }

    var elapsedSeconds: Double {
        get async { 0 }
    }

    var reachedDurationCap: Bool {
        get async { false }
    }

    var stopCallCount: Int {
        get async { readStopCallCount() }
    }
}

/// One-shot async rendezvous: `wait()` suspends until `fire()` is called, or
/// returns immediately if `fire()` already happened. (Reimplemented here
/// rather than shared with `MeetingMutualExclusionTests`' `RaceSignal` of the
/// same shape, since those doubles are private to that file.)
private actor CoordinatorRaceSignal {
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
