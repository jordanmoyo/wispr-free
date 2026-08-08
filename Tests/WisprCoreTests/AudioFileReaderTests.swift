import AVFoundation
import XCTest
@testable import WisprCore

/// Holds a task at a known point so the test can cancel it BEFORE the work
/// starts. Without this, "cancel then await" races a decode that finishes in
/// microseconds and the test passes or fails by timing.
private actor Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}

final class AudioFileReaderTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wispr-reader-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Writes a mono WAV of `seconds` at `sampleRate` whose sample at index
    /// `i` is `Float(i) / Float(total)` — a ramp, so a decoded window's
    /// VALUES identify which part of the file it came from. A constant tone
    /// would let a seek bug pass unnoticed.
    private func writeRamp(seconds: Double, sampleRate: Double) throws -> URL {
        let url = directory.appendingPathComponent("ramp-\(Int(sampleRate)).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate, channels: 1,
                                   interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        for i in 0..<total {
            buffer.floatChannelData![0][i] = Float(i) / Float(total)
        }
        try file.write(from: buffer)
        return url
    }

    func testReportsDurationAndSampleCountAtTargetRate() async throws {
        let url = try writeRamp(seconds: 3, sampleRate: 44_100)
        let reader = try AudioFileReader(url: url)
        XCTAssertEqual(reader.durationSeconds, 3, accuracy: 0.05)
        XCTAssertEqual(Double(reader.sampleCount), 48_000, accuracy: 200)
    }

    func testReadsRequestedRangeLength() async throws {
        let url = try writeRamp(seconds: 3, sampleRate: 16_000)
        let reader = try AudioFileReader(url: url)
        let samples = try await reader.samples(in: 0..<16_000)
        XCTAssertEqual(samples.count, 16_000)
    }

    /// The seek test. A window from the middle of a ramp must hold
    /// mid-ramp VALUES — this is what fails if `framePosition` is ignored
    /// and every call decodes from the start of the file.
    ///
    /// The tolerance is tight on purpose. At `accuracy: 0.02` this test also
    /// passed with `dropFirst(preRoll)` removed — the 1,024-sample pre-roll is
    /// `1024/64000 = 0.016` of a four-second ramp, inside the old window — so
    /// it named a defect it could not detect. 0.005 is narrower than the
    /// pre-roll it is meant to catch.
    func testSeeksToTheRequestedOffset() async throws {
        let url = try writeRamp(seconds: 4, sampleRate: 16_000)
        let reader = try AudioFileReader(url: url)
        let middle = try await reader.samples(in: 32_000..<32_100)
        XCTAssertFalse(middle.isEmpty)
        // Halfway through a 0→1 ramp.
        XCTAssertEqual(middle[0], 0.5, accuracy: 0.005)
    }

    func testDisjointWindowsDoNotRepeatTheSameAudio() async throws {
        let url = try writeRamp(seconds: 4, sampleRate: 16_000)
        let reader = try AudioFileReader(url: url)
        let first = try await reader.samples(in: 0..<100)
        let second = try await reader.samples(in: 32_000..<32_100)
        // Guarded rather than indexed blind: a regression that returns []
        // would otherwise crash the whole test process instead of failing
        // this one assertion.
        XCTAssertFalse(first.isEmpty)
        XCTAssertFalse(second.isEmpty)
        XCTAssertNotEqual(first[0], second[0], accuracy: 0.1)
    }

    /// Spec §6.1's strongest claim, which had no test: reassembling
    /// non-aligned chunks reproduces the original with no seam error. This is
    /// what the pre-roll exists for — a fresh converter per seek starts with
    /// zero-filled filter history, and without the pre-roll the first few
    /// output samples of every chunk after the first are corrupted.
    func testChunksReassembleIntoTheOriginalAcrossASeam() async throws {
        let url = try writeRamp(seconds: 4, sampleRate: 16_000)
        let reader = try AudioFileReader(url: url)
        // A deliberately non-aligned split point, so the seam lands
        // mid-buffer rather than on a convenient boundary.
        let whole = try await reader.samples(in: 0..<20_000)
        let head = try await reader.samples(in: 0..<9_137)
        let tail = try await reader.samples(in: 9_137..<20_000)

        XCTAssertEqual(head.count + tail.count, whole.count)
        let rejoined = head + tail
        // Reduced to the single worst sample rather than asserted per
        // sample: a failing run should name where and by how much, not emit
        // ten thousand identical failures.
        var worst = (index: 0, error: Float(0))
        for index in 0..<min(rejoined.count, whole.count) {
            let error = abs(rejoined[index] - whole[index])
            if error > worst.error { worst = (index, error) }
        }
        XCTAssertLessThan(worst.error, 0.0005,
                          "worst seam error \(worst.error) at sample \(worst.index)")
    }

    /// Spec §6.1 claims 16 / 44.1 / 48 kHz were all verified; 48 kHz had no
    /// test. It is the rate most screen recordings and interview kit produce.
    func testResamplesA48kHzSourcePreservingPosition() async throws {
        let url = try writeRamp(seconds: 4, sampleRate: 48_000)
        let reader = try AudioFileReader(url: url)
        let middle = try await reader.samples(in: 32_000..<32_100)
        XCTAssertEqual(middle.count, 100)
        XCTAssertEqual(middle[0], 0.5, accuracy: 0.005)
    }

    /// Writes a SPARSE silent 16 kHz mono WAV of `seconds`: a real 44-byte
    /// RIFF header followed by a data region created with `truncate`.
    ///
    /// Two hours at 16 kHz is 230 MB of samples, which is exactly why
    /// `AudioFileReader` streams instead of loading whole files — and far too
    /// much to write in a unit test. Silence is all zero bytes, and APFS
    /// stores a truncated hole without allocating blocks, so this produces a
    /// genuinely valid two-hour WAV that `AVAudioFile` opens and reports the
    /// full length for, in a fraction of a second and no disk.
    private func writeSparseSilence(seconds: Int) throws -> URL {
        let rate = 16_000                     // mono 16-bit: 2 bytes per frame
        let dataBytes = seconds * rate * 2

        var header = Data()
        func ascii(_ text: String) { header.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: Int) {
            withUnsafeBytes(of: UInt32(value).littleEndian) { header.append(contentsOf: $0) }
        }
        func u16(_ value: Int) {
            withUnsafeBytes(of: UInt16(value).littleEndian) { header.append(contentsOf: $0) }
        }
        ascii("RIFF"); u32(36 + dataBytes); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1); u32(rate)
        u32(rate * 2); u16(2); u16(16)
        ascii("data"); u32(dataBytes)

        let url = directory.appendingPathComponent("sparse-\(seconds).wav")
        try header.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(header.count + dataBytes))
        try handle.close()
        return url
    }

    /// The two-hour ceiling had no test at all, in a feature whose headline
    /// promise is "files up to two hours". `AppController.start` turns this
    /// throw into the `.fileTooLong` banner; without the throw a three-hour
    /// upload would silently begin a run that allocates past what the machine
    /// has.
    func testAFileOverTwoHoursIsRefused() throws {
        let url = try writeSparseSilence(seconds: 7_260)   // 2 h 1 min
        XCTAssertThrowsError(try AudioFileReader(url: url)) { error in
            guard case WisprError.audioFileTooLong = error else {
                return XCTFail("expected audioFileTooLong, got \(error)")
            }
        }
    }

    /// The other side of the same line: two hours is the documented limit, so
    /// a file AT it must be accepted. A guard written `<` rather than `<=`
    /// would reject exactly the file the feature advertises.
    func testAFileAtExactlyTwoHoursIsAccepted() throws {
        let url = try writeSparseSilence(seconds: 7_200)
        let reader = try AudioFileReader(url: url)
        XCTAssertEqual(reader.sampleCount, AudioFileReader.maxSamples)
        XCTAssertEqual(reader.durationSeconds, 7_200, accuracy: 0.5)
    }

    /// Cancelling a two-hour transcription must not wait out the chunk that
    /// is already decoding. The reader is the one place in a run that holds
    /// the CPU for a long stretch without an `await` of its own, so without
    /// an explicit check the Cancel button does nothing until the decode ends.
    func testReadingIsCancellable() async throws {
        let url = try writeRamp(seconds: 4, sampleRate: 16_000)
        let reader = try AudioFileReader(url: url)
        let gate = Gate()
        let task = Task { () -> [Float] in
            await gate.wait()
            return try await reader.samples(in: 0..<64_000)
        }
        task.cancel()
        await gate.open()

        do {
            let samples = try await task.value
            XCTFail("a cancelled read returned \(samples.count) samples")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    /// The other half: an uncancelled read must still return audio, or the
    /// test above would pass against a reader that refuses everything.
    func testAnUncancelledReadStillReturnsAudio() async throws {
        let url = try writeRamp(seconds: 4, sampleRate: 16_000)
        let reader = try AudioFileReader(url: url)
        let task = Task { try await reader.samples(in: 0..<64_000) }
        let samples = try await task.value
        XCTAssertEqual(samples.count, 64_000)
    }

    func testWindowsAreRepeatableRegardlessOfOrder() async throws {
        let url = try writeRamp(seconds: 4, sampleRate: 16_000)
        let reader = try AudioFileReader(url: url)
        let firstPass = try await reader.samples(in: 16_000..<16_100)
        _ = try await reader.samples(in: 0..<100)
        let secondPass = try await reader.samples(in: 16_000..<16_100)
        XCTAssertEqual(firstPass, secondPass)
    }

    /// A 44.1 kHz source must come back at the 16 kHz target rate, with the
    /// ramp values preserved — resampling must not shift the timeline.
    func testResamplesToTargetRatePreservingPosition() async throws {
        let url = try writeRamp(seconds: 4, sampleRate: 44_100)
        let reader = try AudioFileReader(url: url)
        let middle = try await reader.samples(in: 32_000..<32_100)
        XCTAssertEqual(middle.count, 100)
        XCTAssertEqual(middle[0], 0.5, accuracy: 0.03)
    }

    func testRangePastEndOfFileReturnsEmpty() async throws {
        let url = try writeRamp(seconds: 1, sampleRate: 16_000)
        let reader = try AudioFileReader(url: url)
        let samples = try await reader.samples(in: 100_000..<101_000)
        XCTAssertTrue(samples.isEmpty)
    }

    func testFinalWindowIsShortRatherThanPadded() async throws {
        let url = try writeRamp(seconds: 1, sampleRate: 16_000)
        let reader = try AudioFileReader(url: url)
        let samples = try await reader.samples(in: 15_000..<20_000)
        XCTAssertGreaterThan(samples.count, 0)
        XCTAssertLessThan(samples.count, 5_000)
    }

    func testEmptyRangeReturnsEmpty() async throws {
        let url = try writeRamp(seconds: 1, sampleRate: 16_000)
        let reader = try AudioFileReader(url: url)
        let samples = try await reader.samples(in: 500..<500)
        XCTAssertTrue(samples.isEmpty)
    }

    func testUnreadableFileThrows() {
        let url = directory.appendingPathComponent("nope.wav")
        XCTAssertThrowsError(try AudioFileReader(url: url)) { error in
            guard case WisprError.audioFileUnreadable = error else {
                return XCTFail("expected audioFileUnreadable, got \(error)")
            }
        }
    }
}
