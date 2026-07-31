import AppKit
import Foundation

/// Abstracts `MeetingRecorder` (an `actor`, hence `Sendable`-compatible by
/// construction) so `MeetingsCoordinatorImpl` can be exercised in tests
/// against a fake with a controllable, gated `stop()`/`start()` — including
/// the stop-during-enhance ordering `stopMeeting()` must get right — instead
/// of requiring real `AVAudioEngine`/ScreenCaptureKit hardware.
public protocol MeetingRecording: Sendable {
    func start() async throws
    func stop() async -> MeetingRecordingResult
    var elapsedSeconds: Double { get async }
    var reachedDurationCap: Bool { get async }
}

extension MeetingRecorder: MeetingRecording {}

/// Owns every piece of state and logic behind meeting recording: the
/// recorder, the setup/stop/coalescing flags, the pipeline-run chain, and
/// the registered `MeetingsViewModel`. Extracted out of `AppController`
/// (where all of this used to live directly) specifically so it can be
/// constructed on its own in a test, with fakes substituted for the
/// recorder and the pipeline — `AppController` itself cannot safely be
/// constructed in a test: `StatusItemController.init()` calls
/// `NSStatusBar.system.statusItem(withLength:)`, a real, visible side effect
/// on construction, with no test-only alternative initializer. A review
/// twice deferred this extraction as "larger scope"; the third round made it
/// non-optional — `deleteMeeting`'s and `stopMeeting`'s correctness both now
/// depend on registry/actor state observed ACROSS suspension points, which
/// inspection alone already got wrong once (see `PipelineRunRegistry`'s doc
/// comment).
///
/// `AppController` owns one instance of this as a stored property and
/// forwards `meetingRecordingActive`/`toggleMeetingRecording` to it; every
/// other meetings entry point (`MainWindowController`'s
/// `meetingsCoordinator:` parameter) talks to it directly through
/// `MeetingsCoordinating`, type-erased, exactly as it did with
/// `AppController` before.
@MainActor
final class MeetingsCoordinatorImpl {
    private let meetingStore: MeetingStore
    private let meetingAudioStore: MeetingAudioStore
    private let settings: SettingsStore
    private let meetingDiarizer: any MeetingDiarizing
    /// Builds the recorder for a new meeting. Production default builds a
    /// real `MeetingRecorder`; tests substitute a fake conforming to
    /// `MeetingRecording` with a controllable, gated `stop()`.
    private let recorderFactory: (UUID, URL, URL) -> any MeetingRecording
    /// Builds the pipeline used for a `process()`/`enhanceNotes()` run.
    /// Production default (built by `AppController`) shares the app's real
    /// transcriber/MLX backend; tests substitute one built from stub
    /// doubles (`GatedRaceTranscriber`/`FixedRaceGenerator`/etc).
    private let pipelineFactory: (any MeetingDiarizing) -> MeetingPipeline
    private let dictationPhaseIdle: () -> Bool
    private let showError: (String) -> Void
    private let setStatusIcon: (StatusItemController.Icon) -> Void
    private let rebuildMenu: () -> Void
    private let showMeetingsWindow: () -> Void

    /// How long `withTimeout`-wrapped ScreenCaptureKit calls (permission
    /// probe, `recorder.start()`/`stop()`) are allowed to run before the
    /// setup/teardown attempt gives up on them. See `AppController
    /// .withTimeout`'s doc comment for why an unbounded wait is
    /// unacceptable.
    static let screenCaptureTimeoutSeconds: TimeInterval = 12

    private var meetingRecorder: (any MeetingRecording)?
    private var meetingRecordingID: UUID?
    private var meetingTimer: Timer?
    /// True from the moment `startMeeting()` commits to starting a
    /// recording until that attempt either succeeds or cleanly rolls back.
    /// See the original `AppController` doc comment (carried forward in
    /// spirit): without this, dictation could start its own `AVAudioEngine`
    /// capture on the same physical input while `MeetingMicSource` is
    /// mid-bind.
    private var meetingSetupInProgress = false
    /// True from the moment `stopMeeting()` commits to stopping until
    /// `recorder.stop()` has actually resolved (or this gives up waiting on
    /// it — see `stopMeeting`). Mirrors `meetingSetupInProgress` for the
    /// opposite transition, and unblocks dictation as soon as the mic tap is
    /// LIKELY down — narrower than a guarantee; see `stopMeeting`'s comment.
    private var meetingStopInProgress = false
    /// The id of the meeting currently being set up, so `deleteMeeting` can
    /// refuse deleting it even though `meetingRecordingID` is nil for that
    /// whole window.
    private var meetingSetupID: UUID?
    /// The id of the meeting currently being stopped, from the instant
    /// `stopMeeting()` clears `meetingRecordingID` until this coordinator's
    /// own pipeline run for it has been registered with `pipelineRuns`.
    ///
    /// This exists because of a genuine regression a review found in the fix
    /// for the "recorder keeps capturing past Stop" bug (see `stopMeeting`'s
    /// comment): once `recorder.stop()` was moved to run BEFORE the chained
    /// `pipelineRuns.begin` — so it can never be stuck behind an unrelated
    /// queued `enhanceNotes`/`reprocess` run — there is a real `await`
    /// between clearing `meetingRecordingID` and registering the run that
    /// protects this id from `deleteMeeting`. Without a guard for exactly
    /// that window, a `deleteMeeting(id:)` landing while `recorder.stop()`
    /// is still finalizing its AAC writers would delete the row and audio
    /// tracks out from under it — reopening the exact resurrection race
    /// `pipelineRuns`/`deleteMeetingSafely` exist to close, since the
    /// still-running stop would then secure/upsert a meeting that no longer
    /// exists. Set and cleared with zero suspension around the
    /// `pipelineRuns.begin` call in `stopMeeting`, so there is no gap
    /// between this flag covering the window and `pipelineRuns` taking over.
    private var meetingStoppingID: UUID?
    /// A menu-triggered `startMeeting()` failure captured while no Meetings
    /// pane has ever registered, so `register(model:)` can apply it to the
    /// pane's banner the moment one finally does.
    private var pendingMenuStartFailure: MeetingStartFailure?
    /// Coalesces concurrent `startMeeting()` calls into one attempt. Claimed
    /// synchronously, before any `await`.
    private var startMeetingTask: Task<Result<UUID, MeetingStartFailure>, Never>?
    /// Tracks the single in-flight pipeline run (`process`, `reprocess`, or
    /// `enhanceNotes`) for a meeting, keyed by id, so `deleteMeeting` can
    /// find and await it. See `PipelineRunRegistry`'s doc comment.
    private let pipelineRuns = PipelineRunRegistry()
    /// Weak: the coordinator must never be the thing keeping a closed
    /// Meetings pane's view model alive.
    private weak var meetingsModel: MeetingsViewModel?

