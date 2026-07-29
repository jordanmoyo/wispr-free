import AVFoundation

/// Captures microphone audio via `AVAudioEngine`, gated by push-to-talk.
///
/// Concurrency discipline: `sampleQueue` guards tap-shared state only
/// (`mode`, `samples`, `ring`, `seedCount`, `buffersSeen`, `rawFrames`);
/// `AVAudioEngine` calls (`installTap`, `removeTap`, `engine.start`/`stop`,
/// `connect`) stay outside the lock. `removeTap` blocks until any in-flight
/// tap callback returns, and that callback itself calls `sampleQueue.sync`
/// — holding the lock across an engine call would deadlock main against the
/// audio thread. Engine-call ordering is instead guaranteed by every public
/// entry point (`start`, `stop`, `preRollEnabled`, the configuration-change
/// handler) running serialized on the main thread.
public final class Recorder {
    /// Ring capacity for pre-roll: 0.5 s at the 16 kHz target sample rate.
    private static let ringCapacity = 8000

    private enum Mode: Equatable, CustomStringConvertible {
        case stopped
        case idle
        case recording

        var description: String {
            switch self {
            case .stopped: return "stopped"
            case .idle: return "idle"
            case .recording: return "recording"
            }
        }
    }

    public struct StopResult {
        /// All samples captured for this session, including any pre-roll
        /// seed audio at the front.
        public let samples: [Float]
        /// Samples captured strictly after `start()` was called (excludes
        /// pre-roll seed) — the count that gates dictation.
        public let sessionSampleCount: Int
    }

    private let engine = AVAudioEngine()
    private var mode: Mode = .stopped
    private var samples: [Float] = []
    private var ring = RingBuffer(capacity: Recorder.ringCapacity)
    private var seedCount = 0
    private let sampleQueue = DispatchQueue(label: "wispr.recorder.samples")
    private var buffersSeen = 0
    private var rawFrames = 0
    private var configObserver: NSObjectProtocol?

    /// Called on the main queue with the RMS level (0...1) of each captured
    /// buffer. Only fires while `mode == .recording`.
    public var onLevel: ((Float) -> Void)?

    /// When enabled, the engine stays running (tap installed, muted render
    /// chain) between dictations so the last 0.5 s of audio before the
    /// hotkey is pressed can be included in the transcription. Setting this
    /// to true starts an idle-mode engine (if the mic is available); setting
    /// it to false while idle tears the engine down. The caller
    /// (AppController) is responsible for only enabling this once the
    /// microphone permission is confirmed granted.
    public var preRollEnabled: Bool = false {
        didSet {
            guard preRollEnabled != oldValue else { return }
            if preRollEnabled {
                let needsStart = sampleQueue.sync { mode == .stopped }
                guard needsStart else { return }
                startIdleEngine()
            } else {
                let needsTeardown = sampleQueue.sync { mode == .idle }
                guard needsTeardown else { return }
                teardownEngine()
                sampleQueue.sync {
                    mode = .stopped
                    WisprLog.log("Recorder: mode -> stopped (preRoll disabled)")
                }
            }
        }
    }

