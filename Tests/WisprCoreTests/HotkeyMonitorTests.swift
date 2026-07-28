import XCTest
import CoreGraphics
@testable import WisprCore

final class HotkeyMonitorTests: XCTestCase {
    private func event(type: CGEventType, code: Int64, flags: CGEventFlags) -> CGEvent {
        let e = CGEvent(source: nil)!
        e.type = type
        e.setIntegerValueField(.keyboardEventKeycode, value: code)
        e.flags = flags
        return e
    }

    private func waitForMain() {
        let exp = expectation(description: "main queue drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
    }

    func testRightCommandPressAndReleaseViaFlagsChanged() {
        let monitor = HotkeyMonitor()
        monitor.keyCode = 54  // Right Command — a modifier: emits flagsChanged only
        var presses = 0
        var releases = 0
        monitor.onPress = { presses += 1 }
        monitor.onRelease = { releases += 1 }

        monitor.handle(type: .flagsChanged, event: event(type: .flagsChanged, code: 54, flags: .maskCommand))
        waitForMain()
        XCTAssertEqual(presses, 1, "modifier key down must trigger onPress")

        monitor.handle(type: .flagsChanged, event: event(type: .flagsChanged, code: 54, flags: []))
        waitForMain()
        XCTAssertEqual(releases, 1, "modifier key up must trigger onRelease")
    }

    func testRightOptionUsesAlternateMask() {
        let monitor = HotkeyMonitor()
        monitor.keyCode = 61  // Right Option
        var presses = 0
        monitor.onPress = { presses += 1 }

        monitor.handle(type: .flagsChanged, event: event(type: .flagsChanged, code: 61, flags: .maskAlternate))
        waitForMain()
        XCTAssertEqual(presses, 1)
    }

    func testOtherModifierKeyDoesNotTrigger() {
        let monitor = HotkeyMonitor()
        monitor.keyCode = 54
        var presses = 0
        monitor.onPress = { presses += 1 }

        // Left Command (55) changes the same flag but is a different key.
        monitor.handle(type: .flagsChanged, event: event(type: .flagsChanged, code: 55, flags: .maskCommand))
        waitForMain()
        XCTAssertEqual(presses, 0)
    }

    func testFnStillWorksViaSecondaryFnMask() {
        let monitor = HotkeyMonitor()
        monitor.keyCode = 63
        var presses = 0
        var releases = 0
        monitor.onPress = { presses += 1 }
        monitor.onRelease = { releases += 1 }

        monitor.handle(type: .flagsChanged, event: event(type: .flagsChanged, code: 63, flags: .maskSecondaryFn))
        monitor.handle(type: .flagsChanged, event: event(type: .flagsChanged, code: 63, flags: []))
        waitForMain()
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(releases, 1)
    }

    func testRegularKeyUsesKeyDownKeyUp() {
        let monitor = HotkeyMonitor()
        monitor.keyCode = 96  // F5 — a regular key
        var presses = 0
        var releases = 0
        monitor.onPress = { presses += 1 }
        monitor.onRelease = { releases += 1 }

        monitor.handle(type: .keyDown, event: event(type: .keyDown, code: 96, flags: []))
        monitor.handle(type: .keyUp, event: event(type: .keyUp, code: 96, flags: []))
        waitForMain()
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(releases, 1)
    }
}
