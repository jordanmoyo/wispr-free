import AVFoundation
import CoreAudio
import Foundation

/// Captures the local microphone for a meeting on a dedicated
/// `AVAudioEngine`.
///
/// It deliberately does NOT share `Recorder`'s engine: a device that fails
/// mid-binding permanently wedges an `AVAudioEngine` instance, and a meeting
/// must never be able to take dictation down with it.
public final class MeetingMicSource: MeetingAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var elapsedSamples = 0
    private let deviceUID: String?

    /// Engine restarts spent on the current session, and the ceiling on
    /// them. A headset connecting or an output device switching is a
    /// one-off; an engine that dies three times in a row is a device that
    /// is not coming back, and retrying forever would keep a dead track
    /// "alive" for the rest of the meeting instead of telling
    /// `MeetingRecorder` to carry on without it.
    private var recoveries = 0
    private static let maxRecoveries = 3

    /// Configuration-change notifications arrive on whatever thread posted
    /// them, and rebuilding an engine is not something to do on the audio
    /// system's own thread. Serial, so two changes in quick succession
    /// recover one at a time.
    private let recoveryQueue = DispatchQueue(label: "wispr.meeting.mic.recovery")

    /// True from the moment a `start()` call claims the source until
    /// `stop()` clears it. Guards against a second concurrent/reentrant
    /// `start()` and gives the audio tap a fast way to bail once stopped.
    private var isActive = false
    /// Bumped every time `start()` claims the source. Lets a `start()` that
    /// began before a concurrent `stop()` detect, at commit time, that it
    /// was superseded — see `commitIfCurrent`.
    private var epoch = 0

    private var _onChunk: (@Sendable (AudioChunk) -> Void)?
    private var _onFailure: (@Sendable (Error) -> Void)?

    public var onChunk: (@Sendable (AudioChunk) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onChunk }
        set { lock.lock(); defer { lock.unlock() }; _onChunk = newValue }
    }

    public var onFailure: (@Sendable (Error) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFailure }
        set { lock.lock(); defer { lock.unlock() }; _onFailure = newValue }
    }

    /// `deviceUID` is the CoreAudio device UID to capture from, or nil to
    /// follow the system default input.
    public init(deviceUID: String?) {
        self.deviceUID = deviceUID
    }

    public func start() async throws {
        guard let myEpoch = claimStart() else {
            WisprLog.log("meeting mic: start() called while already started — ignoring")
            return
        }

        let engine: AVAudioEngine
        let observer: NSObjectProtocol
        do {
            (engine, observer) = try buildAndStartEngine(epoch: myEpoch)
        } catch {
            abortStart(epoch: myEpoch)
            throw error
        }

        if !commitIfCurrent(epoch: myEpoch, engine: engine, observer: observer) {
            // A concurrent `stop()` landed between our claim and this commit.
            // Nobody holds a handle on this engine anymore — tear down the
            // one we just brought up rather than leaking it running forever.
            WisprLog.log("meeting mic: start() superseded by a concurrent stop(), tearing down")
            teardown(engine: engine, observer: observer)
        }
    }

    /// Builds a fresh engine bound to the preferred device, installs the
    /// tap and the configuration-change observer, and starts it. Used by
    /// both the cold start and the mid-meeting restart, so a recovered
    /// track behaves exactly like a freshly started one.
    ///
    /// On any throw it has already undone everything it installed.
    private func buildAndStartEngine(
        epoch myEpoch: Int
    ) throws -> (AVAudioEngine, NSObjectProtocol) {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Bind the preferred device, exactly as `Recorder` does. A failure
        // here is not fatal: fall through to the system default input rather
        // than refusing to record the meeting.
        if let deviceUID, let deviceID = AudioInputDevices.deviceID(forUID: deviceUID) {
            if let audioUnit = input.audioUnit {
                var id = deviceID
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0,
                    &id, UInt32(MemoryLayout<AudioDeviceID>.size))
                if status != noErr {
                    WisprLog.log("meeting mic: device bind FAILED status=\(status), using default")
                }
            } else {
                // A fresh, unprepared input node can legitimately have no
                // audio unit yet. Mirror `Recorder.applyPreferredDevice`:
                // fall through to the system default rather than trap.
                WisprLog.log("meeting mic: input node has no audio unit, using default")
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw WisprError.recordingFailed
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = AudioResampler.resampleToWhisperFormat(buffer)
            guard !samples.isEmpty else { return }
            self.lock.lock()
            // Bail without delivering unless this tap still belongs to the
            // live session. `isActive` alone is not enough: a callback from a
            // superseded engine can land after a NEWER start() has set
            // isActive back to true, and would then advance that session's
            // elapsedSamples with stale audio. Comparing the epoch this tap
            // was installed under pins delivery to its own session.
            guard self.isActive, self.epoch == myEpoch, let handler = self._onChunk else {
                self.lock.unlock()
                return
            }
            let offset = Double(self.elapsedSamples) / AudioResampler.targetSampleRate
            self.elapsedSamples += samples.count
            self.lock.unlock()
            handler(AudioChunk(samples: samples, hostTime: offset))
        }

        // A device switched or yanked mid-meeting surfaces here.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil
        ) { [weak self] _ in
            self?.recoveryQueue.async {
                self?.handleConfigurationChange(epoch: myEpoch)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            NotificationCenter.default.removeObserver(observer)
            WisprLog.log("meeting mic: engine start FAILED: \(error)")
            throw WisprError.recordingFailed
        }

        return (engine, observer)
    }

    // MARK: - Configuration change recovery

    /// Rebuilds the engine when a configuration change stops it, rather than
    /// losing the microphone for the rest of the meeting.
    ///
    /// `Recorder` has always done this for dictation; Meetings reported the
    /// failure and gave up, so a Bluetooth headset connecting — or the
    /// output device switching, which is enough on its own — cost the whole
    /// mic track. Observed live: 13 seconds into a meeting the engine
    /// stopped, the track was dropped, and the transcript came out
    /// system-audio-only and marked `.partial`.
    ///
    /// Audio during the dropout is genuinely gone. `elapsedSamples` is
    /// carried across the restart unchanged, so timestamps stay monotonic
    /// and no segment overlaps another; the cost is that everything after
    /// the gap reads earlier than it happened by the length of the gap,
    /// which for a device switch is a fraction of a second.
    private func handleConfigurationChange(epoch myEpoch: Int) {
        switch beginRecovery(epoch: myEpoch) {
        case .ignore:
            return
        case .giveUp:
            WisprLog.log("meeting mic: engine died \(Self.maxRecoveries) times, giving up on the track")
            reportFailure(epoch: myEpoch)
        case .restart(let claim):
            WisprLog.log("meeting mic: engine stopped after configuration change,"
                + " restarting (attempt \(claim.attempt))")
            teardown(engine: claim.engine, observer: claim.observer)
            do {
                let (engine, observer) = try buildAndStartEngine(epoch: myEpoch)
                if commitRecovery(epoch: myEpoch, engine: engine, observer: observer) {
                    WisprLog.log("meeting mic: engine restarted, track intact")
                } else {
                    // `stop()` won the race; nothing holds this engine.
                    teardown(engine: engine, observer: observer)
                }
            } catch {
                WisprLog.log("meeting mic: restart after configuration change FAILED: \(error)")
                reportFailure(epoch: myEpoch)
            }
        }
    }

    private func teardown(engine: AVAudioEngine?, observer: NSObjectProtocol?) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func reportFailure(epoch myEpoch: Int) {
        lock.lock()
        guard isActive, epoch == myEpoch, let handler = _onFailure else {
            lock.unlock()
            return
        }
        lock.unlock()
        handler(WisprError.recordingFailed)
    }

    /// The engine and observer a recovery has taken ownership of, and which
    /// attempt this is. Both may be nil if the session was committed
    /// without them.
    struct RecoveryClaim {
        let engine: AVAudioEngine?
        let observer: NSObjectProtocol?
        let attempt: Int
    }

    enum RecoveryDecision {
        /// Stale notification, or the engine rode the change out — do nothing.
        case ignore
        /// Rebuild the engine; tear down what the claim carries first.
        case restart(RecoveryClaim)
        /// Out of attempts — tell the recorder the track is lost.
        case giveUp
    }

    /// Decides what a configuration-change notification means for this
    /// session and, when it means a restart, hands over the dead engine.
    ///
    /// Clearing `engine`/`configObserver` inside the same locked section is
    /// what makes two notifications arriving together safe: the second one
    /// finds no engine to claim. Internal (see `claimStart`) so tests can
    /// drive the decision without real audio hardware — a committed but
    /// never-started `AVAudioEngine` reads as not running, exactly like one
    /// a configuration change has stopped.
    func beginRecovery(epoch myEpoch: Int) -> RecoveryDecision {
        lock.lock(); defer { lock.unlock() }
        guard isActive, epoch == myEpoch else { return .ignore }
        guard !(engine?.isRunning ?? false) else { return .ignore }
        guard recoveries < Self.maxRecoveries else { return .giveUp }
        recoveries += 1
        let claim = RecoveryClaim(engine: engine, observer: configObserver, attempt: recoveries)
        engine = nil
        configObserver = nil
        return .restart(claim)
    }

    /// Installs a restarted engine. Unlike `commitIfCurrent` this must NOT
    /// reset `elapsedSamples` — the session's timeline continues across the
    /// gap rather than restarting at zero and overlapping everything
    /// recorded before the device changed.
    func commitRecovery(
        epoch myEpoch: Int, engine: AVAudioEngine, observer: NSObjectProtocol
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard epoch == myEpoch, isActive else { return false }
        self.engine = engine
        self.configObserver = observer
        return true
    }

    /// Test seam for the tap's running sample position — the tap itself only
    /// advances it from real audio, and `commitRecovery`'s contract is that
    /// this survives a restart while `commitIfCurrent`'s zeroes it.
    var elapsedSamplesForTesting: Int {
        get { lock.lock(); defer { lock.unlock() }; return elapsedSamples }
        set { lock.lock(); defer { lock.unlock() }; elapsedSamples = newValue }
    }

    /// Claims the source for a new start attempt. Returns nil (no-op, do
    /// not proceed) if already active — guards against a reentrant/second
    /// concurrent `start()` leaking the previous engine's tap and observer.
    /// Otherwise marks the source active and returns a fresh epoch that the
    /// caller must present unchanged to `commitIfCurrent`/`abortStart`.
    ///
    /// Internal rather than `private` so `MeetingAudioSourceTests` can
    /// exercise the start/stop race and reentrancy guard directly and
    /// deterministically, without touching real audio hardware — not part
    /// of the public API, still invisible outside this module.
    func claimStart() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !isActive else { return nil }
        isActive = true
        recoveries = 0
        epoch += 1
        return epoch
    }

    /// Undoes `claimStart` after this attempt failed before reaching
    /// engine/tap setup completion, but only if nothing superseded it in
    /// the meantime (a concurrent `stop()`, or — impossible without a prior
    /// `stop()` — a newer `start()`). If superseded, that other call already
    /// owns (or has already cleared) `isActive`, so this is a no-op.
    func abortStart(epoch: Int) {
        lock.lock(); defer { lock.unlock() }
        guard epoch == self.epoch else { return }
        isActive = false
    }

    /// Synchronous body of the post-start bookkeeping, kept separate so the
    /// lock is taken and released entirely inside an ordinary (non-`async`)
    /// function — see `MeetingAudioWriter.finishSync()` for why holding an
    /// `NSLock` directly inside an `async func` is a Swift 6 language-mode
    /// error.
    ///
    /// Returns false if a concurrent `stop()` (or, impossible on its own, a
    /// newer `start()`) ran since `epoch` was claimed — the caller must then
    /// tear down the engine and observer it just built instead of storing
    /// them, since nothing else holds a handle to stop them later.
    func commitIfCurrent(epoch: Int, engine: AVAudioEngine, observer: NSObjectProtocol) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard epoch == self.epoch, isActive else { return false }
        self.engine = engine
        self.configObserver = observer
        self.elapsedSamples = 0
        return true
    }

    public func stop() async {
        let (engine, observer) = clearState()
        teardown(engine: engine, observer: observer)
    }

    /// Synchronous body of `stop()`'s state teardown; see the concurrency
    /// note above `commitIfCurrent`. Clears the chunk/failure handlers in
    /// the same locked section so a tap callback already in flight when
    /// `stop()` is called reads a nil handler (and, independently, sees
    /// `isActive == false`) rather than delivering into a track the caller
    /// believes is finalised. Internal (see `claimStart`) so tests can drive
    /// it directly to simulate a `stop()` racing an in-flight `start()`.
    func clearState() -> (AVAudioEngine?, NSObjectProtocol?) {
        lock.lock(); defer { lock.unlock() }
        isActive = false
        let engine = self.engine
        let observer = self.configObserver
        self.engine = nil
        self.configObserver = nil
        self._onChunk = nil
        self._onFailure = nil
        return (engine, observer)
    }
}