    public init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.handleConfigurationChange() }
        }
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    public func start() throws {
        var needsColdStart = false
        sampleQueue.sync {
            switch mode {
            case .recording:
                // Already recording — belt-and-braces guard; AppController's
                // phase machine should already prevent this.
                WisprLog.log("Recorder: start() called while already recording — ignoring")
            case .idle:
                samples = ring.snapshot()
                seedCount = samples.count
                ring.clear()
                buffersSeen = 0
                rawFrames = 0
                mode = .recording
                WisprLog.log("Recorder: mode -> recording (from idle, seed=\(seedCount))")
            case .stopped:
                samples.removeAll()
                seedCount = 0
                buffersSeen = 0
                rawFrames = 0
                needsColdStart = true
            }
        }

        guard needsColdStart else { return }
        try installTapAndStartEngine()
        sampleQueue.sync {
            mode = .recording
            WisprLog.log("Recorder: mode -> recording (cold start)")
        }
    }

    /// Stops capture and returns the samples recorded for this session.
    public func stop() -> StopResult {
        var needsTeardown = false
        let result: StopResult = sampleQueue.sync {
            guard mode == .recording else {
                // Spurious call (mode already .idle or .stopped) — never crash.
                return StopResult(samples: [], sessionSampleCount: 0)
            }
            let sessionCount = samples.count - seedCount
            WisprLog.log("Recorder: stop buffers=\(buffersSeen) rawFrames=\(rawFrames) " +
                         "resampled=\(samples.count) seed=\(seedCount) session=\(sessionCount)")
            let stopResult = StopResult(samples: samples, sessionSampleCount: sessionCount)
            if preRollEnabled {
                mode = .idle
                WisprLog.log("Recorder: mode -> idle")
            } else {
                needsTeardown = true
            }
            return stopResult
        }

        if needsTeardown {
            teardownEngine()
            sampleQueue.sync {
                mode = .stopped
                WisprLog.log("Recorder: mode -> stopped")
            }
        }
        return result
    }

    /// Duration of the captured audio in seconds.
    public static func duration(of samples: [Float]) -> Double {
        Double(samples.count) / AudioResampler.targetSampleRate
    }

    // MARK: - Idle-mode (pre-roll) engine lifecycle

    /// Must be called on the main thread, without holding `sampleQueue`
    /// (see the class-level concurrency note).
    private func startIdleEngine() {
        do {
            try installTapAndStartEngine()
            sampleQueue.sync {
                mode = .idle
                WisprLog.log("Recorder: mode -> idle (pre-roll engine started)")
            }
        } catch {
            // Fail-open: pre-roll is best-effort. Stay stopped; the normal
            // start() path (installing the tap on hotkey press) still works.
            sampleQueue.sync { mode = .stopped }
            WisprLog.log("Recorder: startIdleEngine FAILED, staying stopped: \(error)")
        }
    }

    // MARK: - Engine / tap plumbing

    /// Must be called on the main thread, without holding `sampleQueue`
    /// (see the class-level concurrency note). Leaves the engine running
    /// with a tap installed; does not itself set `mode`.
    private func installTapAndStartEngine() throws {
        let input = engine.inputNode
        // inputFormat is the device's real hardware format; outputFormat can
        // report a generic 44.1 kHz that mismatches (e.g. 16 kHz Bluetooth
        // headsets), which makes the tap silently deliver zero buffers.
        let format = input.inputFormat(forBus: 0)
        WisprLog.log("Recorder: input format sr=\(format.sampleRate) ch=\(format.channelCount)")
        guard format.sampleRate > 0 else { throw WisprError.recordingFailed }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let chunk = AudioResampler.resampleToWhisperFormat(buffer)
            var levelMode: Mode = .stopped
            self.sampleQueue.sync {
                switch self.mode {
                case .recording:
                    self.samples.append(contentsOf: chunk)
                case .idle:
                    self.ring.append(chunk)
                case .stopped:
                    break
                }
                self.buffersSeen += 1
                self.rawFrames += Int(buffer.frameLength)
                if self.buffersSeen == 1 {
                    WisprLog.log("Recorder: first buffer frames=\(buffer.frameLength) resampled=\(chunk.count)")
                }
                levelMode = self.mode
            }

            guard levelMode == .recording else { return }
            if let data = buffer.floatChannelData {
                let n = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += data[0][i] * data[0][i] }
                let rms = n > 0 ? sqrtf(sum / Float(n)) : 0
                DispatchQueue.main.async { self.onLevel?(min(rms * 5, 1)) }
            }
        }
        // A tap-only graph may never pull audio on macOS; route input into a
        // muted mixer so the engine has an active render chain.
        engine.connect(input, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw WisprError.recordingFailed
        }
        WisprLog.log("Recorder: engine started, isRunning=\(engine.isRunning)")
    }

    /// Must be called on the main thread, without holding `sampleQueue` —
    /// `removeTap` blocks until any in-flight tap callback returns, and that
    /// callback itself calls `sampleQueue.sync`, so holding the lock here
    /// would deadlock main against the audio thread (see the class-level
    /// concurrency note).
    private func teardownEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - Configuration change handling

    /// Handles `.AVAudioEngineConfigurationChange` (e.g. device switch,
    /// Bluetooth headset connect/disconnect). Serialized on main since
    /// notifications can arrive concurrently with app activity. Fail-open:
    /// any failure here degrades to `.stopped`, so the next `start()` falls
    /// back to the normal cold-start path rather than breaking dictation.
    private func handleConfigurationChange() {
        let previousMode = sampleQueue.sync { mode }
        WisprLog.log("Recorder: audio engine configuration changed (mode=\(previousMode))")
        guard previousMode != .stopped else { return }

        teardownEngine()
        sampleQueue.sync { ring.clear() }

        do {
            try installTapAndStartEngine()
            sampleQueue.sync {
                mode = previousMode
                WisprLog.log("Recorder: reconfigured, mode restored -> \(mode)")
            }
        } catch {
            sampleQueue.sync { mode = .stopped }
            WisprLog.log("Recorder: reconfiguration FAILED, mode -> stopped: \(error)")
        }
    }
}