    init(meetingStore: MeetingStore,
         meetingAudioStore: MeetingAudioStore,
         settings: SettingsStore,
         meetingDiarizer: any MeetingDiarizing,
         recorderFactory: @escaping (UUID, URL, URL) -> any MeetingRecording,
         pipelineFactory: @escaping (any MeetingDiarizing) -> MeetingPipeline,
         dictationPhaseIdle: @escaping () -> Bool,
         showError: @escaping (String) -> Void,
         setStatusIcon: @escaping (StatusItemController.Icon) -> Void,
         rebuildMenu: @escaping () -> Void,
         showMeetingsWindow: @escaping () -> Void) {
        self.meetingStore = meetingStore
        self.meetingAudioStore = meetingAudioStore
        self.settings = settings
        self.meetingDiarizer = meetingDiarizer
        self.recorderFactory = recorderFactory
        self.pipelineFactory = pipelineFactory
        self.dictationPhaseIdle = dictationPhaseIdle
        self.showError = showError
        self.setStatusIcon = setStatusIcon
        self.rebuildMenu = rebuildMenu
        self.showMeetingsWindow = showMeetingsWindow
    }

    /// Read by `AppController.beginRecording()` to refuse dictation while a
    /// meeting is recording, being set up, or being torn down, and evaluated
    /// by `meetingStartRefusal` to refuse a second meeting while one is
    /// already active.
    var meetingRecordingActive: Bool {
        meetingRecordingID != nil || meetingSetupInProgress || meetingStopInProgress
    }

    // MARK: - Test seams
    //
    // `startMeeting()` goes through real permission checks
    // (`Permissions.microphoneGranted()`, `SystemAudioSource
    // .permissionGranted()`) that depend on the test machine's actual OS
    // permission state — exercising `stopMeeting()`/`deleteMeeting()`'s own
    // logic (the thing under test) must not also depend on that. These let
    // a test put the coordinator directly into the state each of those
    // methods expects to find, with an injected fake recorder standing in
    // for real hardware.

    /// Puts the coordinator into "actively recording `id` with `recorder`"
    /// state, as if `startMeeting()` had just succeeded.
    func seedActiveRecording(id: UUID, recorder: any MeetingRecording) {
        meetingRecordingID = id
        meetingRecorder = recorder
    }

    /// Puts the coordinator into the setup window `deleteMeeting` refuses —
    /// see `meetingSetupID`'s doc comment.
    func seedSetupInProgress(id: UUID) {
        meetingSetupID = id
        meetingSetupInProgress = true
    }

    /// Puts the coordinator into the stopping window `deleteMeeting`
    /// refuses — see `meetingStoppingID`'s doc comment.
    func seedStoppingInProgress(id: UUID) {
        meetingStoppingID = id
        meetingStopInProgress = true
    }

    /// Menu-bar entry point, routed through the registered `meetingsModel`
    /// when one exists so a menu-triggered start/stop shares the exact same
    /// code path as the Meetings pane's own Record button. Falls back to the
    /// direct coordinator call + pill only when no Meetings pane has been
    /// opened yet this session.
    func toggleRecording() async {
        if let model = meetingsModel {
            if meetingRecordingActive {
                await model.stopRecording()
            } else {
                await model.startRecording()
            }
            return
        }
        if meetingRecordingActive {
            // `stopMeeting()`'s own `guard let id = meetingRecordingID` returns
            // silently during both transition windows, where
            // `meetingRecordingActive` is true but the id is not yet (or no
            // longer) assigned. On the pane's path the view model reports
            // that itself; here there is no pane — this branch is taken
            // precisely because none was ever opened, or one was opened and
            // deallocated — so a banner written into a view model that does
            // not exist is not feedback. The pill is the only surface the
            // menu can reach, which is why the start-failure branch below
            // also opens the window rather than relying on a banner alone.
            guard meetingRecordingID != nil else {
                showError(meetingStopInProgress
                    ? MeetingsViewModel.stillStoppingMessage
                    : MeetingsViewModel.stillStartingMessage)
                return
            }
            await stopMeeting()
        } else {
            let result = await startMeeting()
            if case .failure(let failure) = result {
                pendingMenuStartFailure = failure
                showError(failure.userMessage)
                showMeetingsWindow()
            }
        }
    }

