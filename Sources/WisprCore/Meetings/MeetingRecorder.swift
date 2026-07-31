import Foundation

public enum MeetingRecorderError: Error, Equatable {
    case bothSourcesFailed
    case alreadyRecording
}

/// The result of one meeting recording.
///
/// `micURL`/`systemURL` and `micFailed`/`systemFailed` answer two different
/// questions and are **not** derived from each other:
///
/// - `*URL` is non-nil exactly when that track's writer actually captured at
///   least one sample (`MeetingAudioWriter.sampleCount > 0`). A writer that
///   never received audio deletes its own zero-byte file on `finish()`
///   (`MeetingAudioWriter.finishSync`), so there is nothing to return.
/// - `*Failed` reports whether that source stopped working — at start, or
///   partway through.
///
/// The two are independent, and both combinations that look surprising at
/// first are legitimate and expected:
/// - `failed == true` with a **non-nil** URL: the track died mid-meeting but
///   had already captured real audio, which is kept. Losing a track must not
///   discard what it already recorded — that would defeat the entire point
///   of failing open.
/// - `failed == false` with a **nil** URL: the track started and ran cleanly
///   the whole time but the meeting ended (or was empty) before it ever
///   emitted a chunk — e.g. a silent participant who never spoke, or a
///   recording stopped an instant after it started.
public struct MeetingRecordingResult: Sendable {
    public let micURL: URL?
    public let systemURL: URL?
    public let durationSeconds: Double
    public let micFailed: Bool
    public let systemFailed: Bool

    public init(micURL: URL?, systemURL: URL?, durationSeconds: Double,
                micFailed: Bool, systemFailed: Bool) {
        self.micURL = micURL
        self.systemURL = systemURL
        self.durationSeconds = durationSeconds
        self.micFailed = micFailed
        self.systemFailed = systemFailed
    }
}

/// Thread-safe landing pad for chunks arriving on an audio callback thread.
///
/// `MeetingAudioSource.onChunk` is a plain synchronous, non-`async` closure —
/// bridging it into actor-isolated state normally means firing an
/// unstructured `Task { await actor.method() }` per chunk. That works, but it
/// races: the `Task` has to be picked up by the concurrent-executor thread
/// pool before it can even attempt to hop onto the actor, while a caller
/// already running inside an async context (e.g. a test calling
/// `await recorder.stop()` right after `emit()`) hops onto the same actor
/// directly, with no such delay. In practice the direct call consistently
/// wins the race, so a chunk `emit`ted immediately before `stop()` is called
/// can be silently dropped even though `stopped` was still `false` at the
/// moment it arrived.
///
/// The fix is to make the handoff itself synchronous: `append` runs
/// immediately, on the calling (audio) thread, under a lock — no actor hop,
/// no race. The actor drains the buffer both opportunistically (nudged by a
/// best-effort `Task`, coalesced so at most one is in flight per drain cycle
/// no matter how many chunks arrive while it's pending — see
/// `append(_:isMic:)`) and authoritatively (`stop()` drains once more after
/// both sources have been stopped and can no longer append, so nothing
/// captured before `stop()` was called can be lost — see
/// `MeetingRecorder.receive`'s doc comment for why that final drain does not
/// need to special-case `stopped`).
///
/// Each track's queue is capped at `maxBufferSeconds` of audio. Under normal
/// load the queue drains to empty almost immediately after every append, so
/// this never engages — it exists purely as a back-pressure valve for a
/// stalled or slow writer (disk contention, thermal throttling) over a
/// meeting that can run for hours. On overflow the new chunk is refused, not
/// the oldest dropped: dropping the oldest would punch a hole in the middle
/// of otherwise-contiguous audio, whereas refusing the newest just truncates
/// the tail, which is the same trade-off the duration cap already makes.
///
/// Internal rather than `private` so `MeetingRecorderTests` can exercise the
/// overflow cap directly and deterministically — driving 70+ one-second
/// chunks through `MeetingRecorder`'s public API in a tight loop does not
/// reliably reach it, because Swift's concurrent executor is free to run the
/// drain-nudge `Task` on another thread in parallel with the loop, which
/// keeps draining the queue back toward empty and makes the cap a race
/// rather than a certainty from the outside. Talking to `append`/`drain`
/// directly removes the actor and the `Task` scheduler from the picture
/// entirely, the same way `MeetingMicSource.claimStart`/`commitIfCurrent`
/// are `internal` rather than `private` so their own race tests don't need
/// real hardware.
final class ChunkBuffer: @unchecked Sendable {
    /// 60 s per track, computed from `MeetingAudioWriter.sampleRate` rather
    /// than a literal sample count.
    static let maxBufferSeconds: Double = 60
    private static var maxSamplesPerTrack: Int {
        Int(MeetingAudioWriter.sampleRate * maxBufferSeconds)
    }

