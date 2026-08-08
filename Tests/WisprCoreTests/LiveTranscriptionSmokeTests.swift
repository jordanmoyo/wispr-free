import XCTest
@testable import WisprCore

/// A REAL run: a real audio file, the real WhisperKit model on disk, the real
/// chunking and the real store. Everything else in this suite substitutes the
/// transcriber, and a green suite has already shipped defects that one real
/// pass caught immediately — a decode that produced silence, a chunk boundary
/// that dropped a sentence. Doubles cannot find those.
///
/// Skipped unless `WISPR_LIVE=1`, because it loads gigabytes of model weights
/// and takes minutes:
///
///     WISPR_LIVE=1 WISPR_LIVE_AUDIO=/path/to/clip.m4a \
///         swift test --filter LiveTranscriptionSmokeTests
///
/// `WISPR_LIVE_MODEL` picks the model id (default `large-v3-turbo`), and
/// `WISPR_LIVE_EXPECT` is a comma-separated list of words the transcript must
/// contain. Document generation is deliberately NOT exercised here: it runs
/// through MLX, whose Metal shaders `swift test` cannot compile, so the
/// process would abort rather than fail.
final class LiveTranscriptionSmokeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["WISPR_LIVE"] == "1" else {
            throw XCTSkip("set WISPR_LIVE=1 to run the live transcription pass")
        }
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wispr-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func testTranscribesARealFileEndToEnd() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try XCTUnwrap(environment["WISPR_LIVE_AUDIO"],
                                 "set WISPR_LIVE_AUDIO to an audio file")
        let modelID = environment["WISPR_LIVE_MODEL"] ?? "large-v3-turbo"
        let expected = (environment["WISPR_LIVE_EXPECT"] ?? "")
            .split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }.filter { !$0.isEmpty }

        let model = try XCTUnwrap(ModelRegistry.model(id: modelID),
                                  "unknown model id \(modelID)")
        let modelStore = ModelStore.defaultStore()
        try XCTSkipUnless(modelStore.isInstalled(model),
                          "\(model.displayName) is not installed")

        let reader = try AudioFileReader(url: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(reader.sampleCount, 0, "the file decoded to nothing")

        let transcriber = Transcriber(modelStore: modelStore)
        try await transcriber.load(model: model)

        let store = TranscriptionJobStore(directoryURL: directory)
        let job = TranscriptionJob(
            title: "live smoke", createdAt: Date(), sourcePath: path,
            durationSeconds: reader.durationSeconds,
            transcriptionModelID: model.id, enhancementModelID: "qwen3-4b",
            diarizationRequested: false)
        await store.upsert(job)

        // Progress must be monotonic and reach 1.0 — the bar is the only thing
        // the user sees for the length of a two-hour run.
        let progress = ProgressRecorder()
        await TranscriptionPipeline.transcribe(
            jobID: job.id, audio: reader, diarize: false,
            transcriber: transcriber, diarizer: nil, store: store,
            progress: { progress.record($0) })

        let stored = await store.job(id: job.id)
        let saved = try XCTUnwrap(stored)
        XCTAssertFalse(saved.segments.isEmpty, "no segments came back")
        XCTAssertEqual(saved.status, .complete,
                       "status \(saved.status): \(saved.failureNote ?? "no note")")

        let text = saved.segments.map(\.text).joined(separator: " ").lowercased()
        for word in expected {
            XCTAssertTrue(text.contains(word),
                          "transcript is missing \"\(word)\": \(text)")
        }

        XCTAssertEqual(progress.last ?? 0, 1.0, accuracy: 0.001,
                       "the bar never reached 100%")
        XCTAssertTrue(progress.isMonotonic, "progress went backwards: \(progress.values)")

        // Printed, not asserted: the point of a live pass is that a person
        // reads what the model actually produced.
        print("LIVE TRANSCRIPT (\(saved.segments.count) segments):\n\(text)")
    }
}

/// Records the `@Sendable` progress callback under a lock — the same pattern
/// the rest of the suite uses for synchronous callbacks.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    func record(_ progress: TranscriptionProgress) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(progress.fraction)
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var last: Double? { values.last }

    var isMonotonic: Bool {
        let all = values
        return zip(all, all.dropFirst()).allSatisfy { $0 <= $1 }
    }
}
