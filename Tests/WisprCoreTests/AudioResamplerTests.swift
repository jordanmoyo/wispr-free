import XCTest
import AVFoundation
@testable import WisprCore

final class AudioResamplerTests: XCTestCase {
    private func makeSineBuffer(sampleRate: Double, channels: AVAudioChannelCount,
                                seconds: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: channels, interleaved: false)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<Int(channels) {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                data[i] = sinf(2 * .pi * 440 * Float(i) / Float(sampleRate))
            }
        }
        return buffer
    }

    /// ScreenCaptureKit can deliver Int16 buffers, for which `floatChannelData` is
    /// nil. The manual downmix path used to force-unwrap it, so a non-Float32
    /// buffer crashed the process instead of being converted. This must produce
    /// real audio, not an empty array and not a trap.
    func testResamplesInt16StereoWithoutCrashing() {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                   channels: 2, interleaved: false)!
        let frames = AVAudioFrameCount(48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        XCTAssertNil(buffer.floatChannelData, "test premise: Int16 buffer has no float data")
        for ch in 0..<2 {
            let data = buffer.int16ChannelData![ch]
            for i in 0..<Int(frames) {
                data[i] = Int16(sinf(2 * .pi * 440 * Float(i) / 48_000) * 16_000)
            }
        }

        let samples = AudioResampler.resampleToWhisperFormat(buffer)

        XCTAssertGreaterThan(samples.count, 15_000)
        XCTAssertLessThan(samples.count, 17_000)
        let energy = samples.reduce(Float(0)) { $0 + $1 * $1 }
        XCTAssertGreaterThan(energy, 100, "Int16 input decoded to silence")
    }

    func testResamples48kStereoTo16kMono() {
        let buffer = makeSineBuffer(sampleRate: 48000, channels: 2, seconds: 1.0)
        let samples = AudioResampler.resampleToWhisperFormat(buffer)
        // 1 second of audio -> ~16000 samples (converter may trim edges slightly)
        XCTAssertGreaterThan(samples.count, 15000)
        XCTAssertLessThan(samples.count, 17000)
        // signal survives: sine wave has non-trivial energy
        let energy = samples.reduce(Float(0)) { $0 + $1 * $1 }
        XCTAssertGreaterThan(energy, 100)
    }

    func testStereoDownmixAveragesChannels() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                   channels: 2, interleaved: false)!
        let frames = AVAudioFrameCount(48000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let sample = sinf(2 * .pi * 440 * Float(i) / 48000)
            buffer.floatChannelData![0][i] = sample
            buffer.floatChannelData![1][i] = -sample  // opposite phase
        }
        let samples = AudioResampler.resampleToWhisperFormat(buffer)
        XCTAssertFalse(samples.isEmpty)
        let energy = samples.reduce(Float(0)) { $0 + $1 * $1 }
        // Correct average: (s + -s)/2 = 0 → near-zero energy.
        // Channel-drop bug: full sine energy ≈ 8000. Threshold sits far below that.
        XCTAssertLessThan(energy, 10, "stereo downmix should average channels (cancellation), not drop one")
    }

    func testPassthrough16kMonoKeepsLength() {
        let buffer = makeSineBuffer(sampleRate: 16000, channels: 1, seconds: 0.5)
        let samples = AudioResampler.resampleToWhisperFormat(buffer)
        XCTAssertGreaterThan(samples.count, 7500)
        XCTAssertLessThan(samples.count, 8500)
    }
}