    /// Launch-time housekeeping for Meetings: reconciles rows left mid-flight
    /// by a previous launch, then applies the retention caps.
    ///
    /// Reconciles any meeting row still marked `.recording` from a previous
    /// launch — this process's `meetingRecordingID` starts nil, so by
    /// definition any such row was never cleanly stopped (a crash or force
    /// quit killed the recorder before `stopMeeting` ever ran). Marking it
    /// `.failed` is what lets `MeetingsPane`/`MeetingDetailView` stop
    /// disabling Delete for it.
    ///
    /// Scoped to skip whatever this coordinator itself currently considers
    /// live (`meetingRecordingID`/`meetingSetupID`/`meetingStoppingID`). A
    /// review found that `AppController.start()` calls `buildMenu()`
    /// (making Record Meeting clickable) before `bootstrap()` even begins,
    /// and `bootstrap()` itself awaits `loadSelectedModel()` — a Whisper
    /// load that can take many seconds — before ever calling this. A
    /// meeting started by the user in that window had its own live
    /// `.recording` row flipped to `.failed` by this method: the pane
    /// showed "Failed" mid-recording, and — worse — both Delete guards
    /// re-enabled for the live meeting (they key off stored status, which
    /// this had just corrupted), defeating the guard entirely.
    /// A row left `.processing` is orphaned the same way, by a quit or crash
    /// between `finishStopping` setting that status and the pipeline reaching
    /// its final checkpoint. It was worse than a stuck label:
    /// `MeetingDetailView` disables Reprocess for `.processing`, so the one
    /// action that could recover the meeting was unreachable, permanently,
    /// while the audio and partial transcript both sat on disk intact. It
    /// resolves to `.partial` when the dead run had already persisted a
    /// transcript and `.failed` when it hadn't — both re-enable Reprocess,
    /// and neither claims more than the meeting actually has.
    ///
    /// Retention also runs here. Its only other triggers are the end of a
    /// recording and a change to either cap in Settings → Privacy, so a user
    /// who lowers nothing and records nothing never sweeps: audio past the
    /// caps they set survived indefinitely, contradicting what the Privacy
    /// pane says those caps do. Launch is the one moment guaranteed to come
    /// around. It uses the same `excludingMeetingIDs:` protection as every
    /// other sweep.
    func reconcileAtLaunch() async {
        var reconciledAny = false
        let live = pipelineRuns.activeIDs()
        for meeting in await meetingStore.all()
        where (meeting.status == .recording || meeting.status == .processing)
            && meeting.id != meetingRecordingID
            && meeting.id != meetingSetupID
            && meeting.id != meetingStoppingID
            && !live.contains(meeting.id) {
            let resolved: MeetingStatus = meeting.status == .processing
                && !meeting.segments.isEmpty ? .partial : .failed
            await meetingStore.update(id: meeting.id) { $0.status = resolved }
            // `secure` normally runs in `finishStopping`, which a crash or
            // force-quit never reached — these tracks were created at the
            // default umask and stayed 0644 and Time-Machine-eligible
            // indefinitely, which is not what the Privacy page describes.
            // This is the first moment after the crash that anything looks
            // at them.
            if let url = await meetingAudioStore.existingMicURL(for: meeting.id) {
                await meetingAudioStore.secure(url)
            }
            if let url = await meetingAudioStore.existingSystemURL(for: meeting.id) {
                await meetingAudioStore.secure(url)
            }
            reconciledAny = true
            WisprLog.log("meeting reconcile: orphaned \(meeting.status.rawValue) row "
                + "\(meeting.id) marked \(resolved.rawValue) at launch")
        }
        if reconciledAny {
            NotificationCenter.default.post(name: .wisprMeetingsDidChange, object: nil)
        }

        await meetingAudioStore.enforceRetention(
            maxBytes: settings.meetingRetentionBytes,
            maxAgeDays: settings.meetingRetentionDays,
            excludingMeetingIDs: pipelineRuns.activeIDs())
    }

    func startMeeting() async -> Result<UUID, MeetingStartFailure> {
        if let existing = meetingRecordingID { return .success(existing) }
        guard !meetingStopInProgress else { return .failure(.meetingStopping) }
        if let inFlight = startMeetingTask { return await inFlight.value }
        let task = Task { await self.performStartMeeting() }
        startMeetingTask = task
        let result = await task.value
        startMeetingTask = nil
        return result
    }

    private func performStartMeeting() async -> Result<UUID, MeetingStartFailure> {
        let micOK = await Permissions.microphoneGranted()
        let screenOK: Bool
        switch await AppController.withTimeout(
            seconds: Self.screenCaptureTimeoutSeconds,
            operation: { await SystemAudioSource.permissionGranted() }
        ) {
        case .completed(let granted):
            screenOK = granted
        case .timedOut:
            WisprLog.log("meeting start: screen recording permission probe exceeded "
                + "\(Self.screenCaptureTimeoutSeconds)s — treating as not granted")
            screenOK = false
        }
        if let refusal = AppController.meetingStartRefusal(
            dictationPhaseIdle: dictationPhaseIdle(),
            meetingActive: meetingRecordingActive,
            micGranted: micOK,
            screenRecordingGranted: screenOK) {
            WisprLog.log("meeting start refused: \(refusal)")
            return .failure(refusal)
        }
        meetingSetupInProgress = true
        rebuildMenu()
        defer {
            meetingSetupInProgress = false
            meetingSetupID = nil
            rebuildMenu()
        }

        let id = UUID()
        meetingSetupID = id
        let detected = CallAppDetector.callApp(
            among: Set(NSWorkspace.shared.runningApplications
                .compactMap(\.bundleIdentifier)))
        var meeting = Meeting(
            id: id,
            title: Meeting.defaultTitle(appName: detected?.name, startedAt: Date()),
            startedAt: Date(), status: .recording)
        meeting.appBundleID = detected?.bundleID
        await meetingStore.upsert(meeting)

        do {
            try await meetingAudioStore.prepareDirectory()
        } catch {
            WisprLog.log("meeting start: audio dir FAILED: \(error)")
            await meetingStore.delete(id: id)
            return .failure(.bothTracksFailed)
        }

        let recorder = recorderFactory(
            id,
            await meetingAudioStore.micURL(for: id),
            await meetingAudioStore.systemURL(for: id))
        guard await startRecorderBounded(recorder, id: id) else {
            await meetingStore.delete(id: id)
            await meetingAudioStore.delete(id: id)
            return .failure(.bothTracksFailed)
        }

        meetingRecorder = recorder
        meetingRecordingID = id
        startMeetingTimer()
        setStatusIcon(.recording)
        NotificationCenter.default.post(name: .wisprMeetingsDidChange, object: nil)
        return .success(id)
    }

