import AVFoundation

public enum AudioResampler {
    public static let targetSampleRate: Double = 16000

    /// Converts any PCM buffer to 16 kHz mono Float32 samples (Whisper input format).
    public static func resampleToWhisperFormat(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: targetSampleRate,
                                               channels: 1, interleaved: false) else {
            return []
        }

        // If already 16kHz mono, return directly
        if buffer.format == targetFormat, let data = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }

        // The manual downmix below reads `floatChannelData`, which is nil for any
        // buffer that is not Float32 — ScreenCaptureKit can hand back Int16, and
        // force-unwrapping there would crash. Let AVAudioConverter do the format,
        // channel and rate conversion in one pass instead.
        guard buffer.floatChannelData != nil else {
            return convert(buffer, to: targetFormat)
        }

        // If input is stereo and needs downmixing, create intermediate mono buffer first
        let monoInput: AVAudioPCMBuffer
        if buffer.format.channelCount > 1 {
            guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: buffer.format.sampleRate,
                                                 channels: 1, interleaved: false) else {
                return []
            }
            guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat,
                                                    frameCapacity: buffer.frameCapacity) else {
                return []
            }
            monoBuffer.frameLength = buffer.frameLength

            // Manually downmix by averaging channels
            let outputData = monoBuffer.floatChannelData![0]
            for ch in 0..<Int(buffer.format.channelCount) {
                let channelData = buffer.floatChannelData![ch]
                if ch == 0 {
                    for i in 0..<Int(buffer.frameLength) {
                        outputData[i] = channelData[i]
                    }
                } else {
                    for i in 0..<Int(buffer.frameLength) {
                        outputData[i] += channelData[i]
                    }
                }
            }
            // Average
            let channelCount = Float(buffer.format.channelCount)
            for i in 0..<Int(buffer.frameLength) {
                outputData[i] /= channelCount
            }
            monoInput = monoBuffer
        } else {
            monoInput = buffer
        }

        // Resample if needed
        if monoInput.format.sampleRate == targetSampleRate {
            guard let data = monoInput.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(monoInput.frameLength)))
        }

        return convert(monoInput, to: targetFormat)
    }

    /// Runs one buffer through `AVAudioConverter` into the target format. Handles
    /// sample-rate, channel-count and sample-format conversion together, so it is
    /// also the safe path for input the manual downmix above cannot touch.
    private static func convert(_ input: AVAudioPCMBuffer,
                                to targetFormat: AVAudioFormat) -> [Float] {
        guard let converter = AVAudioConverter(from: input.format, to: targetFormat) else {
            return []
        }
        let ratio = targetSampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return []
        }
        var consumed = false
        var convertError: NSError?
        let status = converter.convert(to: output, error: &convertError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        // Check for conversion errors
        if status == .error || convertError != nil {
            WisprLog.log("AudioResampler: convert failed status=\(status.rawValue) error=\(String(describing: convertError))")
            return []
        }
        guard let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}
