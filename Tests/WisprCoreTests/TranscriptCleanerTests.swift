import XCTest
@testable import WisprCore

final class TranscriptCleanerTests: XCTestCase {
    func testTrimsAndCollapsesWhitespace() {
        XCTAssertEqual(TranscriptCleaner.clean("  hello   world \n"), "hello world")
    }

    func testStripsBracketArtifacts() {
        XCTAssertEqual(TranscriptCleaner.clean("[BLANK_AUDIO]"), "")
        XCTAssertEqual(TranscriptCleaner.clean("hello [MUSIC] world"), "hello world")
        XCTAssertEqual(TranscriptCleaner.clean("(door slams) hi"), "hi")
    }

    func testKeepsNormalText() {
        XCTAssertEqual(TranscriptCleaner.clean("Bonjour, comment ça va?"),
                       "Bonjour, comment ça va?")
    }
}