    /// Stops the current recording. A review found that the previous shape
    /// — clear state, then register the whole stop-then-process sequence as
    /// ONE `pipelineRuns.begin` call, awaited — meant `recorder.stop()`
    /// itself was chained behind whatever was already registered for this
    /// meeting id (e.g. an `enhanceNotes` run kicked off from "Tidy up my
    /// notes", not disabled while `.recording`). The mic and system-audio
    /// taps stayed LIVE, still writing into the meeting's files, for the
    /// entire time something else was ahead of it in the chain, while the
    /// menu bar/pane/timer all already claimed the recording had ended —
    /// self-healing once the chain drained, but recording past an explicit
    /// Stop while the UI says otherwise is a privacy problem, not just a
    /// responsiveness one.
    ///
    /// The fix: `recorder.stop()` doesn't touch `MeetingStore`/
    /// `MeetingAudioStore` at all, so nothing about it needs to serialize
    /// against other in-flight runs for this id — only what comes after
    /// (securing the audio, upserting `.processing`, running the pipeline)
    /// does. So it's torn down here, immediately, unconditionally, BEFORE
    /// anything is registered with `pipelineRuns` — only `finishStopping`'s
    /// store/audio work is chained.
    func stopMeeting() async {
        guard let id = meetingRecordingID, let recorder = meetingRecorder else { return }
        stopMeetingTimer()
        meetingStopInProgress = true
        meetingStoppingID = id
        meetingRecordingID = nil
        meetingRecorder = nil
        rebuildMenu()
        setStatusIcon(.idle)
        meetingsModel?.syncRecording(id: nil)

        // Bounded the same way `startRecorderBounded` bounds `recorder
        // .start()`. `stopTask` (not the raw operation) is what makes it
        // safe to still await the real result below even after giving up on
        // the race: `Task.value` can be awaited more than once.
        let stopTask = Task<MeetingRecordingResult, Never> { await recorder.stop() }
        switch await AppController.withTimeout(
            seconds: Self.screenCaptureTimeoutSeconds,
            operation: { await stopTask.value }
        ) {
        case .completed:
            break
        case .timedOut:
            WisprLog.log("meeting stop: recorder.stop() exceeded "
                + "\(Self.screenCaptureTimeoutSeconds)s — freeing dictation now; "
                + "still waiting for it to actually finish before this meeting's "
                + "own processing run continues")
        }
        // Freed as soon as `stop()` either resolves or we give up waiting on
        // it here. The one realistic wedge is `SystemAudioSource.stop()`,
        // called AFTER `micSource.stop()` inside `MeetingRecorder.stop()`
        // (sequential, not concurrent) — so by the time system audio could
        // still be stuck, the mic tap dictation would contend with is
        // USUALLY already torn down. That is NOT an absolute guarantee,
        // though — a review corrected an earlier version of this comment
        // that overstated it: `MeetingMicSource.stop()` itself calls
        // `AVAudioEngine.stop()`/`removeTap`, a synchronous CoreAudio call
        // that runs first and could in principle wedge too, in which case
        // this flag would release while the mic is still tearing down. A
        // narrower risk than the ScreenCaptureKit case, but real.
        meetingStopInProgress = false

        // Registered synchronously, with zero suspension before it — see
        // `meetingStoppingID`'s doc comment for why this exact ordering
        // (clear the flag, THEN register, both without an intervening
        // `await`) closes the window a concurrent `deleteMeeting` could
        // otherwise land in.
        let task = pipelineRuns.begin(id: id) { [weak self] token in
            await self?.finishStopping(id: id, stopTask: stopTask, token: token)
        }
        meetingStoppingID = nil
        await task.value
    }