    private let lock = NSLock()
    private var micChunks: [AudioChunk] = []
    private var systemChunks: [AudioChunk] = []
    private var micQueuedSamples = 0
    private var systemQueuedSamples = 0
    private var micOverflowLogged = false
    private var systemOverflowLogged = false
    private var drainScheduled = false

    /// Appends a chunk, refusing it instead if the track's queue is already
    /// at the cap (logged once per track, not on every subsequent refusal,
    /// so a genuinely stalled drain doesn't spam the log for the rest of the
    /// meeting).
    ///
    /// Returns whether the caller should spawn a drain-nudge `Task`: `true`
    /// only the first time since the queue was last drained, so many chunks
    /// arriving in a row before the actor gets a chance to drain coalesce
    /// into a single pending nudge rather than one `Task` per chunk.
    @discardableResult
    func append(_ chunk: AudioChunk, isMic: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let cap = Self.maxSamplesPerTrack
        if isMic {
            guard micQueuedSamples + chunk.samples.count <= cap else {
                if !micOverflowLogged {
                    micOverflowLogged = true
                    WisprLog.log("meeting recorder: mic chunk buffer exceeded "
                        + "\(Int(Self.maxBufferSeconds))s queued, refusing further chunks")
                }
                return false
            }
            micChunks.append(chunk)
            micQueuedSamples += chunk.samples.count
        } else {
            guard systemQueuedSamples + chunk.samples.count <= cap else {
                if !systemOverflowLogged {
                    systemOverflowLogged = true
                    WisprLog.log("meeting recorder: system chunk buffer exceeded "
                        + "\(Int(Self.maxBufferSeconds))s queued, refusing further chunks")
                }
                return false
            }
            systemChunks.append(chunk)
            systemQueuedSamples += chunk.samples.count
        }
        if drainScheduled {
            return false
        }
        drainScheduled = true
        return true
    }

    /// Removes and returns everything queued so far, and clears the
    /// drain-scheduled flag so the next `append` after this point can
    /// request a fresh nudge. Safe to call repeatedly/concurrently: a call
    /// that finds nothing queued just returns empty arrays.
    func drain() -> (mic: [AudioChunk], system: [AudioChunk]) {
        lock.lock()
        defer { lock.unlock() }
        let mic = micChunks
        let system = systemChunks
        micChunks.removeAll()
        systemChunks.removeAll()
        micQueuedSamples = 0
        systemQueuedSamples = 0
        drainScheduled = false
        return (mic, system)
    }
}

