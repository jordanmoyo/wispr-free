import AVFoundation

/// Decodes an on-disk audio file into the 16 kHz mono Float32 sample format
/// consumed by `Transcriber`. Pure decoding — no UI, no AppController wiring.
public enum AudioFileImporter {
    /// 30 minutes at the 16 kHz target rate — a safety cap against runaway inputs.
    public static let maxSamples = 16_000 * 1_800

    /// Reads `url` and returns 16 kHz mono Float32 samples ready for `Transcriber`.
    /// Throws `WisprError.audioFileUnreadable` if the file can't be opened, isn't
    /// a recognizable audio format, or decodes past `maxSamples`.
    public static func loadSamples(url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw WisprError.audioFileUnreadable(error.localizedDescription)
        }

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16000, channels: 1,
                                               interleaved: false) else {
            throw WisprError.audioFileUnreadable("unable to construct target audio format")
        }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw WisprError.audioFileUnreadable("unable to construct audio converter for source format")
        }

        let chunkFrames: AVAudioFrameCount = 8192
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: chunkFrames) else {
            throw WisprError.audioFileUnreadable("unable to allocate input buffer")
        }
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                  frameCapacity: chunkFrames * 4) else {
            throw WisprError.audioFileUnreadable("unable to allocate output buffer")
        }

        var samples: [Float] = []
        var reachedEndOfFile = false
        var readError: Error?

        while true {
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if reachedEndOfFile {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    inputBuffer.frameLength = 0
                    try file.read(into: inputBuffer, frameCount: chunkFrames)
                } catch {
                    readError = error
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    reachedEndOfFile = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength < chunkFrames {
                    // Short read: this is the file's last chunk. Some AVFoundation
                    // versions throw instead of returning 0 frames on the next
                    // read once truly at EOF, so avoid calling read() again.
                    reachedEndOfFile = true
                }
                outStatus.pointee = .haveData
                return inputBuffer
            }

            outputBuffer.frameLength = 0
            var convertError: NSError?
            let status = converter.convert(to: outputBuffer, error: &convertError, withInputFrom: inputBlock)

            if let readError {
                throw WisprError.audioFileUnreadable(readError.localizedDescription)
            }
            if status == .error {
                let message = convertError?.localizedDescription ?? "unknown conversion error"
                throw WisprError.audioFileUnreadable(message)
            }

            if let data = outputBuffer.floatChannelData, outputBuffer.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(outputBuffer.frameLength)))
            }

            if samples.count > maxSamples {
                throw WisprError.audioFileTooLong
            }

            if status == .endOfStream {
                break
            }
        }

        return samples
    }
}
