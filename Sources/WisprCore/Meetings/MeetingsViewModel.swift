import Foundation

public extension Notification.Name {
    /// Posted whenever a meeting is created, updated, or deleted, so an open
    /// Meetings pane refreshes. Mirrors `.wisprHistoryDidChange`.
    static let wisprMeetingsDidChange = Notification.Name("wisprMeetingsDidChange")
}

public enum MeetingStartFailure: Error, Equatable {
    case screenRecordingDenied
    /// Screen Recording is granted, but ScreenCaptureKit would not answer.
    /// Kept distinct from `.screenRecordingDenied` because the fix is
    /// different: sending someone to a Settings pane where Wispr Free is
    /// already ticked leaves them toggling a switch that was never the
    /// problem.
    case screenCaptureUnavailable
    case dictationInProgress
    case micDenied
    case bothTracksFailed
    /// The previous meeting is still being stopped (its recorder is
    /// finalizing audio, its row is mid-update) — starting a new one now
    /// would race that teardown. Distinct from `.dictationInProgress`:
    /// nothing to finish on the user's end, just a moment to wait out.
    case meetingStopping

    public var userMessage: String {
        switch self {
        case .screenRecordingDenied:
            return "Wispr needs Screen Recording permission to hear the other "
                + "participants. Open System Settings › Privacy & Security › "
                + "Screen Recording, enable Wispr Free, then start again."
        case .screenCaptureUnavailable:
            return "macOS would not start screen capture, even though Wispr "
                + "Free has permission. This usually clears after quitting "
                + "and reopening Wispr Free; if macOS asks for Screen "
                + "Recording again after an update, approve it once more."
        case .dictationInProgress:
            return "Finish the dictation in progress before starting a meeting."
        case .micDenied:
            return "Wispr needs Microphone permission to record your side of "
                + "the meeting. Enable it in System Settings › Privacy & "
                + "Security › Microphone."
        case .bothTracksFailed:
            return "Neither the microphone nor system audio could be captured, "
                + "so there was nothing to record."
        case .meetingStopping:
            return "Still finishing the previous meeting — try again in a moment."
        }
    }
}

/// The seam between the Meetings UI and `AppController`, which owns the
/// recorder, the models, and the dictation phase machine. The view model
/// talks only to this, so its whole surface is testable with a stub.
public protocol MeetingsCoordinating: AnyObject, Sendable {
    func startMeeting() async -> Result<UUID, MeetingStartFailure>
    func stopMeeting() async
    func reprocess(meetingID: UUID) async
    func enhanceNotes(meetingID: UUID) async
    func deleteMeeting(id: UUID) async
    /// Bulk counterpart to `deleteMeeting`: refuses outright (with the same
    /// pill language) while any meeting is actively recording, being set up,
    /// or being stopped, and drains every meeting's in-flight pipeline run
    /// before wiping the store — the same resurrection-race guard
    /// `deleteMeeting` already applies to a single meeting, widened to all of
    /// them. Added so `PrivacyPane`'s "Delete All Meetings…"/"Delete All
    /// Data…" no longer call `MeetingStore`/`MeetingAudioStore` directly and
    /// bypass that guard entirely.
    ///
    /// Returns `true` if it actually deleted everything, `false` if it
    /// refused (busy). A round-2 review (N6) found "Delete All Data…" acted
    /// on this call's SIDE EFFECT (the pill) while ignoring whether it
    /// actually succeeded, so a refusal here still went on to delete
    /// history/corrections/the dictation archive — a partial delete the
    /// user was never told about, from an alert that promised to delete
    /// everything. The boolean return is what lets a caller check-before-
    /// acting-on-the-rest instead.
    @discardableResult
    func deleteAllMeetings() async -> Bool
    /// Bulk retention sweep, routed through the coordinator for the same
    /// reason `deleteAllMeetings` is: the brief's original wiring called
    /// `MeetingAudioStore.enforceRetention` straight from `PrivacyPane`,
    /// which could delete an in-flight `MeetingPipeline` run's audio out
    /// from under it. See `MeetingsCoordinatorImpl.enforceRetention`'s doc
    /// comment for why the actual fix is excluding a busy meeting's audio
    /// from the sweep entirely (skip), not cancelling its run (drain) —
    /// a round-2 review (N2) found the original drain-based version made
    /// even a non-destructive cap INCREASE cancel, and silently truncate,
    /// whatever meeting happened to be transcribing at that moment.
    func enforceRetention(maxBytes: Int64, maxAgeDays: Int) async
    /// Lets the coordinator push elapsed-time and progress updates straight
    /// into the pane's own view model instead of polling. Called once, when
    /// the pane appears; the coordinator holds only a weak reference so a
    /// closed window's view model can still deallocate normally.
    @MainActor func register(model: MeetingsViewModel)
}

/// The seam `MeetingsViewModel` uses to resolve a meeting's archived audio.
/// `MeetingAudioStore` conforms to this already; the protocol exists so a
/// test can substitute a locator with a controllable delay to reproduce the
/// "selection changed mid-lookup" race — a real actor call has no delay knob
/// to force that interleaving deterministically.
public protocol MeetingAudioLocating: Sendable {
    func existingMicURL(for id: UUID) async -> URL?
    func existingSystemURL(for id: UUID) async -> URL?
}

