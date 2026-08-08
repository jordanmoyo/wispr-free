import Foundation

/// Everything the coordinator needs to start one file's run. A value type so
/// it can cross the actor boundary into `AppController` unchanged: the view
/// model owns no transcription machinery, it only describes the job.
public struct TranscriptionRequest: Sendable, Equatable {
    public let sourceURL: URL
    public let transcriptionModelID: String
    public let enhancementModelID: String
    /// nil means "let Whisper detect it", the same convention the dictation
    /// path uses.
    public let language: String?
    public let diarize: Bool

    public init(sourceURL: URL, transcriptionModelID: String,
                enhancementModelID: String, language: String? = nil,
                diarize: Bool) {
        self.sourceURL = sourceURL
        self.transcriptionModelID = transcriptionModelID
        self.enhancementModelID = enhancementModelID
        self.language = language
        self.diarize = diarize
    }
}

/// Why a transcription could not be started. Each message names the fix, not
/// just the problem — the `MeetingStartFailure` rule: telling someone what
/// broke without telling them what to do leaves them stuck.
public enum TranscriptionStartFailure: Error, Equatable {
    /// A model is still downloading or warming up. Nothing to fix, just wait.
    case modelLoading
    /// The model this job asked for has not been downloaded. The associated
    /// value is its display name, and it MUST reach the user: "download it
    /// first" without saying which one leaves them hunting.
    case modelNotInstalled(String)
    case dictationInProgress
    case meetingInProgress
    /// macOS could not decode the file. The associated value is the
    /// underlying reason, and it MUST reach the user: "this file could not be
    /// read" with no cause is an error report the user cannot act on.
    case fileUnreadable(String)
    case fileTooLong
    /// Another transcription is already running. One at a time, because a
    /// second run would contend for the same model and the same memory.
    case alreadyRunning

    public var userMessage: String {
        switch self {
        case .modelLoading:
            return "The transcription model is still loading. Wait for it to "
                + "finish in Settings › Models, then start the transcription "
                + "again."
        case .modelNotInstalled(let name):
            return "The \(name) model has not been downloaded yet. Download it "
                + "in Settings › Models, then start the transcription again."
        case .dictationInProgress:
            return "Finish the dictation in progress before transcribing a file."
        case .meetingInProgress:
            return "Stop the meeting that is recording before transcribing a file."
        case .fileUnreadable(let reason):
            return "This file could not be read: \(reason). Try exporting it "
                + "as WAV, M4A, or MP3 and adding it again."
        case .fileTooLong:
            return "Transcription handles recordings up to 2 hours. Split this "
                + "file into shorter parts and add them one at a time."
        case .alreadyRunning:
            return "A transcription is already running. Wait for it to finish, "
                + "or cancel it, then start this one."
        }
    }
}

/// The seam between the Transcribe UI and `AppController`, which owns the
/// models, the pipeline, and the dictation phase machine — mirrors
/// `MeetingsCoordinating`. The view model talks only to this, so its whole
/// surface is testable with a stub.
public protocol TranscriptionCoordinating: AnyObject, Sendable {
    func start(request: TranscriptionRequest) async -> Result<UUID, TranscriptionStartFailure>
    func cancel() async
    func generate(kind: TranscriptOutputKind, jobID: UUID) async
    func delete(id: UUID) async
    /// Lets the coordinator push progress straight into the pane's own view
    /// model instead of polling. Called once, when the pane appears; the
    /// coordinator holds only a weak reference so a closed window's view
    /// model can still deallocate normally.
    @MainActor func register(model: TranscriptionViewModel)
}

/// All the behaviour behind the Transcribe pane: the library, the selection,
/// the pending file, progress, and the actions. `TranscribePane` is a thin
/// projection of this.
@MainActor
public final class TranscriptionViewModel: ObservableObject {
    @Published public private(set) var jobs: [TranscriptionJob] = []
    @Published public private(set) var selection: UUID?
    @Published public private(set) var progress: TranscriptionProgress?
    @Published public private(set) var banner: String?
    /// The job currently being transcribed, or nil when nothing is running.
    @Published public private(set) var activeJobID: UUID?
    /// True from the moment Cancel is pressed until the run actually stops.
    /// The gap is up to one chunk — ten minutes of audio — and the pane says
    /// "Cancelling…" for all of it rather than pretending it is already over.
    @Published public private(set) var cancelling = false
    /// The output currently being generated, so the pane can disable the four
    /// buttons and show which one is working.
    @Published public private(set) var generating: TranscriptOutputKind?

