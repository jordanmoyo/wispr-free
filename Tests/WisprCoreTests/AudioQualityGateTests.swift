import XCTest
@testable import WisprCore

/// Thresholds here were calibrated against real recordings this app captured:
/// laptop-mic speech put 44–60% of its 20 ms frames above the speech floor,
/// while five seconds of a live but quiet room put 0% above it, its loudest
/// frame reaching 0.0016. The synthetic signals below sit at those measured
/// levels.
final class AudioQualityGateTests: XCTestCase {
    /// Constant-amplitude tone: a frame's RMS is `amplitude / sqrt(2)`, so
    /// the level each test asks for is unambiguous.
    private func tone(amplitude: Float, frames: Int) -> [Float] {
        let count = frames * AudioQualityGate.frameLength
        return (0..<count).map { amplitude * sin(Float($0) * 0.3) }
    }

    private func silence(frames: Int) -> [Float] {
        [Float](repeating: 0, count: frames * AudioQualityGate.frameLength)
    }

    func testZeroFilledBuffersAreDigitalSilence() {
        XCTAssertEqual(AudioQualityGate.classify(silence(frames: 100)), .digitalSilence)
    }

    /// A live mic in a quiet room: real buffers, nothing at speech level.
    /// This is the case that makes Whisper invent a sentence, so it must
    /// never reach the model.
    func testRoomToneFromALiveMicIsTooQuiet() {
        XCTAssertEqual(AudioQualityGate.classify(tone(amplitude: 0.0015, frames: 250)),
                       .tooQuiet)
    }

    /// Real speech attenuated by 30 dB still cleared the floor on 21% of its
    /// frames in the calibration recordings, so faint speech must transcribe
    /// rather than be refused.
    func testFaintButRealSpeechIsAccepted() {
        XCTAssertEqual(AudioQualityGate.classify(tone(amplitude: 0.02, frames: 100)),
                       .speech)
    }

    func testNormalSpeechIsAccepted() {
        XCTAssertEqual(AudioQualityGate.classify(tone(amplitude: 0.2, frames: 50)), .speech)
    }

    /// Between the two: enough to transcribe, not enough to believe a
    /// one-word result from. `DictationPlausibility` uses this distinction.
    func testABriefBurstOfSpeechIsMarginal() {
        let samples = tone(amplitude: 0.2, frames: 10) + silence(frames: 90)
        XCTAssertEqual(AudioQualityGate.classify(samples), .marginalSpeech)
    }

    func testVoicedFramesAreCountedAgainstTheSpeechFloor() {
        let samples = tone(amplitude: 0.2, frames: 12) + tone(amplitude: 0.0015, frames: 40)
        XCTAssertEqual(AudioQualityGate.voicedFrameCount(samples), 12)
    }

    /// A trailing partial frame carries less than 20 ms of audio; counting it
    /// would let a recording shorter than one frame report speech.
    func testATrailingPartialFrameIsNotCounted() {
        let samples = tone(amplitude: 0.2, frames: 3)
            + [Float](repeating: 0.2, count: AudioQualityGate.frameLength - 1)
        XCTAssertEqual(AudioQualityGate.voicedFrameCount(samples), 3)
    }

    /// Only the two refusals carry a message; the others let dictation run.
    func testOnlyTheRefusalsHaveSomethingToTellTheUser() {
        XCTAssertNil(AudioQuality.speech.userMessage)
        XCTAssertNil(AudioQuality.marginalSpeech.userMessage)
        XCTAssertNotNil(AudioQuality.tooQuiet.userMessage)
        XCTAssertNotNil(AudioQuality.digitalSilence.userMessage)
    }
}