/// All the behaviour behind the Meetings pane: the list, the selection, the
/// recording state, progress, and the edit actions. `MeetingsPane` is a thin
/// projection of this.
@MainActor
public final class MeetingsViewModel: ObservableObject {
    @Published public private(set) var meetings: [Meeting] = []
    @Published public private(set) var selection: UUID?
    @Published public private(set) var recordingID: UUID?
    @Published public private(set) var elapsedSeconds: Double = 0
    @Published public private(set) var progress: MeetingProgress?
    @Published public private(set) var banner: String?
    @Published public private(set) var permissionMissing = false
    /// The selected meeting's archived audio, resolved by `loadAudioURLs`.
    @Published public private(set) var audioURLs: (mic: URL?, system: URL?) = (nil, nil)

    private let store: MeetingStore
    private let coordinator: any MeetingsCoordinating
    private let audioStore: any MeetingAudioLocating
    /// Set synchronously before the first suspension point in
    /// `startRecording()`, and only cleared after that call fully resolves.
    /// `recordingID` alone cannot gate re-entrancy: it isn't assigned until
    /// `coordinator.startMeeting()` returns, so two overlapping calls (a
    /// rapid double-tap on Record, each in its own `Task`) would both
    /// observe `recordingID == nil` and both start a session. This flag
    /// closes that window the same way `stopRecording()` already closes its
    /// own — by mutating state before the `await`, not after.
    private var startInFlight = false
    /// The mirror of `startInFlight` for the teardown transition: set
    /// synchronously before `coordinator.stopMeeting()` is awaited, cleared
    /// once it resolves. `recordingID` is nil for both windows, so without
    /// this a Stop click landing DURING a stop is indistinguishable from one
    /// landing during a start — and a review found that meant it reported
    /// "still starting" while the meeting was in fact stopping.
    private var stopInFlight = false
    /// Observes `.wisprMeetingsDidChange` so a mutation made outside this
    /// view model (another window, or a background `MeetingPipeline` run
    /// finishing while this pane is open) still refreshes `meetings`
    /// instead of leaving a stale status on screen.
    private var changeObserver: NSObjectProtocol?

