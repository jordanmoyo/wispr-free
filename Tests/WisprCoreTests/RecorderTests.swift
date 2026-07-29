import XCTest
@testable import WisprCore

final class RecorderTests: XCTestCase {
    func testPeakAmplitudeOfEmptyIsZero() {
        XCTAssertEqual(Recorder.peakAmplitude(of: []), 0)
    }

    func testPeakAmplitudeOfDigitalSilenceIsZero() {
        let silence = [Float](repeating: 0, count: 16_000)
        XCTAssertEqual(Recorder.peakAmplitude(of: silence), 0)
        XCTAssertLessThan(Recorder.peakAmplitude(of: silence), Recorder.silencePeakThreshold)
    }

    func testPeakAmplitudeUsesAbsoluteValue() {
        XCTAssertEqual(Recorder.peakAmplitude(of: [0.1, -0.7, 0.3]), 0.7)
    }

    func testQuietButRealSignalPassesThreshold() {
        // A real mic's noise floor peaks orders of magnitude above the
        // digital-silence threshold; a faint 0.001 signal must not be
        // refused as silence.
        let faint = [Float](repeating: 0.001, count: 1_000)
        XCTAssertGreaterThanOrEqual(Recorder.peakAmplitude(of: faint), Recorder.silencePeakThreshold)
    }
}
