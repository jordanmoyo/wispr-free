import XCTest
@testable import WisprCore

// MARK: - Doubles

private struct StubAudio: AudioChunkProviding {
    let sampleCount: Int
    func samples(in range: Range<Int>) async throws -> [Float] {
        [Float](repeating: 0, count: range.count)
    }
}

/// Records which Whisper model a run asked it to load, and how often it was
/// asked to transcribe — the two facts that decide whether a per-job model
/// choice was honoured or quietly discarded.
private actor TranscriberSpy: ModelLoadingTranscribing {
    private(set) var loadedModelIDs: [String] = []
    private(set) var transcribeCalls = 0
    /// What each `transcribeSegments` call was told the language was. The
    /// Language picker is only real if this is what the user chose.
    private(set) var languages: [String?] = []
    /// When set, `load` throws it — a model that is listed but cannot be
    /// brought up (an interrupted download, a corrupt cache).
    let loadError: Error?

    init(loadError: Error? = nil) {
        self.loadError = loadError
    }

    func load(model: WhisperModel) async throws {
        loadedModelIDs.append(model.id)
        if let loadError { throw loadError }
    }

    func transcribeSegments(samples: [Float], language: String?,
                            progress: (@Sendable (Double) -> Void)?) async throws
        -> [MeetingTranscriptSegment] {
        transcribeCalls += 1
        languages.append(language)
        return [MeetingTranscriptSegment(speaker: .others, start: 0, end: 5,
                                         text: "hello")]
    }
}

/// Records which document model the generator asked it to load.
private actor BackendSpy: CleanupBackend {
    private(set) var loadedModelIDs: [String] = []

    func load(model: CleanupModel) async throws {
        loadedModelIDs.append(model.id)
    }

    func generate(system: String, user: String, maxTokens: Int) async throws -> String {
        "cleaned"
    }

    func unload() async {}
}

private struct StubDiarizer: MeetingDiarizing {
    let spans: [DiarizedSpan]
    func warmUp() async throws {}
    func diarize(samples: [Float],
                 progress: (@Sendable (Double) -> Void)?) async throws -> [DiarizedSpan] {
        spans
    }
}

