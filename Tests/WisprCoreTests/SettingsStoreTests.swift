import XCTest
@testable import WisprCore

final class SettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "wispr-tests")!
        defaults.removePersistentDomain(forName: "wispr-tests")
    }

    func testDefaults() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.selectedModelID, "large-v3-turbo")
        XCTAssertEqual(store.hotkeyKeyCode, 63)
    }

    func testPersistsModelSelection() {
        let store = SettingsStore(defaults: defaults)
        store.selectedModelID = "small"
        XCTAssertEqual(SettingsStore(defaults: defaults).selectedModelID, "small")
    }

    func testPersistsHotkey() {
        let store = SettingsStore(defaults: defaults)
        store.hotkeyKeyCode = 54  // right command
        XCTAssertEqual(SettingsStore(defaults: defaults).hotkeyKeyCode, 54)
    }

    func testCleanupDefaults() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.cleanupEnabled)
        XCTAssertEqual(store.cleanupModelID, "qwen3-4b")
    }

    func testPersistsCleanupSettings() {
        let store = SettingsStore(defaults: defaults)
        store.cleanupEnabled = false
        store.cleanupModelID = "qwen2.5-1.5b"
        XCTAssertFalse(SettingsStore(defaults: defaults).cleanupEnabled)
        XCTAssertEqual(SettingsStore(defaults: defaults).cleanupModelID, "qwen2.5-1.5b")
    }
}
