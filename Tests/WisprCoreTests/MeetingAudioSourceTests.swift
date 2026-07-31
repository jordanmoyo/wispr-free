import AVFoundation
import XCTest
@testable import WisprCore

final class MeetingAudioSourceTests: XCTestCase {
    func testAudioChunkCarriesSamplesAndTime() {
        let chunk = AudioChunk(samples: [0.1, 0.2], hostTime: 4.5)
        XCTAssertEqual(chunk.samples, [0.1, 0.2])
        XCTAssertEqual(chunk.hostTime, 4.5)
    }

    func testStubDeliversChunks() async throws {
        let source = StubAudioSource()
        let received = Locked<[AudioChunk]>([])
        source.onChunk = { chunk in received.withLock { $0.append(chunk) } }
        try await source.start()
        source.emit([1, 2, 3], at: 0)
        source.emit([4], at: 1)
        XCTAssertTrue(source.started)
        XCTAssertEqual(received.withLock { $0.count }, 2)
        XCTAssertEqual(received.withLock { $0[1].hostTime }, 1)
    }

    func testStubDeliversFailure() async throws {
        let source = StubAudioSource()
        let failed = Locked(false)
        source.onFailure = { _ in failed.withLock { $0 = true } }
        try await source.start()
        source.fail(WisprError.recordingFailed)
        XCTAssertTrue(failed.withLock { $0 })
    }

    func testStubStartErrorThrows() async {
        let source = StubAudioSource()
        source.startError = WisprError.recordingFailed
        do {
            try await source.start()
            XCTFail("expected throw")
        } catch {
            XCTAssertFalse(source.started)
        }
    }

    func testStubRecordsStop() async throws {
        let source = StubAudioSource()
        try await source.start()
        await source.stop()
        XCTAssertTrue(source.stopped)
    }

    /// Fix round 1, finding 2 (stub side): `stop()` must clear both handlers
    /// so a straggling emit after stop can't be mistaken for live delivery,
    /// and so the stub can't mask the same bug in later tasks' tests.
    func testStubClearsHandlersOnStop() async throws {
        let source = StubAudioSource()
        source.onChunk = { _ in }
        source.onFailure = { _ in }
        try await source.start()
        await source.stop()
        XCTAssertNil(source.onChunk)
        XCTAssertNil(source.onFailure)
    }

    func testMicSourceStopBeforeStartIsSafe() async {
        let source = MeetingMicSource(deviceUID: nil)
        await source.stop()
        await source.stop()   // idempotent, no crash
    }

    /// Strengthened from the brief's original (which only checked the
    /// nil-by-default case, trivially true against a no-op). This also
    /// round-trips the handler properties, which a no-op getter/setter pair
    /// would fail.
    func testMicSourceHandlerPropertiesRoundTrip() {
        let source = MeetingMicSource(deviceUID: nil)
        XCTAssertNil(source.onChunk)
        XCTAssertNil(source.onFailure)

        source.onChunk = { _ in }
        source.onFailure = { _ in }
        XCTAssertNotNil(source.onChunk)
        XCTAssertNotNil(source.onFailure)
    }

    /// Fix round 1, finding 2 (mic source side): `stop()` clears both
    /// handlers even when called on a source that never successfully
    /// started — no hardware needed, since `clearState()` unconditionally
    /// nils the handlers regardless of whether an engine exists.
    func testMicSourceStopClearsHandlers() async {
        let source = MeetingMicSource(deviceUID: nil)
        source.onChunk = { _ in }
        source.onFailure = { _ in }
        await source.stop()
        XCTAssertNil(source.onChunk)
        XCTAssertNil(source.onFailure)
    }

    /// Fix round 1, finding 4: a second `start()` claim while already
    /// active must be rejected rather than silently leaking the first
    /// engine's tap/observer. Exercises `claimStart()` directly (internal,
    /// not private, exactly so this is testable without live hardware) —
    /// no `AVAudioEngine` is ever started here.
    func testMicSourceSecondClaimWhileActiveIsRejected() {
        let source = MeetingMicSource(deviceUID: nil)
        let first = source.claimStart()
        XCTAssertNotNil(first)
        let second = source.claimStart()
        XCTAssertNil(second)
    }