/// Covers `AppController`'s `TranscriptionCoordinating` conformance: the
/// refusal messages the pane shows, the caps they promise, and — the part
/// that matters most — that the per-job model choices the setup screen
/// collects are the ones a run actually uses.
///
/// `AppController` itself cannot be constructed here (`StatusItemController
/// .init()` calls `NSStatusBar.system.statusItem(withLength:)`, a real side
/// effect with no test-only alternative), which is why the two decisions
/// worth proving live in `nonisolated static` functions on it.
final class TranscriptionCoordinatorTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wispr-coordinator-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Deliberately NON-default on both axes: a fixture built from the
    /// defaults would pass just as happily against an implementation that
    /// ignored the request and used the defaults.
    private static let chosenTranscriptionModelID = "small"
    private static let chosenEnhancementModelID = "llama-3.2-3b"

    private func request(
        path: String = "/tmp/x.m4a",
        transcriptionModelID: String = chosenTranscriptionModelID,
        enhancementModelID: String = chosenEnhancementModelID,
        language: String? = nil,
        diarize: Bool = false) -> TranscriptionRequest {
        TranscriptionRequest(
            sourceURL: URL(fileURLWithPath: path),
            transcriptionModelID: transcriptionModelID,
            enhancementModelID: enhancementModelID,
            language: language, diarize: diarize)
    }

    private func seededStore(
        enhancementModelID: String = chosenEnhancementModelID,
        durationSeconds: Double = 60,
        segments: [MeetingTranscriptSegment] = []
    ) async -> (TranscriptionJobStore, TranscriptionJob) {
        let store = TranscriptionJobStore(directoryURL: directory)
        let job = TranscriptionJob(
            title: "test", createdAt: Date(), sourcePath: "/tmp/x.m4a",
            durationSeconds: durationSeconds,
            transcriptionModelID: Self.chosenTranscriptionModelID,
            enhancementModelID: enhancementModelID,
            diarizationRequested: false, segments: segments)
        await store.upsert(job)
        return (store, job)
    }

    // MARK: - Refusal messages

    func testStartFailureMessagesNameTheirFix() {
        XCTAssertTrue(TranscriptionStartFailure.dictationInProgress
            .userMessage.lowercased().contains("dictation"))
        XCTAssertTrue(TranscriptionStartFailure.meetingInProgress
            .userMessage.lowercased().contains("meeting"))
        XCTAssertTrue(TranscriptionStartFailure.modelLoading
            .userMessage.lowercased().contains("loading"))
    }

    func testFileTooLongMessageNamesTheTwoHourLimit() {
        let message = TranscriptionStartFailure.fileTooLong.userMessage
        XCTAssertTrue(message.contains("2 hours") || message.contains("two hours"),
                      "the limit must be stated, not implied: \(message)")
    }

    func testUnreadableFailureCarriesTheUnderlyingReason() {
        let message = TranscriptionStartFailure.fileUnreadable("bad codec").userMessage
        XCTAssertTrue(message.contains("bad codec"))
    }

    /// The ceiling in the reader and the one the refusal message promises
    /// must be the same number. A drifted pair means the app refuses files it
    /// says it accepts.
    ///
    /// This asserts the RELATIONSHIP, not two literals: the hours are derived
    /// from `maxSamples` and then looked for in the message. An earlier
    /// version compared `maxSamples` to `16_000 * 7_200` and never read the
    /// message at all — changing the message to "up to 3 hours", the exact
    /// drift the comment describes, left it green.
    func testReaderCeilingMatchesTheAdvertisedLimit() {
        let hours = Double(AudioFileReader.maxSamples) / 16_000 / 3_600
        XCTAssertEqual(hours, hours.rounded(), accuracy: 0.001,
                       "a fractional ceiling could not be stated as '\(hours) hours'")
        let message = TranscriptionStartFailure.fileTooLong.userMessage
        XCTAssertTrue(message.contains("\(Int(hours)) hours"),
                      "reader accepts \(hours) h but the message says: \(message)")
    }

    /// The dictation path's own cap must NOT have moved.
    func testDictationImportCapIsUnchanged() {
        XCTAssertEqual(AudioFileImporter.maxSamples, 16_000 * 1_800)
    }

    // MARK: - The per-job model choices

    /// The single most important property of the wiring: the Transcription
    /// model picker is only real if the model it names is the one that gets
    /// loaded.
    func testTheRunLoadsTheModelTheRequestNamed() async {
        let (store, job) = await seededStore()
        let spy = TranscriberSpy()

        await AppController.performTranscriptionRun(
            jobID: job.id, request: request(),
            audio: StubAudio(sampleCount: 16_000 * 60),
            transcriber: spy, diarizer: nil, store: store, progress: nil)

        let loaded = await spy.loadedModelIDs
        XCTAssertEqual(loaded, [Self.chosenTranscriptionModelID])
        // Guards the fixture itself: if the chosen id ever became the default,
        // this whole test would pass against an implementation that ignored
        // the request entirely.
        XCTAssertNotEqual(Self.chosenTranscriptionModelID, ModelRegistry.defaultModel.id)
        let saved = await store.job(id: job.id)
        XCTAssertEqual(saved?.status, .complete)
        XCTAssertEqual(saved?.segments.first?.text, "hello")
    }

    /// The Language picker is exactly as real as this assertion. A user who
    /// pins French to stop the detector drifting into English on accented
    /// speech must have Whisper told "fr" — and the row then says `language:
    /// "fr"`, so a run that quietly auto-detected would leave the stored job
    /// describing a setting that was never applied.
    func testTheRunPinsTheLanguageTheRequestNamed() async {
        let (store, job) = await seededStore()
        let spy = TranscriberSpy()

        await AppController.performTranscriptionRun(
            jobID: job.id, request: request(language: "fr"),
            audio: StubAudio(sampleCount: 16_000 * 60),
            transcriber: spy, diarizer: nil, store: store, progress: nil)

        let languages = await spy.languages
        XCTAssertFalse(languages.isEmpty, "nothing was transcribed at all")
        XCTAssertEqual(languages, Array(repeating: "fr", count: languages.count))
    }

    /// The other half of the same property: no pin means free detection, not
    /// some default language quietly substituted for the user's silence.
    func testAJobWithNoLanguagePinLetsWhisperDetect() async {
        let (store, job) = await seededStore()
        let spy = TranscriberSpy()

        await AppController.performTranscriptionRun(
            jobID: job.id, request: request(language: nil),
            audio: StubAudio(sampleCount: 16_000 * 60),
            transcriber: spy, diarizer: nil, store: store, progress: nil)

        let languages = await spy.languages
        XCTAssertFalse(languages.isEmpty)
        XCTAssertTrue(languages.allSatisfy { $0 == nil })
    }

    /// Substituting a different model for one that no longer exists would
    /// hand back a transcript at a quality the user never chose, with nothing
    /// saying so. Failing the row is the honest outcome.
    func testAnUnknownTranscriptionModelFailsTheJobInsteadOfSubstitutingAnother() async {
        let (store, job) = await seededStore()
        let spy = TranscriberSpy()

        await AppController.performTranscriptionRun(
            jobID: job.id, request: request(transcriptionModelID: "no-such-model"),
            audio: StubAudio(sampleCount: 16_000 * 60),
            transcriber: spy, diarizer: nil, store: store, progress: nil)

        let loaded = await spy.loadedModelIDs
        let calls = await spy.transcribeCalls
        XCTAssertEqual(loaded, [])
        XCTAssertEqual(calls, 0)
        let saved = await store.job(id: job.id)
        XCTAssertEqual(saved?.status, .failed)
        XCTAssertFalse(saved?.failureNote.isEmpty ?? true,
                       "a failed job must say why")
    }

    /// A model that cannot be brought up must stop the run, not fall through
    /// into a transcription performed by whatever model happened to be
    /// resident already.
    func testAModelThatFailsToLoadStopsTheRun() async {
        let (store, job) = await seededStore()
        let spy = TranscriberSpy(loadError: WisprError.modelNotLoaded)

        await AppController.performTranscriptionRun(
            jobID: job.id, request: request(),
            audio: StubAudio(sampleCount: 16_000 * 60),
            transcriber: spy, diarizer: nil, store: store, progress: nil)

        let calls = await spy.transcribeCalls
        XCTAssertEqual(calls, 0)
        let saved = await store.job(id: job.id)
        XCTAssertEqual(saved?.status, .failed)
        XCTAssertFalse(saved?.failureNote.isEmpty ?? true)
    }

    /// The speaker toggle is a per-job choice too, and it has to reach the
    /// pipeline: a lit toggle that produced an unlabelled transcript would
    /// promise speaker names the transcript does not have.
    func testTheRunHonoursThePerJobSpeakerChoice() async {
        let (store, job) = await seededStore()

        await AppController.performTranscriptionRun(
            jobID: job.id, request: request(diarize: true),
            audio: StubAudio(sampleCount: 16_000 * 60),
            transcriber: TranscriberSpy(),
            diarizer: StubDiarizer(
                spans: [DiarizedSpan(speakerID: "7", start: 0, end: 10)]),
            store: store, progress: nil)

        let saved = await store.job(id: job.id)
        XCTAssertEqual(saved?.segments.first?.speaker, .remote("7"))
    }

    /// The row is what carries every per-job choice forward: `performGenerate`
    /// reads the document model back off it hours after the run, so a choice
    /// dropped here is a choice silently replaced by a default later.
    func testTheJobRowRecordsTheRequestsOwnChoices() {
        let job = AppController.makeJob(
            request: request(path: "/tmp/Weekly sync.m4a",
                             language: "fr", diarize: true),
            durationSeconds: 3_600)

        XCTAssertEqual(job.transcriptionModelID, Self.chosenTranscriptionModelID)
        XCTAssertEqual(job.enhancementModelID, Self.chosenEnhancementModelID)
        XCTAssertNotEqual(Self.chosenEnhancementModelID,
                          CleanupModelRegistry.defaultModel.id)
        XCTAssertEqual(job.language, "fr")
        XCTAssertTrue(job.diarizationRequested)
        XCTAssertEqual(job.title, "Weekly sync")
        XCTAssertEqual(job.sourcePath, "/tmp/Weekly sync.m4a")
        XCTAssertEqual(job.durationSeconds, 3_600)
        XCTAssertEqual(job.status, .processing)
    }

    /// The Document model picker is only real if the model it names is the
    /// one that writes the documents.
    func testGenerateUsesTheModelThisJobWasSetUpWith() async {
        let (store, job) = await seededStore(
            segments: [MeetingTranscriptSegment(speaker: .others, start: 0,
                                                end: 5, text: "hello")])
        let backend = BackendSpy()

        await AppController.performGenerate(
            kind: .cleanTranscript, jobID: job.id, store: store,
            backend: backend, progress: nil)

        let loaded = await backend.loadedModelIDs
        XCTAssertEqual(loaded.first, Self.chosenEnhancementModelID)
        XCTAssertNotEqual(Self.chosenEnhancementModelID,
                          CleanupModelRegistry.defaultModel.id)
        // Proves the generator was actually driven, not merely constructed.
        let saved = await store.job(id: job.id)
        XCTAssertFalse(saved?.cleanTranscript.isEmpty ?? true)
    }

    /// A row created with a different document model must use THAT one — the
    /// test above alone cannot tell "reads the row" from "happens to use a
    /// constant that matches the fixture".
    func testGenerateFollowsTheRowRatherThanAnyFixedModel() async {
        let (store, job) = await seededStore(
            enhancementModelID: "gemma-3-4b",
            segments: [MeetingTranscriptSegment(speaker: .others, start: 0,
                                                end: 5, text: "hello")])
        let backend = BackendSpy()

        await AppController.performGenerate(
            kind: .cleanTranscript, jobID: job.id, store: store,
            backend: backend, progress: nil)

        let loaded = await backend.loadedModelIDs
        XCTAssertEqual(loaded.first, "gemma-3-4b")
    }

    // MARK: - Cleanup-engine repointing

    /// `performGenerate` loads the JOB's document model into the backend that
    /// dictation's `CleanupEngine` shares. The engine is not told, and its
    /// `ensureLoadStarted` short-circuits on a non-nil load task, so every
    /// later dictation would clean up with this job's model — a silent,
    /// permanent switch of a setting the user never changed. This predicate
    /// is what decides to unload the engine around the call.
    func testGeneratingWithADifferentDocumentModelRepointsTheCleanupEngine() {
        XCTAssertTrue(AppController.generateRepointsCleanupModel(
            jobModelID: "gemma-3-4b", dictationModelID: "qwen3-4b"))
    }

    /// The other direction matters as much: unloading when the two already
    /// agree throws away a warm model and buys the next dictation a reload
    /// for nothing.
    func testGeneratingWithTheSameModelLeavesTheCleanupEngineAlone() {
        XCTAssertFalse(AppController.generateRepointsCleanupModel(
            jobModelID: "qwen3-4b", dictationModelID: "qwen3-4b"))
    }

    /// A job with no recorded model — a row written before the field existed,
    /// or a job id that no longer resolves — cannot have repointed anything.
    func testAJobWithNoRecordedModelDoesNotRepointAnything() {
        XCTAssertFalse(AppController.generateRepointsCleanupModel(
            jobModelID: nil, dictationModelID: "qwen3-4b"))
    }
}
