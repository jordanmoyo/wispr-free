import AVFoundation
import SwiftUI

/// Live input-level preview for the Microphone settings pane. Runs its own
/// tiny `AVAudioEngine` (separate from `Recorder`'s — CoreAudio allows
/// concurrent capture clients), started when the pane appears and stopped
/// when it disappears. Fail-open: if the engine can't start (no mic
/// permission, device busy), `available` stays false and the pane shows a
/// static meter.
@MainActor
public final class MicLevelMonitor: ObservableObject {
    /// Smoothed RMS level in 0...1.
    @Published public private(set) var level: Float = 0
    @Published public private(set) var available = false

    private let engine = AVAudioEngine()
    private var running = false

    public init() {}

    public func start(deviceUID: String?) {
        stop()
        let input = engine.inputNode
        Recorder.applyPreferredDevice(uid: deviceUID, to: input)
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += data[0][i] * data[0][i] }
            let rms = n > 0 ? sqrtf(sum / Float(n)) : 0
            let scaled = min(rms * 5, 1)
            Task { @MainActor [weak self] in
                guard let self, self.running else { return }
                // Fast attack, slow decay, so speech peaks read clearly.
                self.level = max(scaled, self.level * 0.85)
            }
        }
        engine.connect(input, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        engine.prepare()
        do {
            try engine.start()
            running = true
            available = true
        } catch {
            input.removeTap(onBus: 0)
            WisprLog.log("MicLevelMonitor: engine start failed: \(error)")
        }
    }

    public func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        available = false
        level = 0
    }
}
