import XCTest
@testable import WisprCore

/// The Transcribe pane's SwiftUI body is not unit-testable here, so these
/// cover what is: the sidebar tab wiring and the pure menu-label helper —
/// the same shape as `PrivacyPaneTests` and `LanguageBadgeTests`.
final class TranscribePaneTests: XCTestCase {
    func testTranscribeTabExistsWithItsLabel() {
        XCTAssertEqual(MainTab.transcribe.label, "Transcribe")
    }

    func testTranscribeSitsInTheDictationGroupAfterMeetings() {
        let dictation = MainTab.groups.first { $0.label == "Dictation" }
        XCTAssertNotNil(dictation)
        XCTAssertEqual(dictation?.tabs, [.history, .meetings, .transcribe, .learning])
    }

    func testEveryTabIsReachableFromSomeGroup() {
        let grouped = Set(MainTab.groups.flatMap(\.tabs))
        for tab in MainTab.allCases {
            XCTAssertTrue(grouped.contains(tab), "\(tab) is in no sidebar group")
        }
    }

    func testInstalledModelLabelHasNoDownloadSuffix() {
        XCTAssertEqual(
            TranscribePane.modelMenuLabel(displayName: "Small", approxSizeMB: 480,
                                          installed: true),
            "Small")
    }

    func testUninstalledModelLabelStatesTheDownloadSize() {
        XCTAssertEqual(
            TranscribePane.modelMenuLabel(displayName: "Large v3 Turbo",
                                          approxSizeMB: 1_600, installed: false),
            "Large v3 Turbo  (↓ 1.6 GB)")
    }
}
