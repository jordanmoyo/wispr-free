import XCTest
import AVFoundation
@testable import WisprCore

final class AudioFileImporterTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispr-audio-import-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Writes a sine-wave wav file to disk using AVAudioFile so tests need no committed fixtures.
    private func writeSineWav(sampleRate: Double, channels: AVAudioChannelCount,
                              seconds: Double, to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: channels, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<Int(channels) {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                data[i] = sinf(2 * .pi * 440 * Float(i) / Float(sampleRate))
            }
        }
        try file.write(from: buffer)
    }

    func testLoadsMono44kWavToPipelineFormat() throws {
        let url = tempDir.appendingPathComponent("mono44k.wav")
        try writeSineWav(sampleRate: 44100, channels: 1, seconds: 1.0, to: url)

        let samples = try AudioFileImporter.loadSamples(url: url)

        // 1s of audio at 16kHz target -> ~16000 samples (converter may trim edges slightly).
        XCTAssertGreaterThan(samples.count, 16000 - 800)
        XCTAssertLessThan(samples.count, 16000 + 800)
        let rms = sqrtf(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
        XCTAssertGreaterThan(rms, 0.05)
    }

    func testLoadsStereo48kWavDownmixed() throws {
        let url = tempDir.appendingPathComponent("stereo48k.wav")
        try writeSineWav(sampleRate: 48000, channels: 2, seconds: 1.0, to: url)

        let samples = try AudioFileImporter.loadSamples(url: url)

        XCTAssertGreaterThan(samples.count, 16000 - 800)
        XCTAssertLessThan(samples.count, 16000 + 800)
    }

    func testNonexistentPathThrows() {
        let url = tempDir.appendingPathComponent("does-not-exist.wav")
        XCTAssertThrowsError(try AudioFileImporter.loadSamples(url: url))
    }

    func testTextFileRenamedWavThrows() throws {
        let url = tempDir.appendingPathComponent("not-really-audio.wav")
        try "this is plain text, not an audio file".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try AudioFileImporter.loadSamples(url: url))
    }

    /// Writes a 16 kHz mono AAC `.m4a` holding exactly `sampleCount` frames, so a
    /// test can put the decoder on an exact read-chunk boundary.
    private func writeSineM4A(sampleCount: Int, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(sampleCount))!
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        let data = buffer.floatChannelData![0]
        for i in 0..<sampleCount {
            data[i] = sinf(2 * .pi * 440 * Float(i) / 16_000)
        }
        try file.write(from: buffer)
    }

    /// Regression: a file whose decoded length is an exact multiple of the 8192-frame
    /// read chunk used to throw. Every read filled the buffer completely, so the
    /// short-read "this was the last chunk" heuristic never fired, the loop issued one
    /// more `read()` past true end-of-file, and AVFoundation threw instead of returning
    /// zero frames. Verified against 8192, 16384, 24576, 196608, 204800 and 212992;
    /// totals ten samples either side of those decoded fine.
    func testDecodesLengthThatIsExactMultipleOfReadChunk() throws {
        for sampleCount in [8_192, 16_384, 204_800] {
            let url = tempDir.appendingPathComponent("boundary-\(sampleCount).m4a")
            try writeSineM4A(sampleCount: sampleCount, to: url)

            let samples = try AudioFileImporter.loadSamples(url: url)

            XCTAssertGreaterThan(samples.count, sampleCount - 4_000,
                                 "lost audio decoding \(sampleCount) frames")
            XCTAssertLessThan(samples.count, sampleCount + 4_000,
                              "decoded past the end of \(sampleCount) frames")
        }
    }

    func testMaxSamplesConstant() {
        XCTAssertEqual(AudioFileImporter.maxSamples, 28_800_000)
    }
}