    /// Fix round 1, finding 4 (continued): after aborting a failed start,
    /// the source must accept a fresh claim rather than staying wedged
    /// "active" forever.
    func testMicSourceAbortStartAllowsFreshClaim() {
        let source = MeetingMicSource(deviceUID: nil)
        guard let epoch = source.claimStart() else {
            return XCTFail("expected first claim to succeed")
        }
        source.abortStart(epoch: epoch)
        XCTAssertNotNil(source.claimStart())
    }

    /// Fix round 1, finding 3: a `start()` that is mid-flight when a
    /// concurrent `stop()` lands must not commit its engine — the caller
    /// would otherwise leak a running engine nobody holds a handle to.
    /// Drives `claimStart`/`clearState`/`commitIfCurrent` directly to
    /// reproduce the interleaving deterministically; the `AVAudioEngine`
    /// passed to `commitIfCurrent` is never started, so this needs no
    /// hardware or microphone permission.
    func testMicSourceCommitFailsAfterConcurrentStop() {
        let source = MeetingMicSource(deviceUID: nil)
        guard let epoch = source.claimStart() else {
            return XCTFail("expected first claim to succeed")
        }
        // Simulate a concurrent stop() landing before this start() commits.
        _ = source.clearState()

        let engine = AVAudioEngine()
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("MeetingAudioSourceTests.dummy"), object: nil, queue: nil
        ) { _ in }
        defer { NotificationCenter.default.removeObserver(observer) }

