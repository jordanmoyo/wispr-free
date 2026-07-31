import XCTest
@testable import WisprCore

final class MeetingSettingsTests: XCTestCase {
    private func store() -> SettingsStore {
        let defaults = UserDefaults(suiteName: "meeting-settings-\(UUID().uuidString)")!
        return SettingsStore(defaults: defaults)
    }

    func testRetentionDefaults() {
        let settings = store()
        XCTAssertEqual(settings.meetingRetentionGB, 5)
        XCTAssertEqual(settings.meetingRetentionDays, 90)
        XCTAssertTrue(settings.meetingAutoDetect)
    }

    func testRetentionBytesDerivesFromGB() {
        let settings = store()
        settings.meetingRetentionGB = 2
        XCTAssertEqual(settings.meetingRetentionBytes, 2 * 1024 * 1024 * 1024)
    }

    func testRetentionGBIsClamped() {
        let settings = store()
        settings.meetingRetentionGB = 0
        XCTAssertEqual(settings.meetingRetentionGB, 1)
        settings.meetingRetentionGB = 9_999
        XCTAssertEqual(settings.meetingRetentionGB, 100)
        settings.meetingRetentionGB = -4
        XCTAssertEqual(settings.meetingRetentionGB, 1)
    }

    func testRetentionDaysIsClamped() {
        let settings = store()
        settings.meetingRetentionDays = 0
        XCTAssertEqual(settings.meetingRetentionDays, 1)
        settings.meetingRetentionDays = 99_999
        XCTAssertEqual(settings.meetingRetentionDays, 3_650)
    }

    func testRetentionRoundTrips() {
        let settings = store()
        settings.meetingRetentionGB = 25
        settings.meetingRetentionDays = 180
        settings.meetingAutoDetect = false
        XCTAssertEqual(settings.meetingRetentionGB, 25)
        XCTAssertEqual(settings.meetingRetentionDays, 180)
        XCTAssertFalse(settings.meetingAutoDetect)
    }

    /// C3: a value already out of range in `UserDefaults` — not just one
    /// passed through the setter — must come back clamped. Writing directly
    /// to `UserDefaults` (bypassing the clamping setter entirely) is what
    /// distinguishes this from `testRetentionGBIsClamped`/
    /// `testRetentionDaysIsClamped` above, which only ever exercise the
    /// setter's clamp. Reverting the getters back to
    /// `(defaults.object(forKey:) as? Int) ?? default` (no `min`/`max`)
    /// fails this test: it would read the raw out-of-range ints straight
    /// through.
    func testOutOfRangeStoredValuesAreClampedOnRead() {
        let defaults = UserDefaults(suiteName: "out-of-range-\(UUID().uuidString)")!
        defaults.set(-4, forKey: "meetingRetentionGB")
        defaults.set(0, forKey: "meetingRetentionDays")
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.meetingRetentionGB, 1,
            "a negative stored GB value must clamp to the floor on read, not pass through raw")
        XCTAssertEqual(settings.meetingRetentionDays, 1,
            "a stored 0 days value must clamp to the floor on read — unclamped, it would "
                + "push MeetingAudioStore.enforceRetention's cutoff to \"now\" and evict "
                + "every meeting's audio outright")

        defaults.set(9_999, forKey: "meetingRetentionGB")
        defaults.set(99_999, forKey: "meetingRetentionDays")
        XCTAssertEqual(settings.meetingRetentionGB, 100,
            "a stored GB value above the ceiling must clamp on read too")
        XCTAssertEqual(settings.meetingRetentionDays, 3_650,
            "a stored days value above the ceiling must clamp on read too")
    }

    func testCorruptStoredValuesFailOpenToDefaults() {
        let defaults = UserDefaults(suiteName: "corrupt-\(UUID().uuidString)")!
        defaults.set("not a number", forKey: "meetingRetentionGB")
        defaults.set("nonsense", forKey: "meetingRetentionDays")
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.meetingRetentionGB, 5)
        XCTAssertEqual(settings.meetingRetentionDays, 90)
    }
}