    public init(store: MeetingStore, coordinator: any MeetingsCoordinating,
                audioStore: any MeetingAudioLocating) {
        self.store = store
        self.coordinator = coordinator
        self.audioStore = audioStore
        changeObserver = NotificationCenter.default.addObserver(
            forName: .wisprMeetingsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.load()
            }
        }
    }

    public var selectedMeeting: Meeting? {
        guard let selection else { return nil }
        return meetings.first { $0.id == selection }
    }

    public var isRecording: Bool { recordingID != nil }

    public func load() async {
        meetings = await store.all()
        if let selection, !meetings.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    public func select(_ id: UUID?) {
        selection = id
        // Cleared eagerly, not just left to `loadAudioURLs` to overwrite:
        // between selecting a new meeting and its own lookup resolving, the
        // detail view must not show the previously-selected meeting's Play
        // buttons under the newly-selected meeting's transcript.
        audioURLs = (nil, nil)
    }

    public func dismissBanner() {
        banner = nil
    }

    /// Resolves `id`'s archived audio. Two actor hops separate the lookups
    /// from the write below, and cancellation here is cooperative —
    /// `MeetingAudioStore` never checks `Task.isCancelled` — so a fast
    /// selection change while this call is in flight must not let a late
    /// result for `id` clobber `audioURLs` with a different meeting's
    /// tracks. Capturing `id` as the parameter and re-checking `selection`
    /// after both awaits, rather than trusting the caller's snapshot of
    /// "current" to still be current, is what makes that safe.
    public func loadAudioURLs(for id: UUID) async {
        let mic = await audioStore.existingMicURL(for: id)
        let system = await audioStore.existingSystemURL(for: id)
        guard selection == id else { return }
        audioURLs = (mic, system)
    }

    public func startRecording() async {
        guard recordingID == nil, !startInFlight else { return }
        startInFlight = true
        defer { startInFlight = false }
        banner = nil
        permissionMissing = false
        switch await coordinator.startMeeting() {
        case .success(let id):
            recordingID = id
            selection = id
            elapsedSeconds = 0
            await load()
        case .failure(let failure):
            banner = failure.userMessage
            permissionMissing = failure == .screenRecordingDenied
        }
    }

    /// Aligns `recordingID` (and `elapsedSeconds` when clearing) with the
    /// coordinator's own recording state. Called once when the pane
    /// registers with the coordinator (`register(model:)`), so a pane
    /// opened after a meeting was already started elsewhere — the menu bar,
    /// with no pane open yet to route a `startRecording()` call through —
    /// shows the live session instead of a stale "not recording". Not used
    /// by `startRecording`/`stopRecording` themselves; those already own
    /// `recordingID` directly as part of owning the transition.
    public func syncRecording(id: UUID?) {
        guard recordingID != id else { return }
        recordingID = id
        if id == nil { elapsedSeconds = 0 }
    }

    /// Applies a `startMeeting()` failure that happened before this pane
    /// existed to show it directly — the menu-bar fallback path stashes one
    /// on `AppController` when no pane has ever registered, and replays it
    /// here the moment `register(model:)` runs, the same way
    /// `startRecording()`'s own failure branch sets these two fields.
    public func applyStartFailure(_ failure: MeetingStartFailure) {
        banner = failure.userMessage
        permissionMissing = failure == .screenRecordingDenied
    }

    /// Shown when a Stop lands in the sub-second window where the meeting is
    /// still being set up — `meetingRecordingActive` (and therefore the menu
    /// bar's "Stop Meeting" label) is already true, but `recordingID` is not
    /// yet assigned. Matches `deleteMeeting`'s wording for the same window.
    public static let stillStartingMessage =
        "This meeting is still starting — try again in a moment"
    /// The stop-window counterpart. `meetingRecordingActive` stays true for
    /// the whole teardown too, so the menu keeps saying "Stop Meeting" while
    /// a stop is already under way — reporting "still starting" there (as
    /// this did before a review caught it) tells the user the opposite of
    /// what is happening.
    public static let stillStoppingMessage =
        "This meeting is still stopping — try again in a moment"

    public func stopRecording() async {
        // Reachable during BOTH transition windows: the menu bar labels the
        // item "Stop Meeting" as soon as `meetingRecordingActive` is true,
        // which covers setup and teardown as well as an actually-live
        // recording, but `recordingID` is nil for both — so a click in
        // either window used to reach here and silently no-op, with no
        // feedback at all. `stopInFlight` is what tells the two apart.
        guard recordingID != nil else {
            banner = stopInFlight ? Self.stillStoppingMessage : Self.stillStartingMessage
            return
        }
        recordingID = nil
        elapsedSeconds = 0
        stopInFlight = true
        await coordinator.stopMeeting()
        stopInFlight = false
        await load()
    }

    /// Called by `AppController` while recording so the pane can show a timer.
    public func updateElapsed(_ seconds: Double) {
        elapsedSeconds = seconds
    }

    /// Called by `AppController` during processing.
    public func updateProgress(_ value: MeetingProgress?) {
        progress = value
    }

    public func reprocess(id: UUID) async {
        await coordinator.reprocess(meetingID: id)
        await load()
    }

    /// Pure delegation, like `startMeeting`/`stopMeeting`/`reprocess`/
    /// `enhanceNotes`: deleting a meeting needs AppController-exclusive
    /// machinery (cancelling an in-flight `MeetingPipeline` run for this
    /// meeting, deleting its archived audio tracks from
    /// `MeetingAudioStore`), unlike `saveNotes`/`rename`/`renameMeeting`,
    /// which are pure data CRUD this view model can own outright. The
    /// coordinator's real implementation owns the store row delete too —
    /// see the `// Task 16` note in `AppController`.
    public func delete(id: UUID) async {
        await coordinator.deleteMeeting(id: id)
        if selection == id { selection = nil }
        await load()
    }

    /// Saves the typed notes, then — unless the meeting is still recording —
    /// runs the LLM tidy-up over them.
    ///
    /// The `.recording` exclusion is the root-cause half of the
    /// stop-during-enhance class of bugs. An `enhanceNotes` run registers a
    /// pipeline run for the meeting's id; `stopMeeting()`'s own store/audio
    /// work legitimately chains behind whatever is already registered, so a
    /// tidy-up started mid-meeting means the pane's Stop button — which
    /// awaits `stopMeeting()` — blocks for a full local LLM generation. The
    /// recorder itself is torn down immediately regardless (that is the
    /// privacy fix, and it stands on its own), but the simplest way to stop
    /// the chain forming at all is not to start an LLM run while the meeting
    /// is live. Saving is deliberately NOT gated: typing notes during a
    /// meeting is the whole point of the field, and this is the only path
    /// that persists them.
    public func saveNotes(_ text: String, for id: UUID) async {
        guard let meeting = await store.update(id: id, { $0.userNotes = text })
        else { return }
        await load()
        guard meeting.status != .recording else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await coordinator.enhanceNotes(meetingID: id)
        await load()
    }

    /// A blank name clears the override and falls back to "Speaker N".
    public func rename(speaker speakerID: String, to name: String, in id: UUID) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = await store.update(id: id) { meeting in
            if trimmed.isEmpty {
                meeting.speakerNames.removeValue(forKey: speakerID)
            } else {
                meeting.speakerNames[speakerID] = trimmed
            }
        }
        guard updated != nil else { return }
        await load()
    }

    public func renameMeeting(_ id: UUID, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let updated = await store.update(id: id) { $0.title = trimmed }
        guard updated != nil else { return }
        await load()
    }

    // MARK: - Formatting

    /// "0:09", "12:04", "1:02:33".
    public static func elapsedLabel(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    public static func statusLabel(_ status: MeetingStatus) -> String {
        switch status {
        case .recording: return "Recording"
        case .processing: return "Processing"
        case .complete: return "Ready"
        case .partial: return "Partial"
        case .failed: return "Failed"
        }
    }
}
