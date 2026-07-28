import AVFoundation

public final class Recorder {
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let sampleQueue = DispatchQueue(label: "wispr.recorder.samples")
    private var buffersSeen = 0
    private var rawFrames = 0

    /// Called on the main queue with the RMS level (0...1) of each captured buffer.
    public var onLevel: ((Float) -> Void)?

    public init() {}

    public func start() throws {
        sampleQueue.sync { samples.removeAll(); buffersSeen = 0; rawFrames = 0 }
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
            self.sampleQueue.sync {
                self.samples.append(contentsOf: chunk)
                self.buffersSeen += 1
                self.rawFrames += Int(buffer.frameLength)
                if self.buffersSeen == 1 {
                    WisprLog.log("Recorder: first buffer frames=\(buffer.frameLength) resampled=\(chunk.count)")
                }
            }

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

    /// Stops capture and returns all samples recorded since start() (16 kHz mono).
    public func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return sampleQueue.sync {
            WisprLog.log("Recorder: stop buffers=\(buffersSeen) rawFrames=\(rawFrames) resampled=\(samples.count)")
            return samples
        }
    }

    /// Duration of the captured audio in seconds.
    public static func duration(of samples: [Float]) -> Double {
        Double(samples.count) / AudioResampler.targetSampleRate
    }
}