    // User-editable setup, initialised from the dictation defaults.
    @Published public var transcriptionModelID: String
    @Published public var enhancementModelID: String
    @Published public var language: String?
    @Published public var diarize = false

    @Published public private(set) var pendingURL: URL?
    @Published public private(set) var pendingTitle = ""
    @Published public private(set) var pendingDurationSeconds: Double = 0

    private let store: TranscriptionJobStore
    private let coordinator: any TranscriptionCoordinating
    /// Set synchronously before the first suspension point in `start()`, and
    /// only cleared after that call fully resolves. `activeJobID` alone
    /// cannot gate re-entrancy: it isn't assigned until `coordinator.start`
    /// returns, so two overlapping calls (a rapid double-click on
    /// Transcribe, each in its own `Task`) would both observe
    /// `activeJobID == nil` and both start a run. This flag closes that
    /// window by mutating state BEFORE the `await`, not after — the
    /// `MeetingsViewModel.startRecording` precedent.
    private var startInFlight = false
    /// Observes `.wisprTranscriptionsDidChange` so a mutation made outside
    /// this view model — a background pipeline run finishing while the pane
    /// is open — still refreshes `jobs` instead of leaving a stale status on
    /// screen.
    private var changeObserver: NSObjectProtocol?

    public init(store: TranscriptionJobStore,
                coordinator: any TranscriptionCoordinating,
                defaultTranscriptionModelID: String = ModelRegistry.defaultModel.id,
                defaultEnhancementModelID: String = CleanupModelRegistry.defaultModel.id) {
        self.store = store
        self.coordinator = coordinator
        self.transcriptionModelID = defaultTranscriptionModelID
        self.enhancementModelID = defaultEnhancementModelID
        changeObserver = NotificationCenter.default.addObserver(
            forName: .wisprTranscriptionsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.load()
            }
        }
    }

    public var selectedJob: TranscriptionJob? {
        guard let selection else { return nil }
        return jobs.first { $0.id == selection }
    }

    public var isRunning: Bool { activeJobID != nil }

    /// Whether speaker identification can run on the pending file.
    public var diarizationAvailable: Bool {
        DiarizationGate.available(durationSeconds: pendingDurationSeconds)
    }

    /// Why it cannot, phrased for the user, or nil when it can.
    public var diarizationUnavailableReason: String? {
        DiarizationGate.unavailableReason(durationSeconds: pendingDurationSeconds)
    }

    // MARK: - Library

    public func load() async {
        jobs = await store.all()
        if let selection, !jobs.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    public func select(_ id: UUID?) {
        selection = id
    }

    public func dismissBanner() {
        banner = nil
    }

    // MARK: - Setup

    /// Records the file the user picked. Forcing `diarize` off above the gate
    /// is not cosmetic: a toggle that stays lit while the feature cannot run
    /// promises speaker labels the transcript will not have.
    public func selectFile(url: URL, durationSeconds: Double) {
        pendingURL = url
        pendingTitle = TranscriptionJob.defaultTitle(sourcePath: url.path)
        pendingDurationSeconds = durationSeconds
        banner = nil
        if !DiarizationGate.available(durationSeconds: durationSeconds) {
            diarize = false
        }
    }

    public func clearSelection() {
        pendingURL = nil
        pendingTitle = ""
        pendingDurationSeconds = 0
    }

    // MARK: - Actions

    public func start() async {
        guard let url = pendingURL else { return }
        guard activeJobID == nil, !startInFlight else { return }
        startInFlight = true
        defer { startInFlight = false }
        banner = nil
        cancelling = false
        let request = TranscriptionRequest(
            sourceURL: url,
            transcriptionModelID: transcriptionModelID,
            enhancementModelID: enhancementModelID,
            language: language,
            diarize: diarize)
        switch await coordinator.start(request: request) {
        case .success(let id):
            activeJobID = id
            selection = id
            progress = TranscriptionProgress.make(
                stage: diarize ? .diarizing : .transcribing,
                stageFraction: 0, diarizationEnabled: diarize)
            await load()
        case .failure(let failure):
            banner = failure.userMessage
        }
    }

    /// Deliberately ungated: Cancel must reach the coordinator even when this
    /// pane's own `activeJobID` is stale (a run started from another window),
    /// and cancelling nothing is harmless.
    ///
    /// `activeJobID` is NOT cleared here. Cancellation is cooperative and
    /// lands between chunks, so the run keeps going for up to ten minutes of
    /// audio; clearing it would re-enable Start immediately and the next
    /// press would be refused with "cancel it, then start this one" — advice
    /// the user had just followed. The run's own `defer` calls
    /// `syncActive(id: nil)` when it really ends, and `cancelling` keeps the
    /// pane honest in the meantime.
    public func cancel() async {
        guard activeJobID != nil else {
            await coordinator.cancel()
            return
        }
        cancelling = true
        await coordinator.cancel()
        await load()
    }

    public func generate(_ kind: TranscriptOutputKind) async {
        guard let id = selection else { return }
        generating = kind
        await coordinator.generate(kind: kind, jobID: id)
        generating = nil
        await load()
    }

    /// Pure delegation, like `MeetingsViewModel.delete`: removing a job needs
    /// AppController-exclusive machinery (cancelling an in-flight run for
    /// this job) as well as the store row, so the coordinator owns it.
    public func delete(id: UUID) async {
        await coordinator.delete(id: id)
        if selection == id { selection = nil }
        if activeJobID == id { activeJobID = nil; progress = nil; cancelling = false }
        await load()
    }

    /// A rename is pure data CRUD, so it goes straight to the store — the
    /// `renameMeeting` precedent. A blank name is ignored rather than
    /// blanking the row.
    public func rename(_ id: UUID, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard await store.update(id: id, { $0.title = trimmed }) != nil else { return }
        await load()
    }

    // MARK: - Coordinator pushes

    /// Called by the coordinator as a run advances.
    ///
    /// Clamped monotonically. The coordinator dispatches each callback in its
    /// own unstructured `Task { @MainActor in … }`, and unstructured tasks
    /// have no ordering guarantee — two callbacks issued 40% then 45% can
    /// land in either order, and a bar that jumps backwards reads as a stall
    /// or a restart. Clearing (nil) and the terminal `.done` always win, so
    /// the bar can still come down.
    public func updateProgress(_ value: TranscriptionProgress?) {
        guard let value else {
            progress = nil
            return
        }
        let isLateArrival = value.stage != .done
            && value.fraction < (progress?.fraction ?? 0)
        guard !isLateArrival else { return }
        progress = value
    }

    /// Aligns `activeJobID` with the coordinator's own state. Called when the
    /// pane registers, so a pane opened after a run was already started
    /// elsewhere shows the live job instead of a stale idle state, and when a
    /// run finishes, so the pane stops showing a bar for work that is done.
    /// Mirrors `MeetingsViewModel.syncRecording`.
    public func syncActive(id: UUID?) {
        guard activeJobID != id else { return }
        activeJobID = id
        if id == nil {
            progress = nil
            cancelling = false
        }
    }

    // MARK: - Formatting

    /// "0 min", "1 min", "1 h 2 min".
    public static func durationLabel(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0 min" }
        let totalMinutes = Int(max(0, seconds)) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours) h \(minutes) min"
        }
        return "\(minutes) min"
    }

    public static func statusLabel(_ status: TranscriptionJobStatus) -> String {
        switch status {
        case .processing: return "Transcribing"
        case .complete: return "Ready"
        case .partial: return "Partial"
        case .failed: return "Failed"
        }
    }
}
