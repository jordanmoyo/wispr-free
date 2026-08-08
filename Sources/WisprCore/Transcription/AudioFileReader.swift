import AVFoundation

/// Decodes arbitrary ranges of an on-disk audio file to 16 kHz mono Float32,
/// on demand.
///
/// Why this exists: `AudioFileImporter` decodes a whole file into one
/// `[Float]`. Two hours at 16 kHz Float32 is 460 MB resident before Whisper
/// allocates anything, so whole-file loading does not reach the two-hour
/// requirement. Reading a chunk at a time holds peak memory at roughly one
/// chunk — about 40 MB — whether the file is three minutes or three hours.
///
/// An actor because `AVAudioFile` is neither `Sendable` nor safe to seek
/// from two tasks at once: `samples(in:)` mutates `framePosition`, so two
/// concurrent callers would read each other's window.
public actor AudioFileReader {
    /// 2 hours at the 16 kHz target rate.
    public static let maxSamples = 16_000 * 7_200
    static let targetRate: Double = 16_000

    /// Output samples decoded before the requested range and then discarded,
    /// to warm the resampler.
    ///
    /// A converter built fresh for one call starts with zero filter history,
    /// so its first output samples are blends of real signal and the silence
    /// the filter assumes preceded it. Measured on a 44.1 kHz → 16 kHz ramp,
    /// output sample 0 comes back at ~66% of its true value and the error is
    /// only below 1e-4 from sample 5 on. Returning that transient would put a
    /// click at the head of every chunk. Decoding a pre-roll and dropping it
    /// means the first sample a caller sees was produced with real history
    /// behind it. 1024 samples is 64 ms — far more than the measured
    /// transient, and cheap next to a chunk.
    static let preRollSamples = 1_024

    /// Length in 16 kHz output samples.
    ///
    /// COMPUTED from the source length and rate, not measured by decoding,
    /// so it can differ from the true converted length by a frame or two.
    /// `samples(in:)` therefore returns UP TO `range.count` samples and every
    /// caller must tolerate a short final chunk.
    public nonisolated let sampleCount: Int
    public nonisolated let durationSeconds: Double

    private let file: AVAudioFile
    private let sourceRate: Double
    private let targetFormat: AVAudioFormat

    public init(url: URL) throws {
        let opened: AVAudioFile
        do {
            opened = try AVAudioFile(forReading: url)
        } catch {
            throw WisprError.audioFileUnreadable(error.localizedDescription)
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.targetRate, channels: 1,
                                         interleaved: false) else {
            throw WisprError.audioFileUnreadable("unable to construct target audio format")
        }
        let rate = opened.processingFormat.sampleRate
        guard rate > 0 else {
            throw WisprError.audioFileUnreadable("source reports a zero sample rate")
        }

        self.file = opened
        self.sourceRate = rate
        self.targetFormat = format
        self.durationSeconds = Double(opened.length) / rate
        self.sampleCount = Int(Double(opened.length) * Self.targetRate / rate)

        guard self.sampleCount <= Self.maxSamples else {
            throw WisprError.audioFileTooLong
        }
    }

    /// Decodes `range` (in 16 kHz output samples) and returns up to
    /// `range.count` samples — fewer at the end of the file, none if the
    /// range starts past it.
    ///
    /// A FRESH `AVAudioConverter` is built per call, because a converter
    /// carries resampler state that a seek invalidates. That cold resampler
    /// is why the decode starts `preRollSamples` early and throws the
    /// pre-roll away — see `preRollSamples`.
    public func samples(in range: Range<Int>) throws -> [Float] {
        guard !range.isEmpty else { return [] }

        let ratio = sourceRate / Self.targetRate
        let sourceStart = Int64((Double(range.lowerBound) * ratio).rounded())
        guard sourceStart < file.length else { return [] }

        // Back up by the pre-roll, clamped at the start of the file: the
        // first window of a file has no earlier audio to warm the filter with.
        let preRoll = min(Self.preRollSamples, range.lowerBound)
        let readStart = sourceStart - Int64((Double(preRoll) * ratio).rounded())
        // Decode the pre-roll AND the requested range; the pre-roll is
        // dropped from the front of the result.
        let wanted = preRoll + range.count
        file.framePosition = readStart

        guard let converter = AVAudioConverter(from: file.processingFormat,
                                               to: targetFormat) else {
            throw WisprError.audioFileUnreadable(
                "unable to construct audio converter for source format")
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

        // Bound the source frames this call may consume so a request for one
        // chunk cannot walk the rest of the file. The extra `chunkFrames` is
        // slack for resampler priming.
        //
        // `nonisolated(unsafe)` on the block's mutable state: the block is
        // invoked synchronously by `converter.convert` on this thread before
        // it returns, never concurrently, so the compiler's cross-actor
        // reasoning about these captures does not apply.
        nonisolated(unsafe) var sourceBudget = Int64((Double(wanted) * ratio).rounded())
            + Int64(chunkFrames)
        // Bound to a local so the converter's input block never captures
        // `self` — capturing an actor's `self` in a synchronously-invoked
        // callback is exactly the pattern Swift 6 rejects.
        let localFile = file
        nonisolated(unsafe) var finished = false
        nonisolated(unsafe) var readError: Error?
        var samples: [Float] = []
        samples.reserveCapacity(wanted)

        while samples.count < wanted {
            // The whole-file read for diarization decodes up to an hour of
            // audio in this one loop and occupies a cooperative-pool thread
            // for its entire duration. Without this, a cancel cannot reach
            // it at all — the ten-minute cancel latency documented for
            // transcription is a per-chunk figure and does not cover this.
            try Task.checkCancellation()

            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if finished {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                // Bound every read by the frames actually left in the file AND
                // by this call's budget. AVFoundation throws rather than
                // returning 0 frames when read past true EOF, and a short read
                // is not a reliable end marker (see `AudioFileImporter`).
                let remaining = min(localFile.length - localFile.framePosition,
                                    sourceBudget)
                guard remaining > 0 else {
                    finished = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    inputBuffer.frameLength = 0
                    try localFile.read(
                        into: inputBuffer,
                        frameCount: AVAudioFrameCount(min(Int64(chunkFrames), remaining)))
                } catch {
                    readError = error
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    finished = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                sourceBudget -= Int64(inputBuffer.frameLength)
                outStatus.pointee = .haveData
                return inputBuffer
            }

            outputBuffer.frameLength = 0
            var convertError: NSError?
            let status = converter.convert(to: outputBuffer, error: &convertError,
                                           withInputFrom: inputBlock)

            if let readError {
                throw WisprError.audioFileUnreadable(readError.localizedDescription)
            }
            if status == .error {
                throw WisprError.audioFileUnreadable(
                    convertError?.localizedDescription ?? "unknown conversion error")
            }

            if let data = outputBuffer.floatChannelData, outputBuffer.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: data[0], count: Int(outputBuffer.frameLength)))
            }

            if status == .endOfStream || outputBuffer.frameLength == 0 { break }
        }

        // Trimmed IN PLACE rather than `Array(samples.dropFirst(…).prefix(…))`.
        // That form allocates a second buffer while `samples` is still alive,
        // doubling peak memory — tolerable for a 38 MB chunk, but the
        // diarization path reads the whole file, so an hour of audio would
        // peak near 460 MB instead of the 230 MB `DiarizationGate` budgets for.
        if samples.count > preRoll + range.count {
            samples.removeLast(samples.count - preRoll - range.count)
        }
        // Clamped: a decode that ended early can return fewer samples than the
        // pre-roll itself, and `removeFirst(_:)` traps rather than clamping.
        if preRoll > 0 { samples.removeFirst(min(preRoll, samples.count)) }
        return samples
    }
}
