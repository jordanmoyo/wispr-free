import XCTest
@testable import WisprCore

@MainActor
private final class StubCoordinator: MeetingsCoordinating {
    var startResult: Result<UUID, MeetingStartFailure> = .success(UUID())
    private let store: MeetingStore
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var reprocessed: [UUID] = []
    private(set) var enhanced: [UUID] = []
    private(set) var deleted: [UUID] = []

    init(store: MeetingStore) {
        self.store = store
    }

    func startMeeting() async -> Result<UUID, MeetingStartFailure> {
        startCount += 1
        // A real coordinator's `startMeeting()` always suspends (permission
        // checks, recorder setup). Forcing a genuine suspension here too —
        // rather than returning synchronously — is what lets the
        // double-start race test actually exercise the race instead of the
        // two calls trivially running one after the other.
        await Task.yield()
        return startResult
    }
    /// Lets a test park `stopMeeting()` mid-flight, the way the real one
    /// parks on `recorder.stop()`. Without a genuine suspension here there
    /// is no window in which a second Stop can land while the first is still
    /// running — which is exactly the state whose message a review found
    /// wrong.
    var stopGate: (@Sendable () async -> Void)?

    func stopMeeting() async {
        stopCount += 1
        await stopGate?()
    }
    func reprocess(meetingID: UUID) async { reprocessed.append(meetingID) }
    func enhanceNotes(meetingID: UUID) async { enhanced.append(meetingID) }
    /// Real `AppController.deleteMeeting` owns the store row delete (see the
    /// `// Task 16` note there); this stub does the same against the
    /// shared `store` so the test validates the true contract —
    /// `MeetingsViewModel.delete` is pure delegation and does NOT touch
    /// `store` itself.
    func deleteMeeting(id: UUID) async {
        await store.delete(id: id)
        deleted.append(id)
    }
    // `deleteAllMeetings`/`enforceRetention` below exist ONLY to satisfy
    // `MeetingsCoordinating` conformance, deliberately without call-tracking
    // fields (round 3, N6 review correction): `MeetingsViewModel` never
    // calls either of these — `PrivacyPane` calls `context.meetingsCoordinator
    // .deleteAllMeetings()`/`.enforceRetention(...)` directly, bypassing the
    // view model entirely. A round-2 report claimed `deletedAllCount`/
    // `enforcedRetention` tracking fields here were "coverage" for that
    // return-value plumbing; a round-3 review found nothing in this file
    // ever set or asserted them — dead scaffolding masquerading as a test.
    // The real `PrivacyPane` guard (N6) has no automated coverage at all,
    // for the same SwiftUI-testing-infrastructure reason already disclosed
    // for other view-level fixes in this feature; removing the fields that
    // implied otherwise rather than leaving them to mislead the next reader.
    func deleteAllMeetings() async -> Bool { true }
    func enforceRetention(maxBytes: Int64, maxAgeDays: Int) async {}
    func register(model: MeetingsViewModel) {}
}

/// Always-empty audio locator for tests that don't care about playback —
/// the default so every existing `makeModel()` call site didn't need to
/// change when `MeetingsViewModel` grew this dependency.
private struct NullAudioLocator: MeetingAudioLocating {
    func existingMicURL(for id: UUID) async -> URL? { nil }
    func existingSystemURL(for id: UUID) async -> URL? { nil }
}

/// A locator whose lookup for one specific id genuinely suspends (several
/// `Task.yield()`s) before returning, so a test can force "a fast lookup for
/// a different id finishes first" — the interleaving that makes the stale
/// selection guard in `loadAudioURLs` worth having. A real `MeetingAudioStore`
/// call has no delay knob to make that deterministic.
private final class DelayedAudioLocator: MeetingAudioLocating {
    private let urls: [UUID: URL]
    private let slowID: UUID

    init(urls: [UUID: URL], slowID: UUID) {
        self.urls = urls
        self.slowID = slowID
    }

    func existingMicURL(for id: UUID) async -> URL? {
        if id == slowID {
            for _ in 0..<5 { await Task.yield() }
        }
        return urls[id]
    }

    func existingSystemURL(for id: UUID) async -> URL? { nil }
}

