import XCTest
@testable import WisprCore

final class DictationGateTests: XCTestCase {
    func testShortRecordingDiscarded() {
        // 0.2 s at 16 kHz = 3200 samples
        let short = [Float](repeating: 0.1, count: 3200)
        XCTAssertFalse(DictationGate.shouldTranscribe(samples: short))
    }

    func testLongEnoughRecordingAccepted() {
        // 0.5 s at 16 kHz = 8000 samples
        let ok = [Float](repeating: 0.1, count: 8000)
        XCTAssertTrue(DictationGate.shouldTranscribe(samples: ok))
    }
}