/// Owns the two capture tracks of one meeting and writes each to its own AAC
/// file.
///
/// Either track may fail — at start or mid-recording — without ending the
/// meeting: half a meeting is far more useful than none. Only a double
/// failure at start aborts.
public actor MeetingRecorder {
    /// 3 hours. Past this the recorder stops accepting audio but does not
    /// tear itself down, so the UI can tell the user why.
    public static let defaultMaxDuration: TimeInterval = 10_800

    private let meetingID: UUID
    private var micSource: any MeetingAudioSource
    private var systemSource: any MeetingAudioSource
    private let micURL: URL
    private let systemURL: URL
    private let maxDurationSeconds: TimeInterval

    private var micWriter: MeetingAudioWriter?
    private var systemWriter: MeetingAudioWriter?
    private var micFailed = false
    private var systemFailed = false
    private var recording = false
    private var stopped = false
    private var longestSeconds: Double = 0
    private var capReached = false
    /// Set once `stop()` has drained, finished both writers and computed the
    /// result. Distinct from `stopped`, which is set BEFORE the final drain
    /// precisely so that drain still counts.
    private var finalized = false
    /// Samples actually written to each track, captured from
    /// `MeetingAudioWriter.sampleCount` in `finishWriter` before the writer
    /// is discarded. This — not `micFailed`/`systemFailed` — is what decides
    /// whether `stop()` reports a URL; see `MeetingRecordingResult`'s doc
    /// comment for why the two are independent.
    private var micSamplesWritten = 0
    private var systemSamplesWritten = 0
    /// `nonisolated` so `append` can run synchronously on the calling audio
    /// thread from inside the `onChunk` closures below, with no actor hop —
    /// see `ChunkBuffer`'s doc comment.
    private nonisolated let chunkBuffer = ChunkBuffer()

    public init(meetingID: UUID,
                micSource: any MeetingAudioSource,
                systemSource: any MeetingAudioSource,
                micURL: URL,
                systemURL: URL,
                maxDurationSeconds: TimeInterval = MeetingRecorder.defaultMaxDuration) {
        self.meetingID = meetingID
        self.micSource = micSource
        self.systemSource = systemSource
        self.micURL = micURL
        self.systemURL = systemURL
        self.maxDurationSeconds = maxDurationSeconds
    }

    public var isRecording: Bool { recording }
    public var elapsedSeconds: Double { longestSeconds }
    public var reachedDurationCap: Bool { capReached }

    public func start() async throws {
        guard !recording else { throw MeetingRecorderError.alreadyRecording }

        WisprLog.log("meeting recorder: starting meeting \(meetingID)")

        micWriter = makeWriter(at: micURL, label: "mic")
        systemWriter = makeWriter(at: systemURL, label: "system")

        // The chunk itself lands synchronously, on the calling (audio)
        // thread, via `chunkBuffer.append` — see `ChunkBuffer`'s doc comment
        // for why. `append` returns whether a nudge is actually needed
        // (coalescing back-to-back chunks into a single pending drain); the
        // `Task` spawned when it is is just a best-effort prompt so the
        // actor drains and writes promptly during a live meeting — `stop()`
        // drains authoritatively regardless of whether any nudge ever runs.
        micSource.onChunk = { [weak self] chunk in
            guard let self else { return }
            if self.chunkBuffer.append(chunk, isMic: true) {
                Task { await self.drainChunks() }
            }
        }
        micSource.onFailure = { [weak self] error in
            Task { await self?.trackDied(.mic, error: error) }
        }
        systemSource.onChunk = { [weak self] chunk in
            guard let self else { return }
            if self.chunkBuffer.append(chunk, isMic: false) {
                Task { await self.drainChunks() }
            }
        }
        systemSource.onFailure = { [weak self] error in
            Task { await self?.trackDied(.system, error: error) }
        }

        if micWriter == nil { micFailed = true }
        if systemWriter == nil { systemFailed = true }

        if !micFailed {
            do {
                try await micSource.start()
            } catch {
                WisprLog.log("meeting recorder: mic start FAILED: \(error)")
                micFailed = true
                await finishWriter(.mic)
            }
        }
        if !systemFailed {
            do {
                try await systemSource.start()
            } catch {
                WisprLog.log("meeting recorder: system start FAILED: \(error)")
                systemFailed = true
                await finishWriter(.system)
            }
        }

        guard !(micFailed && systemFailed) else {
            await micSource.stop()
            await systemSource.stop()
            recording = false
            WisprLog.log("meeting recorder: both sources FAILED at start, aborting meeting \(meetingID)")
            throw MeetingRecorderError.bothSourcesFailed
        }
        if micFailed {
            WisprLog.log("meeting recorder: continuing on system audio only")
        }
        if systemFailed {
            WisprLog.log("meeting recorder: continuing on microphone only")
        }
        recording = true
    }

    public func stop() async -> MeetingRecordingResult {
        if !stopped {
            stopped = true
            recording = false
            // Stop the sources BEFORE draining. Both real implementations
            // clear their `onChunk`/`onFailure` handlers under lock before
            // `stop()` returns (`MeetingMicSource`/`SystemAudioSource`
            // `clearState()`), so once these two awaits complete, no further
            // `chunkBuffer.append` can happen from either source — there is
            // no remaining window in which a captured chunk could still be
            // in flight.
            await micSource.stop()
            await systemSource.stop()
            // Authoritative drain of whatever is already queued. See
            // `receive`'s doc comment for why this deliberately does not
            // gate on `stopped`.
            drainChunks()
            await finishWriter(.mic)
            await finishWriter(.system)
            WisprLog.log("meeting recorder: stopped meeting \(meetingID), duration=\(longestSeconds)s")
            // Everything that will ever be counted has been counted. Past this
            // point a straggling chunk must not move `longestSeconds` or trip
            // `capReached`, or `elapsedSeconds`/`reachedDurationCap` would drift
            // out of agreement with the result already handed to the caller.
            finalized = true
        }
        return MeetingRecordingResult(
            micURL: micSamplesWritten > 0 ? micURL : nil,
            systemURL: systemSamplesWritten > 0 ? systemURL : nil,
            durationSeconds: longestSeconds,
            micFailed: micFailed,
            systemFailed: systemFailed)
    }

    // MARK: - Private

    private enum Track { case mic, system }

    private func makeWriter(at url: URL, label: String) -> MeetingAudioWriter? {
        do {
            return try MeetingAudioWriter(url: url)
        } catch {
            WisprLog.log("meeting recorder: \(label) writer FAILED: \(error)")
            return nil
        }
    }

    /// Pulls everything currently queued in `chunkBuffer` and applies it.
    /// Safe to call redundantly (from the best-effort nudge `Task`s and from
    /// `stop()`'s authoritative flush): a call that finds nothing queued is a
    /// no-op.
    private func drainChunks() {
        let (mic, system) = chunkBuffer.drain()
        for chunk in mic { receive(chunk, track: .mic) }
        for chunk in system { receive(chunk, track: .system) }
    }

    /// Applies one drained chunk. Deliberately does NOT gate on `stopped`:
    /// a chunk reaches here only via `drainChunks`, which pulls it out of
    /// `chunkBuffer` — and everything in that buffer was appended by a
    /// source callback that fired before `micSource.stop()`/
    /// `systemSource.stop()` returned in `stop()` (both real sources clear
    /// their `onChunk` handler under lock as part of `stop()`, so no append
    /// can happen after that point). So by construction, almost everything
    /// this method is ever asked to apply was legitimately captured before or
    /// during the stop sequence, and an earlier version of this method that
    /// DID gate on `stopped` combined with the coalesced-nudge scheme above
    /// to actively lose chunks: a nudge `Task` created before `stop()` but
    /// not yet run could fire during `stop()`'s own awaits, after `stopped`
    /// had already flipped to `true`, and would then drain (and discard)
    /// chunks that `stop()`'s own authoritative drain was still relying on
    /// finding.
    ///
    /// `finalized` is the guard that still applies, for a narrower and
    /// genuinely-after-the-fact case the paragraph above doesn't cover: both
    /// real sources' `onChunk` handlers check-then-unlock-then-invoke, so a
    /// handler can read a non-nil callback a moment before `stop()` clears it
    /// under lock and still go on to invoke it — a straggler chunk that
    /// really does arrive after `stop()`'s authoritative `drainChunks()` and
    /// both writer finishes have already computed `longestSeconds`/
    /// `capReached`/the written-sample counts that make up the returned
    /// `MeetingRecordingResult`. `finalized` is set only after all of that
    /// has happened (see its declaration above), so it rejects exactly that
    /// late straggler without discarding anything the result depends on.
    private func receive(_ chunk: AudioChunk, track: Track) {
        guard !capReached, !finalized else { return }
        let end = chunk.hostTime
            + Double(chunk.samples.count) / MeetingAudioWriter.sampleRate
        longestSeconds = max(longestSeconds, end)
        switch track {
        case .mic:
            guard !micFailed else { return }
            micWriter?.append(chunk.samples)
        case .system:
            guard !systemFailed else { return }
            systemWriter?.append(chunk.samples)
        }
        if longestSeconds >= maxDurationSeconds {
            capReached = true
            WisprLog.log("meeting recorder: duration cap reached at \(longestSeconds)s")
        }
    }

    private func trackDied(_ track: Track, error: Error) async {
        guard !stopped else { return }
        WisprLog.log("meeting recorder: \(track) died mid-recording: \(error)")
        switch track {
        case .mic:
            guard !micFailed else { return }
            micFailed = true
            await micSource.stop()
            await finishWriter(.mic)
            WisprLog.log("meeting recorder: mic track lost, continuing on system audio only")
        case .system:
            guard !systemFailed else { return }
            systemFailed = true
            await systemSource.stop()
            await finishWriter(.system)
            WisprLog.log("meeting recorder: system track lost, continuing on microphone only")
        }
        if micFailed && systemFailed {
            recording = false
            WisprLog.log("meeting recorder: both tracks lost mid-recording, ending meeting \(meetingID)")
        }
    }

    /// Finishes and discards the writer for a track, first capturing
    /// whether it ever wrote real audio. Idempotent: if the writer was
    /// already finished and cleared (e.g. by an earlier `trackDied`), this
    /// is a no-op and the previously captured sample count is left alone —
    /// it must not be reset to 0 just because the writer is already gone.
    private func finishWriter(_ track: Track) async {
        switch track {
        case .mic:
            if let writer = micWriter {
                await writer.finish()
                micSamplesWritten = writer.sampleCount
            }
            micWriter = nil
        case .system:
            if let writer = systemWriter {
                await writer.finish()
                systemSamplesWritten = writer.sampleCount
            }
            systemWriter = nil
        }
    }
}
