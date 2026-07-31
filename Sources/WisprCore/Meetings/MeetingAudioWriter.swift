import AVFoundation
import Foundation

/// Streams 16 kHz mono Float32 samples to a 16 kHz mono AAC `.m4a` file,
/// appending incrementally so memory stays flat for an hour-long meeting and
/// a crash preserves whatever was already written.
///
/// `append` is safe to call from an audio render callback: it takes a lock and
/// swallows every error (fail-open — losing audio is bad, crashing mid-meeting
/// is worse). `finish` must be awaited before the file is read.
public final class MeetingAudioWriter: @unchecked Sendable {
    public static let sampleRate: Double = 16_000

    private let lock = NSLock()
    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private var written = 0
    private var finished = false

    public var sampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return written
    }

    public init(url: URL) throws {
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false) else {
            throw WisprError.audioFileUnreadable("unable to build writer format")
        }
        self.format = pcmFormat

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        // Throws for an unwritable path, which is what the caller wants to know.
        self.file = try AVAudioFile(forWriting: url, settings: settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let file else { return }
        guard samples.count <= Int(UInt32.max) else {
            WisprLog.log("meeting writer: batch too large to encode, \(samples.count) samples")
            return
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else {
            WisprLog.log("meeting writer: buffer alloc FAILED for \(samples.count) samples")
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData {
            channel[0].update(from: samples, count: samples.count)
        }
        do {
            try file.write(from: buffer)
            written += samples.count
        } catch {
            WisprLog.log("meeting writer: write FAILED: \(error)")
        }
    }

    /// Closes the file. Idempotent; safe to call twice.
    public func finish() async {
        finishSync()
    }

    /// Synchronous body of `finish()`, kept separate so the lock is taken and
    /// released entirely inside an ordinary (non-`async`) function. Locking
    /// directly inside `async func finish()` would hold a blocking `NSLock`
    /// across a suspension point in the Swift 6 language mode, which is a
    /// hard error there and, even today, risks blocking a cooperative-pool
    /// thread against a concurrent `append()` that is mid-`file.write`.
    private func finishSync() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        let fileURL = file?.url
        file = nil   // AVAudioFile finalises the container on deinit
        // A zero-sample AAC container is written with valid headers but no
        // frames, and AVAudioFile/AudioConverter fail to decode it back on
        // this toolchain. Prefer "no file" over "a file that throws on read"
        // for the no-audio-ever-appended case.
        if written == 0, let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
