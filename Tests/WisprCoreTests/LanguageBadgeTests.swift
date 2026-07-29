import XCTest
@testable import WisprCore

final class LanguageBadgeTests: XCTestCase {
    @MainActor
    func testBadgeForPinnedAndFreeTranscription() {
        XCTAssertEqual(AppController.languageBadge(for: nil), "FT")
        XCTAssertEqual(AppController.languageBadge(for: ""), "FT")
        XCTAssertEqual(AppController.languageBadge(for: "en"), "EN")
        XCTAssertEqual(AppController.languageBadge(for: "fr"), "FR")
        XCTAssertEqual(AppController.languageBadge(for: "pt"), "PT")
    }
}
