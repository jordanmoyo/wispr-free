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

    func testUpdateCheckDefaultsToEnabled() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.updateCheckEnabled)
    }

    func testPersistsUpdateCheckSetting() {
        let store = SettingsStore(defaults: defaults)
        store.updateCheckEnabled = false
        XCTAssertFalse(SettingsStore(defaults: defaults).updateCheckEnabled)
    }

    func testHistoryEnabledDefaultsToTrue() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.historyEnabled)
    }

    func testPersistsHistoryEnabledSetting() {
        let store = SettingsStore(defaults: defaults)
        store.historyEnabled = false
        XCTAssertFalse(SettingsStore(defaults: defaults).historyEnabled)
    }

    func testLearningEnabledDefaultsToTrue() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.learningEnabled)
    }

    func testPersistsLearningEnabledSetting() {
        let store = SettingsStore(defaults: defaults)
        store.learningEnabled = false
        XCTAssertFalse(SettingsStore(defaults: defaults).learningEnabled)
    }

    func testDeliveryRulesDefaultsToEmpty() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.deliveryRules, [])
    }

    func testPersistsDeliveryRules() {
        let store = SettingsStore(defaults: defaults)
        let rules = [
            DeliveryRule(bundleID: "com.apple.Terminal", displayName: "Terminal", mode: .insert),
            DeliveryRule(bundleID: "com.example.App", displayName: "App", mode: .insertAndSend),
        ]
        store.deliveryRules = rules
        XCTAssertEqual(SettingsStore(defaults: defaults).deliveryRules, rules)
    }

    func testPreRollEnabledDefaultsToFalse() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.preRollEnabled)
    }

    func testPersistsPreRollEnabledSetting() {
        let store = SettingsStore(defaults: defaults)
        store.preRollEnabled = true
        XCTAssertTrue(SettingsStore(defaults: defaults).preRollEnabled)
    }

    func testCorruptDeliveryRulesDataDecodesToEmpty() {
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: "deliveryRules")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.deliveryRules, [])
    }

    func testFeedbackSoundsDefaultsToFalseAndPersists() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.feedbackSounds)
        store.feedbackSounds = true
        XCTAssertTrue(SettingsStore(defaults: defaults).feedbackSounds)
    }

    func testRetainAudioDefaultsToFalseAndPersists() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.retainAudio)
        store.retainAudio = true
        XCTAssertTrue(SettingsStore(defaults: defaults).retainAudio)
    }

    func testActivationModeDefaultsToHoldAndPersists() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.activationMode, .hold)
        store.activationMode = .toggle
        XCTAssertEqual(SettingsStore(defaults: defaults).activationMode, .toggle)
    }

    func testUnknownActivationModeFailsOpenToHold() {
        defaults.set("waveHands", forKey: "activationMode")
        XCTAssertEqual(SettingsStore(defaults: defaults).activationMode, .hold)
    }

    func testPillPositionDefaultsToBottomCenterAndPersists() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.pillPosition, .bottomCenter)
        store.pillPosition = .nearCursor
        XCTAssertEqual(SettingsStore(defaults: defaults).pillPosition, .nearCursor)
    }

    func testUnknownPillPositionFailsOpenToBottomCenter() {
        defaults.set("underTheRug", forKey: "pillPosition")
        XCTAssertEqual(SettingsStore(defaults: defaults).pillPosition, .bottomCenter)
    }

    func testInputDeviceUIDDefaultsToNilAndPersistsIncludingReset() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertNil(store.inputDeviceUID)
        store.inputDeviceUID = "BuiltInMicrophoneDevice"
        XCTAssertEqual(SettingsStore(defaults: defaults).inputDeviceUID, "BuiltInMicrophoneDevice")
        store.inputDeviceUID = nil
        XCTAssertNil(SettingsStore(defaults: defaults).inputDeviceUID)
    }
}
