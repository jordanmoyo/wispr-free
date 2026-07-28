import XCTest
@testable import WisprCore

final class ScaffoldTests: XCTestCase {
    func testErrorExists() {
        XCTAssertEqual(WisprError.modelNotLoaded, WisprError.modelNotLoaded)
    }
}