    /// The body of the pipeline run `stopMeeting` registers: awaits the
    /// recorder's real result (already raced against a timeout by
    /// `stopMeeting` itself), secures its audio, updates the row to
    /// `.processing`, then runs the full transcribe/diarize/summarize pass —
    /// all under the one run `deleteMeeting` awaits.
    private func finishStopping(
        id: UUID, stopTask: Task<MeetingRecordingResult, Never>, token: UUID
    ) async {
        let result = await stopTask.value

        if let url = result.micURL { await meetingAudioStore.secure(url) }
        if let url = result.systemURL { await meetingAudioStore.secure(url) }

        // Writes the two fields the stop itself owns. Notes typed in the
        // instant between reading the row and writing it back were otherwise
        // lost — the same whole-row overwrite `MeetingStore.update` exists to
        // close, on a much narrower window than the pipeline's.
        let duration = result.durationSeconds
        await meetingStore.update(id: id) { meeting in
            meeting.durationSeconds = duration
            meeting.status = .processing
        }
        NotificationCenter.default.post(name: .wisprMeetingsDidChange, object: nil)

        await runProcessing(id: id, token: token)

        // A track that DIED mid-meeting leaves a file behind, and the
        // pipeline derives its degraded flag purely from track absence — a
        // present file counts as a good track. So the exact case
        // `MeetingRecordingResult` documents (a writer that failed after
        // capturing real audio: the interface unplugged, mic permission
        // revoked, the ScreenCaptureKit stream dropped) produced a
        // `.complete` meeting reading "Ready" whose transcript silently
        // stopped at the moment of death — five minutes of the user's own
        // voice against an hour of everyone else's, with nothing saying so.
        // `micFailed`/`systemFailed` had no production reader at all until
        // here. Only `.complete` is downgraded: `.partial` and `.failed`
        // already tell the truth, and the notice `.partial` shows is exactly
        // right for this ("part of the recording couldn't be processed").
        if result.micFailed || result.systemFailed {
            await meetingStore.update(id: id) { meeting in
                if meeting.status == .complete { meeting.status = .partial }
            }
            WisprLog.log("meeting \(id): a track failed mid-recording "
                + "(mic: \(result.micFailed), system: \(result.systemFailed)); "
                + "transcript marked incomplete")
            NotificationCenter.default.post(name: .wisprMeetingsDidChange, object: nil)
        }
        // N3: this call bypasses the coordinator's own `enforceRetention(
        // maxBytes:maxAgeDays:)` above deliberately — draining `id`'s own
        // run from inside that same run's body (this function IS that
        // run's body) would self-deadlock. It still needs the same
        // exclusion the coordinator method applies, though: without it,
        // this sweep — which runs after EVERY meeting, the common path —
        // could evict a DIFFERENT meeting's audio while that meeting's own
        // pipeline run (e.g. a concurrent Reprocess, which the registry
        // allows per id) is mid-read of it, permanently replacing a good
        // two-sided transcript with one rebuilt from a single track.
        //
        // `id` is NOT subtracted out of `pipelineRuns.activeIDs()` here
        // (round 3, D3 — an earlier version did, reasoning only about `id`'s
        // own just-finished run being safe to sweep). A review found that
        // reasoning stops covering the registry the moment a successor run
        // gets CHAINED onto `id` while this function is still executing —
        // `begin` chains rather than replaces, so `runs[id]` at that point
        // is the successor, a run that hasn't started yet and WILL read
        // this meeting's audio once it does. Subtracting `id` unconditionally
        // stripped that successor's protection right along with the
        // just-finished run's, on the mistaken assumption `runs[id]` could
        // only ever mean the run that just finished. Leaving `id` in the
        // exclusion set costs nothing: eviction is oldest-first, so a
        // meeting whose recording just finished is the least likely
        // candidate for this sweep anyway.
        await meetingAudioStore.enforceRetention(
            maxBytes: settings.meetingRetentionBytes,
            maxAgeDays: settings.meetingRetentionDays,
            excludingMeetingIDs: pipelineRuns.activeIDs())
    }

    func reprocess(meetingID: UUID) async {
        await pipelineRuns.begin(id: meetingID) { [weak self] token in
            await self?.runProcessing(id: meetingID, token: token)
        }.value
    }

    func enhanceNotes(meetingID: UUID) async {
        await pipelineRuns.begin(id: meetingID) { [weak self] token in
            await self?.runEnhanceNotes(id: meetingID, token: token)
        }.value
    }

    /// `MeetingsViewModel.delete(id:)` is pure delegation — it does NOT
    /// touch `MeetingStore` itself. This real implementation owns the row
    /// delete, as well as cancelling and awaiting the drain of any in-flight
    /// `MeetingPipeline` run for this meeting and deleting its audio tracks.
    func deleteMeeting(id: UUID) async {
        // A meeting currently recording, still being set up, or currently
        // being stopped is refused outright — see `meetingSetupID`'s and
        // `meetingStoppingID`'s doc comments for why each needs its own id,
        // separate from `meetingRecordingID`.
        if id == meetingRecordingID {
            showError("Stop the recording before deleting this meeting")
            return
        }
        if id == meetingSetupID {
            showError("This meeting is still starting — try again in a moment")
            return
        }
        if id == meetingStoppingID {
            showError("Still finishing this recording — try again in a moment")
            return
        }
        await drainPipelineRuns(id: id)
        await meetingStore.delete(id: id)
        await meetingAudioStore.delete(id: id)
        NotificationCenter.default.post(name: .wisprMeetingsDidChange, object: nil)
    }

