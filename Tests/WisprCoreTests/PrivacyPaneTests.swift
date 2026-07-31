import XCTest
@testable import WisprCore

/// N10 (round 2): `PrivacyPane.nearestOption` is pure and deterministic —
/// no SwiftUI host needed — but had zero coverage. These tests exercise it
/// directly against option lists mirroring the pane's real
/// `retentionGBOptions`/`retentionDaysOptions`.
final class PrivacyPaneTests: XCTestCase {
    private let gbOptions = [1, 2, 5, 10, 25]

    func testExactMatchReturnsTheSameValue() {
        XCTAssertEqual(PrivacyPane.nearestOption(10, in: gbOptions), 10,
            "a value already on the list must round-trip unchanged")
    }

    func testValueBelowEveryOptionSnapsToTheSmallest() {
        XCTAssertEqual(PrivacyPane.nearestOption(0, in: gbOptions), 1,
            "a value under the smallest option must snap to the smallest, not be left unmatched")
    }

    /// The reviewer's exact scenario: a persisted 100 (GB) has no matching
    /// tick in this five-option list, so it must snap to the closest one
    /// (25), not the largest or a crash/nil fallback.
    func testValueAboveEveryOptionSnapsToTheLargest() {
        XCTAssertEqual(PrivacyPane.nearestOption(100, in: gbOptions), 25,
            "a value over the largest option must snap to the largest")
    }

    func testValueBetweenTwoOptionsSnapsToTheCloserOne() {
        // |2-3| = 1, |5-3| = 2, |1-3| = 2 — 2 is unambiguously closest.
        XCTAssertEqual(PrivacyPane.nearestOption(3, in: gbOptions), 2,
            "a value strictly closer to one option than any other must pick that one — "
                + "this would fail under a mutation that always returns the smallest or "
                + "largest option instead of actually comparing distances")
    }

    /// An exact tie must resolve deterministically rather than crash or
    /// vary — `min(by:)`'s documented behavior keeps the first element
    /// encountered when neither is strictly less than the other, i.e. the
    /// smaller of the two tied options for an ascending-sorted list.
    func testExactTieResolvesToTheFirstOptionEncountered() {
        XCTAssertEqual(PrivacyPane.nearestOption(3, in: [1, 5]), 1,
            "a value exactly equidistant between two options must deterministically pick "
                + "the first one in the list, not the last or an arbitrary one")
    }

    func testEmptyOptionsListFallsBackToTheValueItself() {
        XCTAssertEqual(PrivacyPane.nearestOption(42, in: []), 42,
            "an empty options list has nothing to snap to, so the value must pass through "
                + "unchanged rather than crash")
    }
}
