import XCTest
@testable import WisprCore

final class HotkeyOptionsTests: XCTestCase {
    func testFnIsFirstAndDefault() {
        XCTAssertEqual(HotkeyOptions.all.first?.id, 63)
        XCTAssertEqual(HotkeyOptions.all.first?.label, "Fn (Globe)")
    }

    func testContainsAlternatives() {
        let ids = HotkeyOptions.all.map(\.id)
        XCTAssertEqual(ids, [63, 54, 61, 96, 105])
    }
}