    /// Bulk counterpart to `deleteMeeting`. The brief's original
    /// "Delete All Meetings" wiring called `MeetingStore.deleteAll()` /
    /// `MeetingAudioStore.deleteAll()` straight from `PrivacyPane`, with no
    /// awareness of a meeting currently recording, being set up, or being
    /// stopped — the exact resurrection-race window `deleteMeeting`'s own
    /// guards and drain loop exist to close, just for one meeting instead of
    /// all of them. `meetingRecordingActive` is a single coordinator-wide
    /// flag (not keyed by id), so unlike `deleteMeeting` there's only one
    /// guard to check, not three separate ids — but the effect is the same:
    /// refuse outright, with the same pill language `deleteMeeting` uses for
    /// its own recording-in-progress case, rather than deleting every OTHER
    /// meeting out from under a live one.
    ///
    /// N1 (round 2): an earlier version checked `meetingRecordingActive`
    /// ONCE, up front, then drained every meeting's pipeline run, then
    /// deleted — check-then-act, and the drain WIDENED the gap: the main
    /// actor is free for the entire `await run.task.value` inside
    /// `drainPipelineRuns`. A review found the exact sequence: meeting A
    /// stops and starts transcribing → this method's guard passes (nothing
    /// recording yet) → the drain blocks on A's run → the user starts a NEW
    /// meeting B from the menu bar while blocked → the drain finally returns
    /// → `deleteAll()` wipes B's row and unlinks its still-open audio files
    /// out from under its live recorder — bit-for-bit the outcome this whole
    /// method exists to prevent, just relocated to AFTER the drain instead
    /// of before it.
    ///
    /// The fix loops rather than adding one more re-check: a single re-check
    /// of `meetingRecordingActive` alone would still miss a DIFFERENT
    /// hazard — a meeting that finished recording and is now purely
    /// mid-`MeetingPipeline` run (no longer "recording" by that flag's
    /// definition) but was never drained because it didn't exist yet when
    /// `meetingStore.all()` was first read. Only once a fresh
    /// `meetingRecordingActive` check AND a fresh `meetingStore.all()` read
    /// (compared by id set, not just count) BOTH agree nothing changed since
    /// the drain just completed is it actually safe to call the two
    /// `deleteAll()`s below — any disagreement loops back to drain again
    /// instead of proceeding on a stale snapshot.
    @discardableResult
    func deleteAllMeetings() async -> Bool {
        while true {
            guard !meetingRecordingActive else {
                showError("Stop the recording before deleting all meetings")
                return false
            }
            let before = await meetingStore.all()
            for meeting in before {
                await drainPipelineRuns(id: meeting.id)
            }
            guard !meetingRecordingActive else { continue }
            let after = await meetingStore.all()
            guard Set(after.map(\.id)) == Set(before.map(\.id)) else { continue }
            await meetingStore.deleteAll()
            await meetingAudioStore.deleteAll()
            NotificationCenter.default.post(name: .wisprMeetingsDidChange, object: nil)
            return true
        }
    }

    /// Bulk retention sweep, called from `PrivacyPane` whenever the
    /// retention caps change.
    ///
    /// NOT called from `finishStopping` — a review (N7, round 2) found an
    /// earlier version of this comment claimed it was, which was false and
    /// actively misleading: `finishStopping` calls
    /// `meetingAudioStore.enforceRetention` DIRECTLY (see its own comment),
    /// never through this method, because draining THIS meeting's own
    /// just-finished run from inside that same run's body would
    /// self-deadlock. The two call sites share the same underlying
    /// exclusion logic (`excludingMeetingIDs:`, computed from
    /// `pipelineRuns.activeIDs()` in both places) but are, and must stay,
    /// two separate calls.
    ///
    /// The brief's original wiring called `MeetingAudioStore.enforceRetention`
    /// directly from `PrivacyPane` itself, which can delete an in-flight
    /// `MeetingPipeline` run's audio out from under it — `MeetingPipeline
    /// .process` reads `existingMicURL`/`existingSystemURL` at each
    /// checkpoint, not just once at the start (see C2's fix in
    /// `MeetingPipeline`).
    ///
    /// A round-1 fix routed this through a drain (cancel every in-flight
    /// run, await it, THEN sweep) — the same shape `deleteMeeting`/
    /// `deleteAllMeetings` use. A round-2 review (N2/N3) rejected that here:
    /// unlike a delete, changing a retention cap is not supposed to be
    /// destructive at all, and draining made it so — raising "Keep at most"
    /// from 5 GB to 10 GB, a strictly non-destructive intent, cancelled
    /// whatever meeting happened to be transcribing at that moment,
    /// truncating its transcript. It was also architecturally impossible to
    /// apply from `finishStopping`: draining THIS meeting's own
    /// just-finished run from inside that same run's body self-deadlocks.
    ///
    /// The fix that actually satisfies the hazard I3 named — "don't delete a
    /// file a run is currently reading" — is EXCLUSION, not cancellation:
    /// any meeting with a currently-registered pipeline run is simply left
    /// out of this sweep pass, survives unevicted regardless of age/size,
    /// and gets swept the next time retention runs once its run clears. No
    /// drain, no cancellation, no self-deadlock, and widening a cap can
    /// never truncate a live transcription again.
    func enforceRetention(maxBytes: Int64, maxAgeDays: Int) async {
        await meetingAudioStore.enforceRetention(
            maxBytes: maxBytes, maxAgeDays: maxAgeDays,
            excludingMeetingIDs: pipelineRuns.activeIDs())
    }

    /// Cancels and awaits the drain of whatever `PipelineRunRegistry` chain
    /// is currently registered for `id`, leaving nothing registered when it
    /// returns. Shared by `deleteMeeting`, `deleteAllMeetings`, and
    /// `enforceRetention` — see `deleteMeeting`'s original comment (still
    /// accurate here) for why this must be a loop that re-reads the
    /// registry after every await, not a single snapshot-then-await: `begin`
    /// chains a new run onto whatever is already registered rather than
    /// dropping it, and the main actor is free while this awaits `run.task`
    /// below, so a fresh, legitimate run can register for `id` in that exact
    /// window.
    private func drainPipelineRuns(id: UUID) async {
        while let run = pipelineRuns.run(for: id) {
            await pipelineRuns.requestCancel(id: id, token: run.token)
            await run.task.value
            pipelineRuns.clear(id: id, token: run.token)
        }
    }

    func register(model: MeetingsViewModel) {
        meetingsModel = model
        model.syncRecording(id: meetingRecordingID)
        if let failure = pendingMenuStartFailure {
            pendingMenuStartFailure = nil
            model.applyStartFailure(failure)
        }
    }

