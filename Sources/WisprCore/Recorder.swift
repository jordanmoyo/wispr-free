import AudioToolbox
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

    private var engine = AVAudioEngine()
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

    /// CoreAudio UID of the input device to capture from, or nil for the
    /// system default. Setting it while an engine is running (idle pre-roll
    /// or an active recording) restarts the engine on the new device via the
    /// same fail-open path as a configuration change; captured samples
    /// survive the restart. Must be set on the main thread (see the
    /// class-level concurrency note).
    public var preferredInputDeviceUID: String? {
        didSet {
            guard preferredInputDeviceUID != oldValue else { return }
            let running = sampleQueue.sync { mode != .stopped }
            guard running else { return }
            handleConfigurationChange()
        }
    }

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
        registerConfigObserver()
    }

    private func registerConfigObserver() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.handleConfigurationChange() }
        }
    }

    /// Replaces the engine with a fresh one, re-registering the
    /// configuration observer on it. Once an engine's input unit gets into
    /// an invalid-format state (an input device flapping mid-session), no
    /// re-binding recovers it — `start()` keeps failing with -10875 even on
    /// a healthy device. Only a new engine rebuilds the AUHAL from scratch.
    /// Must be called on the main thread with no tap-dependent mode active.
    private func rebuildEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        registerConfigObserver()
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

    /// Largest absolute sample value — 0 for digital silence.
    public static func peakAmplitude(of samples: [Float]) -> Float {
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        return peak
    }

    /// Recordings whose peak falls below this are digital silence (a device
    /// delivering zero-filled buffers — e.g. a wireless mic whose
    /// transmitter is off), not a quiet room: a real mic's noise floor
    /// peaks orders of magnitude higher. Transcribing such audio makes
    /// Whisper hallucinate filler words ("you"), so it is refused upstream.
    public static let silencePeakThreshold: Float = 1e-5

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
        Recorder.applyPreferredDevice(uid: preferredInputDeviceUID, to: engine.inputNode)
        do {
            try tapConnectAndStart(input: engine.inputNode)
            return
        } catch {
            WisprLog.log("Recorder: engine start failed, rebuilding engine")
        }
        // A device that fails mid-binding (no live stream, format the render
        // chain rejects — e.g. a wireless receiver whose transmitter is
        // asleep) wedges the whole engine; see rebuildEngine(). Try the
        // selected device once more on a fresh engine, then give it up and
        // take the system default so dictation keeps working.
        rebuildEngine()
        if preferredInputDeviceUID != nil {
            Recorder.applyPreferredDevice(uid: preferredInputDeviceUID, to: engine.inputNode)
            do {
                try tapConnectAndStart(input: engine.inputNode)
                return
            } catch {
                WisprLog.log("Recorder: selected device failed on fresh engine, falling back to system default")
                rebuildEngine()
            }
        }
        // A fresh engine's input node is bound to the system default.
        try tapConnectAndStart(input: engine.inputNode)
    }

    private func tapConnectAndStart(input: AVAudioInputNode) throws {
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
            WisprLog.log("Recorder: engine start failed: \(error)")
            input.removeTap(onBus: 0)
            throw WisprError.recordingFailed
        }
        WisprLog.log("Recorder: engine started, isRunning=\(engine.isRunning)")
    }

    /// Points the input node's underlying AUHAL at the device with `uid`.
    /// Fail-open: a missing device (unplugged) or any CoreAudio error leaves
    /// the system default input in place. Static so `MicLevelMonitor` can
    /// share the exact same routing for its preview engine.
    static func applyPreferredDevice(uid: String?, to input: AVAudioInputNode) {
        guard let uid else { return }
        guard var deviceID = AudioInputDevices.deviceID(forUID: uid) else {
            WisprLog.log("Recorder: preferred input device \(uid) not found, using system default")
            return
        }
        guard let audioUnit = input.audioUnit else {
            WisprLog.log("Recorder: input node has no audio unit, using system default")
            return
        }
        let status = AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            // A failed set can leave the AUHAL bound to nothing (input format
            // reads 0 Hz afterward) — rebind the default explicitly rather
            // than assume the previous binding survived.
            WisprLog.log("Recorder: setting input device failed (\(status)), rebinding system default")
            applySystemDefaultDevice(to: input)
        }
    }

    /// Rebinds `input`'s AUHAL to the current system default input device.
    /// Recovery path for when a preferred-device binding fails or yields a
    /// dead stream — a device can enumerate with input channels yet expose
    /// no valid format (wireless receivers whose transmitter is off).
    static func applySystemDefaultDevice(to input: AVAudioInputNode) {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown,
              let audioUnit = input.audioUnit else {
            WisprLog.log("Recorder: could not resolve system default input (\(status))")
            return
        }
        let setStatus = AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        if setStatus != noErr {
            WisprLog.log("Recorder: rebinding system default failed (\(setStatus))")
        }
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
