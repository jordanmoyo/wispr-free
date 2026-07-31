import XCTest
@testable import WisprCore

final class MeetingRecorderTests: XCTestCase {
    private func urls() -> (mic: URL, system: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent("mic.m4a"), dir.appendingPathComponent("sys.m4a"))
    }

    private func makeRecorder(mic: StubAudioSource, system: StubAudioSource,
                              cap: TimeInterval = 10_800)
        -> (MeetingRecorder, mic: URL, system: URL) {
        let paths = urls()
        let recorder = MeetingRecorder(
            meetingID: UUID(), micSource: mic, systemSource: system,
            micURL: paths.mic, systemURL: paths.system, maxDurationSeconds: cap)
        return (recorder, paths.mic, paths.system)
    }

    private func silence(_ count: Int) -> [Float] { [Float](repeating: 0.05, count: count) }

    func testStartsBothSources() async throws {
        let mic = StubAudioSource(), system = StubAudioSource()
        let (recorder, _, _) = makeRecorder(mic: mic, system: system)
        try await recorder.start()
        XCTAssertTrue(mic.started)
        XCTAssertTrue(system.started)
        let recording = await recorder.isRecording
        XCTAssertTrue(recording)
        _ = await recorder.stop()
    }

    func testSecondStartThrows() async throws {
        let mic = StubAudioSource(), system = StubAudioSource()
        let (recorder, _, _) = makeRecorder(mic: mic, system: system)
        try await recorder.start()
        do {
            try await recorder.start()
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? MeetingRecorderError, .alreadyRecording)
        }
        _ = await recorder.stop()
    }

    func testSystemFailureAtStartStillRecordsMic() async throws {
        let mic = StubAudioSource(), system = StubAudioSource()
        system.startError = SystemAudioError.permissionDenied
        let (recorder, _, _) = makeRecorder(mic: mic, system: system)
        try await recorder.start()
        mic.emit(silence(16_000), at: 0)
        let result = await recorder.stop()
        XCTAssertTrue(result.systemFailed)
        XCTAssertFalse(result.micFailed)
        XCTAssertNotNil(result.micURL)
        XCTAssertNil(result.systemURL)
    }

    func testMicFailureAtStartStillRecordsSystem() async throws {
        let mic = StubAudioSource(), system = StubAudioSource()
        mic.startError = WisprError.recordingFailed
        let (recorder, _, _) = makeRecorder(mic: mic, system: system)
        try await recorder.start()
        system.emit(silence(16_000), at: 0)
        let result = await recorder.stop()
        XCTAssertTrue(result.micFailed)
        XCTAssertNil(result.micURL)
        XCTAssertNotNil(result.systemURL)
    }

    func testBothFailuresAtStartThrows() async {
        let mic = StubAudioSource(), system = StubAudioSource()
        mic.startError = WisprError.recordingFailed
        system.startError = SystemAudioError.permissionDenied
        let (recorder, _, _) = makeRecorder(mic: mic, system: system)
        do {
            try await recorder.start()
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? MeetingRecorderError, .bothSourcesFailed)
            let recording = await recorder.isRecording
            XCTAssertFalse(recording)
        }
    }

    func testMidRecordingSystemFailureKeepsMicRunning() async throws {
        let mic = StubAudioSource(), system = StubAudioSource()
        let (recorder, _, systemURL) = makeRecorder(mic: mic, system: system)
        try await recorder.start()
        system.emit(silence(8_000), at: 0)
        system.fail(SystemAudioError.streamFailed("device gone"))
        try await Task.sleep(nanoseconds: 100_000_000)
        mic.emit(silence(16_000), at: 0.5)
        let result = await recorder.stop()
        XCTAssertTrue(result.systemFailed)
        XCTAssertFalse(result.micFailed)
        XCTAssertNotNil(result.micURL)
        // The system track died mid-recording, but it had already captured
        // real audio before it did — that audio must not be discarded from
        // the result just because the track subsequently failed.
        XCTAssertNotNil(result.systemURL)
        XCTAssertEqual(result.systemURL, systemURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: systemURL.path)
        let size = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0)
    }

    func testMidRecordingMicFailureKeepsSystemRunning() async throws {
        let mic = StubAudioSource(), system = StubAudioSource()
        let (recorder, micURL, _) = makeRecorder(mic: mic, system: system)
        try await recorder.start()
        mic.emit(silence(8_000), at: 0)
        mic.fail(WisprError.recordingFailed)
        try await Task.sleep(nanoseconds: 100_000_000)
        system.emit(silence(16_000), at: 0.5)
        let result = await recorder.stop()
        XCTAssertTrue(result.micFailed)
        XCTAssertFalse(result.systemFailed)
        XCTAssertNotNil(result.systemURL)
        // Same contract as the system-side test above, mirrored: the mic
        // track died but keeps the audio it already captured.
        XCTAssertNotNil(result.micURL)
        XCTAssertEqual(result.micURL, micURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
    }

    func testBothTracksDyingMidRecordingEndsRecordingButKeepsCapturedAudio() async throws {
        let mic = StubAudioSource(), system = StubAudioSource()
        let (recorder, micURL, systemURL) = makeRecorder(mic: mic, system: system)
        try await recorder.start()
        mic.emit(silence(8_000), at: 0)
        system.emit(silence(8_000), at: 0)
        mic.fail(WisprError.recordingFailed)
        system.fail(SystemAudioError.streamFailed("device gone"))
        try await Task.sleep(nanoseconds: 100_000_000)
        let recording = await recorder.isRecording
        XCTAssertFalse(recording)
        let result = await recorder.stop()
        XCTAssertTrue(result.micFailed)
        XCTAssertTrue(result.systemFailed)
        // Both died, but both had already captured real audio — the meeting
        // is over, but nothing that was recorded before the double failure
        // is lost.
        XCTAssertNotNil(result.micURL)
        XCTAssertNotNil(result.systemURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
    }

    func testWriterInitFailureForOneTrackStillRecordsTheOther() async throws {
        let mic = StubAudioSource(), system = StubAudioSource()
        // An unwritable directory makes `MeetingAudioWriter(url:)` throw for
        // the mic track specifically — a distinct failure path from the
        // source's own `start()` throwing, since it happens before either
        // source is even started.
        let unwritableDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-unwritable-\(UUID().uuidString)")
        let micURL = unwritableDir.appendingPathComponent("nested").appendingPathComponent("mic.m4a")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let systemURL = dir.appendingPathComponent("sys.m4a")

        let recorder = MeetingRecorder(
            meetingID: UUID(), micSource: mic, systemSource: system,
            micURL: micURL, systemURL: systemURL)
        try await recorder.start()
        // The mic source itself is never even started once its writer fails
        // to open — the ladder treats it the same as any other start-time
        // failure.
        XCTAssertFalse(mic.started)
        XCTAssertTrue(system.started)
        system.emit(silence(16_000), at: 0)
        let result = await recorder.stop()
        XCTAssertTrue(result.micFailed)
        XCTAssertNil(result.micURL)
        XCTAssertFalse(result.systemFailed)
        XCTAssertNotNil(result.systemURL)
    }

    func testWritesBothTracks() async throws {
        let mic = StubAudioSource(), system = StubAudioSource()
        let (recorder, micURL, systemURL) = makeRecorder(mic: mic, system: system)
        try await recorder.start()
        mic.emit(silence(16_000), at: 0)
        system.emit(silence(16_000), at: 0)
        let result = await recorder.stop()
        XCTAssertEqual(result.micURL, micURL)
        XCTAssertEqual(result.systemURL, systemURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
    }

    func testDurationTracksLongestTrack() async throws {
        let mic = StubAudioSource(), system = StubAudioSource()
        let (recorder, _, _) = makeRecorder(mic: mic, system: system)
        try await recorder.start()
        mic.emit(silence(16_000), at: 0)          // 0 → 1 s
        system.emit(silence(48_000), at: 0)       // 0 → 3 s
        let result = await recorder.stop()
        XCTAssertEqual(result.durationSeconds, 3, accuracy: 0.2)
    }

    func testStopsBothSources() async throws {
        let mic = StubAudioSource(), system = StubAudioSource()
        let (recorder, _, _) = makeRecorder(mic: mic, system: system)
        try await recorder.start()
        _ = await recorder.stop()
        XCTAssertTrue(mic.stopped)
        XCTAssertTrue(system.stopped)
        let recording = await recorder.isRecording
        XCTAssertFalse(recording)
    }

    func testStopIsIdempotent() async throws {
        let mic = StubAudioSource(), system = StubAudioSource()
        let (recorder, _, _) = makeRecorder(mic: mic, system: system)
        try await recorder.start()
        mic.emit(silence(16_000), at: 0)
        let first = await recorder.stop()
        let second = await recorder.stop()
        XCTAssertEqual(first.durationSeconds, second.durationSeconds, accuracy: 0.01)
    }

    func testDurationCapStopsAcceptingAudio() async throws {
        let mic = StubAudioSource(), system = StubAudioSource()
        let (recorder, _, _) = makeRecorder(mic: mic, system: system, cap: 2)
        try await recorder.start()
        mic.emit(silence(16_000 * 3), at: 0)      // 3 s, over the 2 s cap
        try await Task.sleep(nanoseconds: 100_000_000)
        let capReached = await recorder.reachedDurationCap
        XCTAssertTrue(capReached)
        mic.emit(silence(16_000), at: 3)
        let result = await recorder.stop()
        // The over-cap chunk was accepted (it crossed the line); the one
        // after was refused, so duration stays at the crossing point.
        XCTAssertLessThan(result.durationSeconds, 3.5)
    }

    func testEmptyRecordingReportsZeroDuration() async throws {
        let mic = StubAudioSource(), system = StubAudioSource()
        let (recorder, micURL, systemURL) = makeRecorder(mic: mic, system: system)
        try await recorder.start()
        let result = await recorder.stop()
        XCTAssertEqual(result.durationSeconds, 0, accuracy: 0.01)
        // Neither track ever captured a chunk, and neither failed — but a
        // zero-sample writer deletes its own file on `finish()`, so both
        // URLs must come back nil rather than pointing at a file that no
        // longer exists.
        XCTAssertFalse(result.micFailed)
        XCTAssertFalse(result.systemFailed)
        XCTAssertNil(result.micURL)
        XCTAssertNil(result.systemURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))
    }

    func testDefaultMaxDurationIsThreeHours() {
        XCTAssertEqual(MeetingRecorder.defaultMaxDuration, 10_800)
    }

    func testChunkBufferOverflowRefusesExcessAudioInsteadOfGrowingUnbounded() {
        // Talks to `ChunkBuffer` directly (it's `internal`, not `private`,
        // precisely for this) rather than through `MeetingRecorder`'s public
        // API: driving chunks through the actor in a loop doesn't reliably
        // reach the cap, because the concurrent executor is free to run the
        // drain-nudge `Task` on another thread in parallel with the loop,
        // which keeps draining the queue back toward empty. Testing the
        // buffer in isolation removes that race entirely.
        let buffer = ChunkBuffer()
        let chunkSamples = 16_000  // 1 s each, at the 16 kHz writer rate.
        let chunksPerTrack = Int(MeetingAudioWriter.sampleRate * ChunkBuffer.maxBufferSeconds)
            / chunkSamples  // 60
        for i in 0..<(chunksPerTrack + 10) {
            let chunk = AudioChunk(samples: [Float](repeating: 0.05, count: chunkSamples),
                                    hostTime: Double(i))
            buffer.append(chunk, isMic: true)
        }
        let (mic, _) = buffer.drain()
        // Only the chunks that fit within the 60 s cap were accepted into
        // the queue; the other 10 were refused rather than growing it
        // without bound.
        XCTAssertEqual(mic.count, chunksPerTrack)
        let totalSamples = mic.reduce(0) { $0 + $1.samples.count }
        XCTAssertEqual(totalSamples, chunksPerTrack * chunkSamples)
    }
}
