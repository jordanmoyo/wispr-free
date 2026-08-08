import XCTest
@testable import WisprCore

private actor CoordinatorLog {
    private(set) var started: [TranscriptionRequest] = []
    private(set) var generated: [TranscriptOutputKind] = []
    private(set) var cancels = 0
    func recordStart(_ request: TranscriptionRequest) { started.append(request) }
    func recordGenerate(_ kind: TranscriptOutputKind) { generated.append(kind) }
    func recordCancel() { cancels += 1 }
}

private final class StubCoordinator: TranscriptionCoordinating, @unchecked Sendable {
    let log = CoordinatorLog()
    var result: Result<UUID, TranscriptionStartFailure> = .success(UUID())

    func start(request: TranscriptionRequest) async -> Result<UUID, TranscriptionStartFailure> {
        await log.recordStart(request)
        return result
    }
    func cancel() async { await log.recordCancel() }
    func generate(kind: TranscriptOutputKind, jobID: UUID) async {
        await log.recordGenerate(kind)
    }
    func delete(id: UUID) async {}
    @MainActor func register(model: TranscriptionViewModel) {}
}

@MainActor
final class TranscriptionViewModelTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wispr-vm-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Both ids are deliberately NON-default. An earlier version of this
    /// helper passed "large-v3-turbo"/"qwen3-4b" — byte-identical to
    /// `ModelRegistry.defaultModel.id` and `CleanupModelRegistry
    /// .defaultModel.id`, the values the initializer falls back to when the
    /// parameters are omitted — so the test below could not tell "honours the
    /// parameter" from "ignores it". Rewriting the init to discard both
    /// parameters left it green.
    private func makeModel() -> (TranscriptionViewModel, StubCoordinator, TranscriptionJobStore) {
        let store = TranscriptionJobStore(directoryURL: directory)
        let coordinator = StubCoordinator()
        return (TranscriptionViewModel(store: store, coordinator: coordinator,
                                       defaultTranscriptionModelID: "medium",
                                       defaultEnhancementModelID: "gemma-3-4b"),
                coordinator, store)
    }

    func testInitialModelsComeFromTheInjectedDefaults() {
        XCTAssertNotEqual("medium", ModelRegistry.defaultModel.id)
        XCTAssertNotEqual("gemma-3-4b", CleanupModelRegistry.defaultModel.id)
        let (model, _, _) = makeModel()
        XCTAssertEqual(model.transcriptionModelID, "medium")
        XCTAssertEqual(model.enhancementModelID, "gemma-3-4b")
    }

    func testSelectingAFileRecordsItsDurationAndTitle() {
        let (model, _, _) = makeModel()
        model.selectFile(url: URL(fileURLWithPath: "/tmp/team sync.m4a"), durationSeconds: 900)
        XCTAssertEqual(model.pendingTitle, "team sync")
        XCTAssertEqual(model.pendingDurationSeconds, 900)
    }

    func testDiarizationOffersItselfBelowTheGate() {
        let (model, _, _) = makeModel()
        model.selectFile(url: URL(fileURLWithPath: "/tmp/a.m4a"), durationSeconds: 900)
        XCTAssertTrue(model.diarizationAvailable)
        XCTAssertNil(model.diarizationUnavailableReason)
    }

    /// The toggle is turned ON against a short file first, on purpose: with
    /// `diarize` defaulting to false, asserting it is false after selecting a
    /// long file would pass against a view model that never forces it off.
    /// This is the real sequence too — pick a 15-minute file, enable speaker
    /// identification, then swap in a 70-minute one.
    func testDiarizationDisablesItselfAboveTheGateAndSaysWhy() {
        let (model, _, _) = makeModel()
        model.selectFile(url: URL(fileURLWithPath: "/tmp/short.m4a"), durationSeconds: 900)
        model.diarize = true
        model.selectFile(url: URL(fileURLWithPath: "/tmp/a.m4a"),
                         durationSeconds: DiarizationGate.maxSeconds + 600)
        XCTAssertFalse(model.diarizationAvailable)
        XCTAssertNotNil(model.diarizationUnavailableReason)
        XCTAssertFalse(model.diarize, "the toggle must not stay on above the gate")
    }

    func testStartPassesTheChosenModelsThrough() async {
        let (model, coordinator, _) = makeModel()
        model.selectFile(url: URL(fileURLWithPath: "/tmp/a.m4a"), durationSeconds: 60)
        model.transcriptionModelID = "small"
        model.enhancementModelID = "qwen2.5-1.5b"
        await model.start()

        let started = await coordinator.log.started
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started.first?.transcriptionModelID, "small")
        XCTAssertEqual(started.first?.enhancementModelID, "qwen2.5-1.5b")
    }

    /// A double-click on Transcribe. `activeJobID` cannot gate this on its
    /// own — it is not assigned until `coordinator.start` RETURNS, so both
    /// calls would observe nil and both start a run over the same two-hour
    /// file: two Whisper models resident at once, two rows, and a Cancel
    /// button that can only stop one of them.
    ///
    /// `async let` rather than a `TaskGroup` because both calls are
    /// `@MainActor`: the first runs to its first suspension inside
    /// `coordinator.start` and the second then runs on the same actor, which
    /// is exactly the interleaving the flag exists to survive.
    func testTwoOverlappingStartsRunOnlyOnce() async {
        let (model, coordinator, _) = makeModel()
        model.selectFile(url: URL(fileURLWithPath: "/tmp/a.m4a"), durationSeconds: 60)

        async let first: Void = model.start()
        async let second: Void = model.start()
        _ = await (first, second)

        let started = await coordinator.log.started
        XCTAssertEqual(started.count, 1, "the second press started another run")
    }

    func testStartWithoutAFileDoesNothing() async {
        let (model, coordinator, _) = makeModel()
        await model.start()
        let started = await coordinator.log.started
        XCTAssertTrue(started.isEmpty)
    }

    func testStartFailureSurfacesItsMessage() async {
        let (model, coordinator, _) = makeModel()
        coordinator.result = .failure(.modelLoading)
        model.selectFile(url: URL(fileURLWithPath: "/tmp/a.m4a"), durationSeconds: 60)
        await model.start()
        XCTAssertEqual(model.banner, TranscriptionStartFailure.modelLoading.userMessage)
    }

    func testGenerateDelegatesTheChosenKind() async {
        let (model, coordinator, store) = makeModel()
        let job = TranscriptionJob(
            title: "t", createdAt: Date(), sourcePath: "/tmp/a.m4a",
            durationSeconds: 60, status: .complete, transcriptionModelID: "base",
            enhancementModelID: "qwen3-4b", diarizationRequested: false)
        await store.upsert(job)
        await model.load()
        model.select(job.id)
        await model.generate(.report)

        let generated = await coordinator.log.generated
        XCTAssertEqual(generated, [.report])
    }

    func testGenerateWithoutASelectionDoesNothing() async {
        let (model, coordinator, _) = makeModel()
        await model.generate(.summary)
        let generated = await coordinator.log.generated
        XCTAssertTrue(generated.isEmpty)
    }

    func testLoadListsJobsNewestFirst() async {
        let (model, _, store) = makeModel()
        for (title, time) in [("older", 1_000.0), ("newer", 2_000.0)] {
            await store.upsert(TranscriptionJob(
                title: title, createdAt: Date(timeIntervalSince1970: time),
                sourcePath: "/tmp/a.m4a", durationSeconds: 60,
                transcriptionModelID: "base", enhancementModelID: "qwen3-4b",
                diarizationRequested: false))
        }
        await model.load()
        XCTAssertEqual(model.jobs.map(\.title), ["newer", "older"])
    }

    func testCancelDelegates() async {
        let (model, coordinator, _) = makeModel()
        model.selectFile(url: URL(fileURLWithPath: "/tmp/a.m4a"), durationSeconds: 60)
        await model.start()
        await model.cancel()
        let cancels = await coordinator.log.cancels
        XCTAssertEqual(cancels, 1)
    }

    /// Cancel must NOT re-enable Start. Cancellation is cooperative and lands
    /// between chunks — up to ten minutes of audio — and the coordinator
    /// deliberately does not await the run. A pane that cleared `activeJobID`
    /// here would re-enable Start immediately and the next press would be
    /// refused with "cancel it, then start this one", which is the advice the
    /// user had just followed.
    func testCancelKeepsTheRunActiveUntilItReallyStops() async {
        let (model, _, _) = makeModel()
        model.selectFile(url: URL(fileURLWithPath: "/tmp/a.m4a"), durationSeconds: 60)
        await model.start()
        XCTAssertTrue(model.isRunning)

        await model.cancel()
        XCTAssertTrue(model.isRunning, "the run has not stopped yet")
        XCTAssertTrue(model.cancelling)

        // What the run's own `defer` calls when it finally ends.
        model.syncActive(id: nil)
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.cancelling)
        XCTAssertNil(model.progress)
    }

    /// Cancelling when nothing is running must still reach the coordinator (a
    /// run started from another window leaves this pane's `activeJobID` nil)
    /// without stranding the pane in a "Cancelling…" state that nothing will
    /// ever clear, because no run will report back.
    func testCancelWithNothingRunningDoesNotStickInCancelling() async {
        let (model, coordinator, _) = makeModel()
        await model.cancel()
        let cancels = await coordinator.log.cancels
        XCTAssertEqual(cancels, 1)
        XCTAssertFalse(model.cancelling)
    }

    /// The coordinator dispatches each progress callback in its own
    /// unstructured `Task`, and unstructured tasks have no ordering
    /// guarantee, so 45% and 40% can arrive in either order. A bar that walks
    /// backwards reads as a stall or a restart.
    func testProgressNeverGoesBackwards() {
        let (model, _, _) = makeModel()
        model.updateProgress(TranscriptionProgress(stage: .transcribing, fraction: 0.45))
        model.updateProgress(TranscriptionProgress(stage: .transcribing, fraction: 0.40))
        XCTAssertEqual(model.progress?.fraction ?? 0, 0.45, accuracy: 0.001)

        // Forwards still moves, or the clamp would freeze the bar entirely.
        model.updateProgress(TranscriptionProgress(stage: .transcribing, fraction: 0.60))
        XCTAssertEqual(model.progress?.fraction ?? 0, 0.60, accuracy: 0.001)
    }

    /// `.done` is terminal and must always win, even when its fraction reads
    /// lower than the last stage reading — otherwise the bar could never come
    /// down.
    func testTheDoneStageAlwaysLands() {
        let (model, _, _) = makeModel()
        model.updateProgress(TranscriptionProgress(stage: .transcribing, fraction: 0.9))
        model.updateProgress(TranscriptionProgress(stage: .done, fraction: 0.1))
        XCTAssertEqual(model.progress?.stage, .done)
    }

    func testDurationLabelFormatsHoursAndMinutes() {
        XCTAssertEqual(TranscriptionViewModel.durationLabel(0), "0 min")
        XCTAssertEqual(TranscriptionViewModel.durationLabel(90), "1 min")
        XCTAssertEqual(TranscriptionViewModel.durationLabel(3_720), "1 h 2 min")
    }
}
