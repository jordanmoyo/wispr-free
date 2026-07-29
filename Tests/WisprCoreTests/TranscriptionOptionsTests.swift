import XCTest
import WhisperKit
@testable import WisprCore

final class TranscriptionOptionsTests: XCTestCase {
    func testNilPinAutoDetects() {
        let options = TranscriptionOptions.build(pinned: nil)
        XCTAssertNil(options.language)
        XCTAssertTrue(options.detectLanguage)
    }

    func testValidPinDisablesDetection() {
        let options = TranscriptionOptions.build(pinned: "fr")
        XCTAssertEqual(options.language, "fr")
        XCTAssertFalse(options.detectLanguage)
    }

    func testUnknownCodeFallsBackToAuto() {
        let options = TranscriptionOptions.build(pinned: "zz")
        XCTAssertNil(options.language)
        XCTAssertTrue(options.detectLanguage)
    }

    func testLanguagesHasThirteenEntries() {
        XCTAssertEqual(TranscriptionOptions.languages.count, 13)
    }

    func testEveryLanguageCodeRoundTripsThroughBuild() {
        for (code, _) in TranscriptionOptions.languages {
            let options = TranscriptionOptions.build(pinned: code)
            XCTAssertEqual(options.language, code, "code \(code) should pin")
            XCTAssertFalse(options.detectLanguage, "code \(code) should disable auto-detect")
        }
    }
}
