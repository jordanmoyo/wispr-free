import AppKit
import XCTest
@testable import WisprCore

/// The pill itself is an `NSPanel` and needs a running app to exercise, so
/// what is tested here is the policy that decides its sharing type. The one
/// line in `show()` that applies the policy to the live panel has no
/// automated coverage — same AppKit-in-tests limitation already disclosed for
/// other view-level code in this project.
final class OverlayPillTests: XCTestCase {
    /// During a meeting the user is usually sharing their screen with the
    /// people in the call. Wispr's HUD — a "call detected" notice, an error
    /// message — is not theirs to see.
    func testThePillIsHiddenFromScreenSharesWhileAMeetingIsActive() {
        XCTAssertEqual(OverlayPill.sharingType(meetingActive: true), .none)
    }

    /// Outside a meeting the pill must stay capturable, or recording a
    /// screencast of Wispr would silently omit the thing being demonstrated.
    func testThePillStaysCapturableOutsideAMeeting() {
        XCTAssertEqual(OverlayPill.sharingType(meetingActive: false), .readOnly)
    }

    func testNonErrorPhasesUseTheRestingWidth() {
        XCTAssertEqual(OverlayPill.width(for: .recording), OverlayPill.baseWidth)
        XCTAssertEqual(OverlayPill.width(for: .transcribing), OverlayPill.baseWidth)
        XCTAssertEqual(OverlayPill.width(for: .cleaning), OverlayPill.baseWidth)
    }

    func testAShortErrorDoesNotWidenThePill() {
        XCTAssertEqual(OverlayPill.width(for: .error("Transcription failed")),
                       OverlayPill.baseWidth)
    }

    /// The resting width leaves 147pt for text, which cut this message off
    /// after "check mic i…". These messages are the only thing telling the
    /// user why nothing was typed, so the pill has to fit them.
    func testALongErrorWidensThePillEnoughToFitTheWholeMessage() {
        let message = "No audio captured — check mic in System Settings → Sound"
        let width = OverlayPill.width(for: .error(message))
        XCTAssertGreaterThan(width, OverlayPill.baseWidth)
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        let textWidth = (message as NSString).size(withAttributes: [.font: font]).width
        // 14pt padding each side, the 17pt warning glyph, 8pt HStack spacing.
        XCTAssertGreaterThanOrEqual(width, textWidth + 14 * 2 + 17 + 8)
    }

    func testAnAbsurdlyLongErrorIsClamped() {
        XCTAssertEqual(OverlayPill.width(for: .error(String(repeating: "wide ", count: 200))),
                       OverlayPill.maximumWidth)
    }
}