        let committed = source.commitIfCurrent(epoch: epoch, engine: engine, observer: observer)
        XCTAssertFalse(committed)
    }

    /// The tap and the configuration-change observer discriminate stale
    /// callbacks by comparing the epoch they were installed under against the
    /// current one, so a superseded engine's callback cannot deliver audio into
    /// a newer session. That only works if the epoch strictly advances across a
    /// start/stop/start cycle — a reused epoch would make a stale callback look
    /// current. This pins that invariant; the callbacks themselves need live
    /// audio hardware to fire and are covered by the guard's construction.
    func testMicSourceEpochAdvancesAcrossRestart() {
        let source = MeetingMicSource(deviceUID: nil)
        guard let first = source.claimStart() else {
            return XCTFail("expected first claim to succeed")
        }
        _ = source.clearState()
        guard let second = source.claimStart() else {
            return XCTFail("expected a fresh claim after clearState")
        }
        XCTAssertNotEqual(first, second, "a reused epoch would let a stale tap deliver")
        XCTAssertGreaterThan(second, first)
    }

    // MARK: - Configuration change recovery

    /// Helper: a committed session whose engine is not running — exactly what
    /// a configuration change that stopped the engine leaves behind. Needs no
    /// hardware: an `AVAudioEngine` that was never started reads as stopped.
    private func committedDeadSession() -> (MeetingMicSource, Int, NSObjectProtocol) {
        let source = MeetingMicSource(deviceUID: nil)
        let epoch = source.claimStart()!
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("MeetingAudioSourceTests.dummy"), object: nil, queue: nil
        ) { _ in }
        XCTAssertTrue(
            source.commitIfCurrent(epoch: epoch, engine: AVAudioEngine(), observer: observer))
        return (source, epoch, observer)
    }

    /// The bug this closes: a Bluetooth headset connecting — or the output
    /// device switching — stopped the engine, and Meetings reported the track
    /// lost instead of rebuilding it the way dictation's `Recorder` always
    /// has. Seen live: the mic died 13s into a meeting and the transcript came
    /// out system-audio-only.
    func testAStoppedEngineAsksForARestartRatherThanLosingTheTrack() {
        let (source, epoch, observer) = committedDeadSession()
        defer { NotificationCenter.default.removeObserver(observer) }

        guard case .restart(let claim) = source.beginRecovery(epoch: epoch) else {
            return XCTFail("a stopped engine must be restarted, not abandoned")
        }
        XCTAssertEqual(claim.attempt, 1)
        XCTAssertNotNil(claim.engine, "the dead engine must be handed over for teardown")
    }

    /// Two notifications arriving together must not both claim the same
    /// engine — the second would tear down an engine the first already
    /// rebuilt over.
    func testASecondConcurrentNotificationFindsNoEngineToClaim() {
        let (source, epoch, observer) = committedDeadSession()
        defer { NotificationCenter.default.removeObserver(observer) }

        guard case .restart(let first) = source.beginRecovery(epoch: epoch) else {
            return XCTFail("expected the first notification to claim the engine")
        }
        guard case .restart(let second) = source.beginRecovery(epoch: epoch) else {
            return XCTFail("expected a restart decision, with nothing left to tear down")
        }
        XCTAssertNotNil(first.engine)
        XCTAssertNil(second.engine, "the engine was already claimed by the first notification")
    }

    /// Retrying forever would keep a dead track nominally alive for the whole
    /// meeting. After the budget the recorder must be told, so it can carry on
    /// with system audio alone.
    func testAnEngineThatKeepsDyingGivesUpSoTheRecorderIsTold() {
        let (source, epoch, observer) = committedDeadSession()
        defer { NotificationCenter.default.removeObserver(observer) }

        for attempt in 1...3 {
            guard case .restart(let claim) = source.beginRecovery(epoch: epoch) else {
                return XCTFail("attempt \(attempt) should still restart")
            }
            XCTAssertEqual(claim.attempt, attempt)
        }
        guard case .giveUp = source.beginRecovery(epoch: epoch) else {
            return XCTFail("the fourth death must give up, not restart a fifth time")
        }
    }

    /// A notification for a superseded or already-stopped session must not
    /// resurrect anything.
    func testAStaleNotificationIsIgnored() {
        let (source, epoch, observer) = committedDeadSession()
        defer { NotificationCenter.default.removeObserver(observer) }

        guard case .ignore = source.beginRecovery(epoch: epoch - 1) else {
            return XCTFail("a notification from a superseded engine must be ignored")
        }
        _ = source.clearState()
        guard case .ignore = source.beginRecovery(epoch: epoch) else {
            return XCTFail("a notification after stop() must be ignored")
        }
    }

    /// A restart continues the session's timeline. Zeroing it — which is
    /// correct for a cold start, and is what `commitIfCurrent` does — would
    /// stamp every sample after the device switch back at 00:00, overlapping
    /// everything already recorded.
    func testARestartContinuesTheTimelineWhereAColdStartResetsIt() {
        let (source, epoch, observer) = committedDeadSession()
        defer { NotificationCenter.default.removeObserver(observer) }
        source.elapsedSamplesForTesting = 48_000

        XCTAssertTrue(source.commitRecovery(
            epoch: epoch, engine: AVAudioEngine(), observer: observer))
        XCTAssertEqual(source.elapsedSamplesForTesting, 48_000,
                       "a restarted engine must not rewind the meeting's clock")

        XCTAssertTrue(source.commitIfCurrent(
            epoch: epoch, engine: AVAudioEngine(), observer: observer))
        XCTAssertEqual(source.elapsedSamplesForTesting, 0,
                       "a cold start does start at zero")
    }

    /// `stop()` racing a restart: nothing may be installed afterwards, or the
    /// engine leaks running past the end of the meeting.
    func testARestartThatLosesToStopIsNotInstalled() {
        let (source, epoch, observer) = committedDeadSession()
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = source.beginRecovery(epoch: epoch)
        _ = source.clearState()

        XCTAssertFalse(source.commitRecovery(
            epoch: epoch, engine: AVAudioEngine(), observer: observer))
    }
}

/// Minimal mutex box so tests can mutate state from `@Sendable` callbacks.
/// Add this to the test target if it does not already have one — later
/// tasks reuse this exact name and shape.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