    /// Runs a full `process()` pass (used by both `stopMeeting`, via
    /// `finishStopping`, and `reprocess`), publishing the pipeline instance
    /// under `token` so `deleteMeeting` can find and cancel it.
    private func runProcessing(id: UUID, token: UUID) async {
        var diarizer: any MeetingDiarizing = meetingDiarizer
        do {
            try await meetingDiarizer.warmUp()
        } catch {
            WisprLog.log("meeting process: diarizer unavailable, continuing without: \(error)")
            diarizer = NullDiarizer()
        }
        let pipeline = pipelineFactory(diarizer)
        await pipelineRuns.attachPipeline(id: id, token: token, pipeline: pipeline)
        _ = await pipeline.process(
            meetingID: id,
            progress: { [weak self] progress in
                Task { @MainActor in self?.meetingsModel?.updateProgress(progress) }
            })
        meetingsModel?.updateProgress(nil)
        NotificationCenter.default.post(name: .wisprMeetingsDidChange, object: nil)
    }

    /// `enhanceNotes` has no cancellation concept of its own, so there is no
    /// pipeline instance for `deleteMeeting` to cancel here — only the task
    /// to await, which `pipelineRuns.begin` already tracks.
    private func runEnhanceNotes(id: UUID, token: UUID) async {
        _ = await pipelineFactory(meetingDiarizer).enhanceNotes(meetingID: id)
        NotificationCenter.default.post(name: .wisprMeetingsDidChange, object: nil)
    }

    /// Starts `recorder`, giving up after `Self.screenCaptureTimeoutSeconds`
    /// rather than blocking indefinitely.
    ///
    /// `MeetingRecorder.start()` brings the mic track up FIRST and the
    /// system-audio track second, so the realistic wedge (ScreenCaptureKit /
    /// `replayd`) can leave a live mic tap running even after this function
    /// has given up waiting. Forcing `recorder.stop()` here — now itself
    /// bounded the same way, per a review's "while you are there" note,
    /// since it was previously the one unbounded call left in this whole
    /// path, asymmetric with `stopMeeting`'s own bounded teardown — tears
    /// down whatever DID come up immediately, unconditionally, rather than
    /// leaving it to a maybe-never callback. Safe to call while `start()` is
    /// still genuinely in flight: `SystemAudioSource`/`MeetingMicSource`'s
    /// epoch-based claim/commit scheme exists specifically so a `stop()`
    /// landing before an in-flight `start()` commits forces that `start()`
    /// to tear down whatever it goes on to create, instead of leaking it.
    private func startRecorderBounded(_ recorder: any MeetingRecording, id: UUID) async -> Bool {
        let startTask = Task<Bool, Never> {
            do {
                try await recorder.start()
                return true
            } catch {
                WisprLog.log("meeting start: recorder FAILED: \(error)")
                return false
            }
        }
        switch await AppController.withTimeout(
            seconds: Self.screenCaptureTimeoutSeconds,
            operation: { await startTask.value }
        ) {
        case .completed(let started):
            return started
        case .timedOut:
            WisprLog.log("meeting start: recorder.start() exceeded "
                + "\(Self.screenCaptureTimeoutSeconds)s — forcing it down before "
                + "releasing the setup guard")
            let forcedStopTask = Task<MeetingRecordingResult, Never> { await recorder.stop() }
            switch await AppController.withTimeout(
                seconds: Self.screenCaptureTimeoutSeconds,
                operation: { await forcedStopTask.value }
            ) {
            case .completed:
                break
            case .timedOut:
                WisprLog.log("meeting start: recorder.stop() (forced after a start "
                    + "timeout) ALSO exceeded \(Self.screenCaptureTimeoutSeconds)s — "
                    + "releasing the setup guard anyway; still waiting for it to "
                    + "actually finish in the background")
            }
            return false
        }
    }

    private func startMeetingTimer() {
        meetingTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.meetingRecorder else { return }
                let elapsed = await recorder.elapsedSeconds
                self.meetingsModel?.updateElapsed(elapsed)
                if await recorder.reachedDurationCap {
                    WisprLog.log("meeting: duration cap reached, stopping")
                    await self.stopMeeting()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meetingTimer = timer
    }

    private func stopMeetingTimer() {
        meetingTimer?.invalidate()
        meetingTimer = nil
    }
}

extension MeetingsCoordinatorImpl: MeetingsCoordinating {}

// MARK: - PipelineRunRegistry

/// Chains concurrent pipeline runs (`process`/`reprocess`/`enhanceNotes`) per
/// meeting id — never more than one touches a given row at a time — and
/// tracks each one under a token so a stale run's own completion can never
/// erase a newer run's registration.
///
/// Extracted out of `AppController` as its own type specifically so this
/// bookkeeping can be unit tested directly — a review found a real bug here
/// that no test had caught: with two independent dictionaries and no
/// coalescing, a second call for the same id registered a second, competing
/// task under the same key, and whichever run finished first unconditionally
/// wiped both entries in its own `defer`.
///
/// `begin` was originally fixed by coalescing — a second call for an id
/// already in flight got back the existing task UNCHANGED, its own `body`
/// never invoked at all. A second review found that traded one bug for a
/// worse one: if `stopMeeting` landed while an unrelated `enhanceNotes` run
/// for the same id was in flight, coalescing meant `stopMeeting`'s own body
/// NEVER RAN. Chaining — every call's `body` is guaranteed to run
/// eventually, in order — keeps the one-run-at-a-time invariant without
/// ever silently dropping an operation.
///
/// `Run` is a class, not a struct, with a `previous` link forming the whole
/// chain rather than just the tail. A third review found chaining had
/// quietly regressed cancellation reach relative to the coalescing version:
/// `begin` used to (as a struct) unconditionally overwrite `runs[id]`,
/// discarding the predecessor's `Run` INCLUDING its `pipeline` reference.
/// Concretely: Reprocess (pipeline attached, transcribing) → Tidy up notes
/// (registers, chained; predecessor's pipeline handle dropped) → Delete —
/// the delete could only reach the TAIL run (nothing to cancel yet), await
/// it, which awaits the transcribe, which then ran UNCANCELLED to
/// completion. `requestCancel` now walks the whole `previous` chain,
/// cancelling every already-attached pipeline along it, not just the tail's.
@MainActor
final class PipelineRunRegistry {
    /// A registered pipeline run: the token identifying it as current, the
    /// wrapping task `deleteMeeting` awaits, the `MeetingPipeline` instance
    /// (once one exists) `deleteMeeting` cancels, and the run it was chained
    /// after, if any (see the type's doc comment for why this matters).
    final class Run {
        let token: UUID
        let task: Task<Void, Never>
        var pipeline: MeetingPipeline?
        /// True once `deleteMeeting` has requested cancellation of this run.
        /// Checked by `attachPipeline` so a pipeline that doesn't exist yet
        /// at the moment cancellation is requested is still cancelled the
        /// instant it shows up, rather than running to completion
        /// unobserved.
        var cancelRequested = false
        let previous: Run?