/// One-shot async rendezvous: `wait()` suspends until `fire()` is called, or
/// returns immediately if `fire()` already happened. (Reimplemented here
/// rather than shared with the identically-shaped `RaceSignal`/
/// `CoordinatorRaceSignal` in the other meetings test files, since those are
/// private to them.)
private actor ViewModelRaceSignal {
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

@MainActor
final class MeetingsViewModelTests: XCTestCase {
    private func makeModel(audioStore: any MeetingAudioLocating = NullAudioLocator())
        -> (MeetingsViewModel, MeetingStore, StubCoordinator) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-\(UUID().uuidString)")
        let store = MeetingStore(directoryURL: dir)
        let coordinator = StubCoordinator(store: store)
        let model = MeetingsViewModel(store: store, coordinator: coordinator,
                                      audioStore: audioStore)
        return (model, store, coordinator)
    }

    // MARK: labels

    func testElapsedLabelUnderAnHour() {
        XCTAssertEqual(MeetingsViewModel.elapsedLabel(0), "0:00")
        XCTAssertEqual(MeetingsViewModel.elapsedLabel(9), "0:09")
        XCTAssertEqual(MeetingsViewModel.elapsedLabel(724), "12:04")
    }

    func testElapsedLabelOverAnHour() {
        XCTAssertEqual(MeetingsViewModel.elapsedLabel(3753), "1:02:33")
        XCTAssertEqual(MeetingsViewModel.elapsedLabel(36_000), "10:00:00")
    }

    func testElapsedLabelHandlesNegativeAsZero() {
        XCTAssertEqual(MeetingsViewModel.elapsedLabel(-5), "0:00")
    }

    /// `Int(.infinity)` is a fatal trap; `elapsedLabel` must guard it rather
    /// than let a runaway or unset duration kill the process.
    func testElapsedLabelHandlesInfinityAsZero() {
        XCTAssertEqual(MeetingsViewModel.elapsedLabel(.infinity), "0:00")
        XCTAssertEqual(MeetingsViewModel.elapsedLabel(-.infinity), "0:00")
    }

    func testStatusLabelsAreDistinctAndNonEmpty() {
        let labels = [MeetingStatus.recording, .processing, .complete, .partial, .failed]
            .map(MeetingsViewModel.statusLabel)
        XCTAssertEqual(Set(labels).count, 5)
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })
    }

    // MARK: load

    func testLoadPopulatesNewestFirst() async {
        let (model, store, _) = makeModel()
        await store.upsert(Meeting(title: "Old",
                                   startedAt: Date(timeIntervalSince1970: 100)))
        await store.upsert(Meeting(title: "New",
                                   startedAt: Date(timeIntervalSince1970: 200)))
        await model.load()
        XCTAssertEqual(model.meetings.map(\.title), ["New", "Old"])
    }

    func testLoadOnEmptyStoreYieldsEmptyList() async {
        let (model, _, _) = makeModel()
        await model.load()
        XCTAssertTrue(model.meetings.isEmpty)
        XCTAssertNil(model.selection)
    }

    /// `MeetingStore` posts `.wisprMeetingsDidChange` on every mutation, and
    /// `MeetingsViewModel` observes it itself (not just the view) — the case
    /// this exists for is a background `MeetingPipeline` run finishing while
    /// the pane is open, which never calls through this view model at all.
    func testStoreMutationOutsideViewModelStillRefreshesIt() async {
        let (model, store, _) = makeModel()
        await model.load()
        XCTAssertTrue(model.meetings.isEmpty)

        let meeting = Meeting(title: "External", startedAt: Date())
        await store.upsert(meeting)

        // notifyChanged() posts via `Task { @MainActor in ... }`, so give
        // that task a turn on the main actor before asserting.
        for _ in 0..<20 where model.meetings.isEmpty {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.meetings.map(\.title), ["External"])
    }

    // MARK: recording

    func testStartRecordingSetsRecordingIDAndSelectsIt() async {
        let (model, store, coordinator) = makeModel()
        let id = UUID()
        coordinator.startResult = .success(id)
        await store.upsert(Meeting(id: id, title: "Live", startedAt: Date(),
                                   status: .recording))
        await model.startRecording()
        XCTAssertEqual(model.recordingID, id)
        XCTAssertEqual(model.selection, id)
        XCTAssertNil(model.banner)
    }

    func testStartRecordingShowsBannerOnScreenRecordingDenial() async {
        let (model, _, coordinator) = makeModel()
        coordinator.startResult = .failure(.screenRecordingDenied)
        await model.startRecording()
        XCTAssertNil(model.recordingID)
        XCTAssertTrue(model.permissionMissing)
        XCTAssertEqual(model.banner, MeetingStartFailure.screenRecordingDenied.userMessage)
    }

    func testStartRecordingShowsBannerWhenDictationBusy() async {
        let (model, _, coordinator) = makeModel()
        coordinator.startResult = .failure(.dictationInProgress)
        await model.startRecording()
        XCTAssertNil(model.recordingID)
        XCTAssertFalse(model.permissionMissing)
        XCTAssertEqual(model.banner, MeetingStartFailure.dictationInProgress.userMessage)
    }

    func testStartRecordingWhileRecordingIsIgnored() async {
        let (model, store, coordinator) = makeModel()
        let id = UUID()
        coordinator.startResult = .success(id)
        await store.upsert(Meeting(id: id, title: "Live", startedAt: Date()))
        await model.startRecording()
        coordinator.startResult = .success(UUID())
        await model.startRecording()
        XCTAssertEqual(model.recordingID, id)   // unchanged
    }

    /// Two genuinely concurrent `startRecording()` calls (an `async let`
    /// pair, not two sequential `await`s) must still only ever call the
    /// coordinator once. `recordingID` alone can't gate this: it isn't
    /// assigned until `coordinator.startMeeting()` returns, so without an
    /// in-flight guard set *before* that suspension, both calls observe
    /// `recordingID == nil` and both start a session.
    func testConcurrentStartRecordingCallsCoordinatorOnce() async {
        let (model, _, coordinator) = makeModel()
        let id = UUID()
        coordinator.startResult = .success(id)

        async let first: Void = model.startRecording()
        async let second: Void = model.startRecording()
        _ = await (first, second)

        XCTAssertEqual(coordinator.startCount, 1)
        XCTAssertEqual(model.recordingID, id)
    }

    func testStopRecordingClearsRecordingState() async {
        let (model, store, coordinator) = makeModel()
        let id = UUID()
        coordinator.startResult = .success(id)
        await store.upsert(Meeting(id: id, title: "Live", startedAt: Date()))
        await model.startRecording()
        await model.stopRecording()
        XCTAssertNil(model.recordingID)
        XCTAssertEqual(model.elapsedSeconds, 0)
        XCTAssertEqual(coordinator.stopCount, 1)
    }

    /// A review found this used to silently no-op with no feedback at all —
    /// reachable from the setup window, where the menu bar already labels
    /// the item "Stop Meeting" (`meetingRecordingActive` covers setup too)
    /// but `recordingID` isn't assigned yet. Now it surfaces a banner
    /// instead of doing nothing.
    func testStopRecordingWhenNotRecordingShowsABannerInsteadOfSilentlyNoOpping() async {
        let (model, _, coordinator) = makeModel()
        await model.stopRecording()
        XCTAssertEqual(coordinator.stopCount, 0)
        XCTAssertEqual(model.banner, "This meeting is still starting — try again in a moment")
    }

    /// The same guard, reached from the OTHER transition window. Both
    /// windows leave `recordingID == nil` while the menu bar still says
    /// "Stop Meeting" (`meetingRecordingActive` covers teardown too), so
    /// before `stopInFlight` existed this branch told the user the meeting
    /// was "still starting" while it was in fact stopping — a review caught
    /// it as a regression introduced by making the stop window blocking.
    ///
    /// Reverting `stopRecording()`'s banner to the unconditional
    /// "still starting" string fails on the message, not on a hang.
    func testStopRecordingWhileAStopIsAlreadyInFlightReportsStoppingNotStarting() async {
        let (model, store, coordinator) = makeModel()
        let id = UUID()
        coordinator.startResult = .success(id)
        await store.upsert(Meeting(id: id, title: "Live", startedAt: Date()))
        await model.startRecording()

        let stopArrived = ViewModelRaceSignal()
        let releaseStop = ViewModelRaceSignal()
        coordinator.stopGate = {
            await stopArrived.fire()
            await releaseStop.wait()
        }

        let firstStop = Task { await model.stopRecording() }
        await stopArrived.wait()   // the first stop is now genuinely parked

        // The second click — from the menu bar, which still reads
        // "Stop Meeting" for the whole teardown.
        await model.stopRecording()
        XCTAssertEqual(model.banner, MeetingsViewModel.stillStoppingMessage,
            "a Stop landing during a teardown must say the meeting is stopping — "
                + "saying \"still starting\" describes the opposite transition")
        XCTAssertEqual(coordinator.stopCount, 1,
            "the second click must not reach the coordinator a second time")

        await releaseStop.fire()
        await firstStop.value
    }

    func testDismissBannerClearsIt() async {
        let (model, _, coordinator) = makeModel()
        coordinator.startResult = .failure(.micDenied)
        await model.startRecording()
        XCTAssertNotNil(model.banner)
        model.dismissBanner()
        XCTAssertNil(model.banner)
    }

    // MARK: editing

    /// `status` is explicit rather than defaulted here: `Meeting.init`
    /// defaults to `.recording`, and `saveNotes` deliberately withholds the
    /// LLM run for a live meeting (see the recording-case test below). A
    /// finished meeting is the state this path actually describes.
    func testSaveNotesPersistsAndTriggersEnhancement() async {
        let (model, store, coordinator) = makeModel()
        let meeting = Meeting(title: "T", startedAt: Date(), status: .complete)
        await store.upsert(meeting)
        await model.load()
        await model.saveNotes("my notes", for: meeting.id)
        let persisted = await store.meeting(id: meeting.id)
        XCTAssertEqual(persisted?.userNotes, "my notes")
        XCTAssertEqual(coordinator.enhanced, [meeting.id])
    }

    /// The root-cause half of the stop-during-enhance class of bugs: an
    /// `enhanceNotes` run registers a pipeline run for the meeting's id, and
    /// `stopMeeting()`'s own store/audio work legitimately chains behind
    /// whatever is already registered — so a tidy-up started mid-meeting is
    /// what makes the pane's Stop button wait out a full local LLM
    /// generation. Notes typed during a meeting must still SAVE (that is the
    /// whole point of the field, and this is the only path that persists
    /// them); only the LLM run is withheld until the meeting is over.
    ///
    /// Removing the `meeting.status != .recording` guard from `saveNotes`
    /// fails the second assertion.
    func testSaveNotesDuringARecordingSavesButDoesNotStartAnLLMRun() async {
        let (model, store, coordinator) = makeModel()
        let meeting = Meeting(title: "Live", startedAt: Date(), status: .recording)
        await store.upsert(meeting)
        await model.load()

        await model.saveNotes("typed while the meeting is running", for: meeting.id)

        let persisted = await store.meeting(id: meeting.id)
        XCTAssertEqual(persisted?.userNotes, "typed while the meeting is running",
            "notes typed during a live meeting must still be saved")
        XCTAssertTrue(coordinator.enhanced.isEmpty,
            "no LLM run may be started while the meeting is still recording — it "
                + "registers a pipeline run for this id that a subsequent Stop "
                + "would then have to wait out")
    }

    /// `.complete`, not the `.recording` default, so this still fails for
    /// the reason it names — blank notes — rather than passing incidentally
    /// off `saveNotes`' live-meeting guard.
    func testSaveEmptyNotesDoesNotTriggerEnhancement() async {
        let (model, store, coordinator) = makeModel()
        let meeting = Meeting(title: "T", startedAt: Date(), status: .complete)
        await store.upsert(meeting)
        await model.load()
        await model.saveNotes("   ", for: meeting.id)
        XCTAssertTrue(coordinator.enhanced.isEmpty)
    }

    func testRenameSpeakerPersists() async {
        let (model, store, _) = makeModel()
        let meeting = Meeting(title: "T", startedAt: Date())
        await store.upsert(meeting)
        await model.load()
        await model.rename(speaker: "1", to: "Marie", in: meeting.id)
        let persisted = await store.meeting(id: meeting.id)
        XCTAssertEqual(persisted?.speakerNames["1"], "Marie")
        XCTAssertEqual(model.meetings.first?.speakerNames["1"], "Marie")
    }

    func testRenameSpeakerToBlankRemovesTheName() async {
        let (model, store, _) = makeModel()
        var meeting = Meeting(title: "T", startedAt: Date())
        meeting.speakerNames = ["1": "Marie"]
        await store.upsert(meeting)
        await model.load()
        await model.rename(speaker: "1", to: "  ", in: meeting.id)
        let persisted = await store.meeting(id: meeting.id)
        XCTAssertNil(persisted?.speakerNames["1"])
    }

    func testRenameMeetingPersistsAndIgnoresBlank() async {
        let (model, store, _) = makeModel()
        let meeting = Meeting(title: "Original", startedAt: Date())
        await store.upsert(meeting)
        await model.load()
        await model.renameMeeting(meeting.id, to: "Renamed")
        let renamed = await store.meeting(id: meeting.id)
        XCTAssertEqual(renamed?.title, "Renamed")
        await model.renameMeeting(meeting.id, to: "   ")
        let stillRenamed = await store.meeting(id: meeting.id)
        XCTAssertEqual(stillRenamed?.title, "Renamed")
    }

    func testDeleteRemovesFromListAndClearsSelection() async {
        let (model, store, coordinator) = makeModel()
        let meeting = Meeting(title: "T", startedAt: Date())
        await store.upsert(meeting)
        await model.load()
        model.select(meeting.id)
        await model.delete(id: meeting.id)
        XCTAssertTrue(model.meetings.isEmpty)
        XCTAssertNil(model.selection)
        XCTAssertEqual(coordinator.deleted, [meeting.id])
    }

    func testSelectedMeetingReflectsSelection() async {
        let (model, store, _) = makeModel()
        let meeting = Meeting(title: "T", startedAt: Date())
        await store.upsert(meeting)
        await model.load()
        XCTAssertNil(model.selectedMeeting)
        model.select(meeting.id)
        XCTAssertEqual(model.selectedMeeting?.title, "T")
        model.select(nil)
        XCTAssertNil(model.selectedMeeting)
    }

    /// Reproduces "the switch lands mid-flight": a lookup for the
    /// originally-selected meeting is still in flight (two actor-style hops
    /// deep) when the user selects a different meeting, whose own lookup
    /// then resolves first. The stale result for the first meeting must be
    /// discarded on arrival rather than clobbering `audioURLs` with the
    /// wrong meeting's tracks.
    func testLoadAudioURLsDiscardsStaleResultAfterSelectionMovesOn() async {
        let idA = UUID()
        let idB = UUID()
        let urlA = URL(fileURLWithPath: "/tmp/a-mic.m4a")
        let urlB = URL(fileURLWithPath: "/tmp/b-mic.m4a")
        let locator = DelayedAudioLocator(urls: [idA: urlA, idB: urlB], slowID: idA)
        let (model, store, _) = makeModel(audioStore: locator)
        await store.upsert(Meeting(id: idA, title: "A", startedAt: Date()))
        await store.upsert(Meeting(id: idB, title: "B", startedAt: Date()))
        await model.load()
        model.select(idA)

        async let staleLoad: Void = model.loadAudioURLs(for: idA)
        // Give the slow lookup for A a chance to start and suspend inside
        // its yield loop before switching selection out from under it.
        await Task.yield()
        model.select(idB)
        // B has no artificial delay, so this resolves and writes before the
        // stale A lookup gets another turn.
        await model.loadAudioURLs(for: idB)
        XCTAssertEqual(model.audioURLs.mic, urlB)

        // Now let the stale A lookup finish; its guard must see that
        // selection has moved on and discard the result rather than
        // overwrite audioURLs with A's (wrong) track.
        _ = await staleLoad
        XCTAssertEqual(model.audioURLs.mic, urlB)
    }

    func testReprocessDelegatesToCoordinator() async {
        let (model, store, coordinator) = makeModel()
        let meeting = Meeting(title: "T", startedAt: Date(), status: .failed)
        await store.upsert(meeting)
        await model.load()
        await model.reprocess(id: meeting.id)
        XCTAssertEqual(coordinator.reprocessed, [meeting.id])
    }

    func testStartFailureMessagesAreDistinctAndNonEmpty() {
        let messages: [String] = [
            MeetingStartFailure.screenRecordingDenied,
            .dictationInProgress, .micDenied, .bothTracksFailed, .meetingStopping,
        ].map(\.userMessage)
        XCTAssertEqual(Set(messages).count, 5)
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
        XCTAssertTrue(
            MeetingStartFailure.screenRecordingDenied.userMessage.contains("Screen Recording"))
    }
}