        init(token: UUID, task: Task<Void, Never>, previous: Run?) {
            self.token = token
            self.task = task
            self.previous = previous
        }
    }

    private var runs: [UUID: Run] = [:]

    init() {}

    /// The currently-registered run for `id`, if any.
    func run(for id: UUID) -> Run? { runs[id] }

    /// Every meeting id with a currently-registered run. Used by
    /// `MeetingsCoordinatorImpl.enforceRetention`/`finishStopping` (N2/N3)
    /// to EXCLUDE a busy meeting's audio from a retention sweep rather than
    /// cancelling its run to make way for one — see those call sites' doc
    /// comments for why exclusion, not cancellation, is the fix.
    func activeIDs() -> Set<UUID> { Set(runs.keys) }

    /// Registers a run for `id`. If one is already registered, `body` is
    /// CHAINED after it — the returned task awaits the existing run's task
    /// to completion before invoking `body` — rather than running
    /// concurrently against the same meeting row.
    @discardableResult
    func begin(id: UUID, _ body: @escaping (UUID) async -> Void) -> Task<Void, Never> {
        let token = UUID()
        let previous = runs[id]
        let task = Task { [weak self] in
            if let previous { await previous.task.value }
            await body(token)
            self?.clear(id: id, token: token)
        }
        runs[id] = Run(token: token, task: task, previous: previous)
        return task
    }

    /// The run registered under `token`, found ANYWHERE along the chain for
    /// `id` — not just at its tail. See `attachPipeline` for why the
    /// distinction is load-bearing.
    private func run(for id: UUID, token: UUID) -> Run? {
        var candidate = runs[id]
        while let run = candidate {
            if run.token == token { return run }
            candidate = run.previous
        }
        return nil
    }

    /// Publishes the `MeetingPipeline` instance a run built, so
    /// `deleteMeeting` can cancel it. If cancellation was already requested
    /// for this run before the pipeline existed, the newly-attached
    /// pipeline is cancelled immediately instead of being left to run to
    /// completion unobserved.
    ///
    /// The run is located by walking the `previous` chain, NOT by requiring
    /// `token` to match the tail. A fourth review found requiring the tail
    /// silently dropped the pipeline in a window wider than the one
    /// `requestCancel`'s chain walk closed: `runProcessing` awaits
    /// `meetingDiarizer.warmUp()` — a multi-second FluidAudio model load —
    /// BEFORE calling this, so a run only has to be mid-warm-up when a
    /// successor registers for the same id (Reprocess, then "Tidy up my
    /// notes" while the models are still loading) for its own attach to
    /// arrive after it has stopped being the tail. Storing nothing there
    /// means a later `deleteMeeting` walks the chain, finds
    /// `run.pipeline == nil`, and cancels nothing — the predecessor
    /// transcribes and summarizes to completion uncancelled while the delete
    /// blocks on it. Cancellation reach and the tail's identity are simply
    /// unrelated: the token is what identifies the run, and it is unique.
    func attachPipeline(id: UUID, token: UUID, pipeline: MeetingPipeline) async {
        guard let run = run(for: id, token: token) else { return }
        run.pipeline = pipeline
        if run.cancelRequested {
            await pipeline.cancel()
        }
    }

    /// Requests cancellation of the run registered under `token` — cancels
    /// its pipeline now if one is already attached, marks the request so a
    /// pipeline that attaches later is cancelled the moment it shows up, AND
    /// walks backward through every run still reachable via `previous`,
    /// doing the same for each — see the type's doc comment for the
    /// cancellation-reach regression this closes. No-ops if `token` is
    /// stale (a newer run has already replaced this one).
    func requestCancel(id: UUID, token: UUID) async {
        guard var run = runs[id], run.token == token else { return }
        while true {
            run.cancelRequested = true
            if let pipeline = run.pipeline {
                await pipeline.cancel()
            }
            guard let previous = run.previous else { break }
            run = previous
        }
    }

    /// Clears the registration for `id`, but only if `token` still matches
    /// — an earlier-registered run finishing after a later one has already
    /// replaced it must not erase the later run's entry.
    func clear(id: UUID, token: UUID) {
        guard runs[id]?.token == token else { return }
        runs[id] = nil
    }
}
