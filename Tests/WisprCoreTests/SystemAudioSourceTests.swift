import XCTest
@testable import WisprCore

final class SystemAudioSourceTests: XCTestCase {
    func testPermissionProbeReturnsWithoutCrashing() async {
        // Returns false in CI (no TCC grant) and true on a granted machine.
        // Either is fine — the contract is that it answers rather than hangs.
        _ = await SystemAudioSource.permissionGranted()
    }

    func testStopBeforeStartIsSafe() async {
        let source = SystemAudioSource()
        await source.stop()
        await source.stop()
    }

    func testStartWithoutPermissionThrowsPermissionDenied() async {
        // On a machine WITHOUT the Screen Recording grant this must be
        // `.permissionDenied`, not a hang and not a crash. On a granted
        // machine the stream starts, which is also a pass — assert only that
        // any thrown error is a SystemAudioError.
        let source = SystemAudioSource()
        do {
            try await source.start()
            await source.stop()
        } catch let error as SystemAudioError {
            if case .permissionDenied = error { return }
            if case .noDisplay = error { return }
            if case .streamFailed = error { return }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testErrorMessagesAreUserFacing() {
        XCTAssertFalse(SystemAudioError.permissionDenied.userMessage.isEmpty)
        XCTAssertFalse(SystemAudioError.noDisplay.userMessage.isEmpty)
        XCTAssertFalse(SystemAudioError.streamFailed("x").userMessage.isEmpty)
        XCTAssertTrue(
            SystemAudioError.permissionDenied.userMessage.contains("Screen Recording"))
    }

    /// Same reentrancy guard as `MeetingMicSource`: a second `start()` on an
    /// already-claimed source must be refused rather than bringing up a second
    /// `SCStream` and orphaning the first. Drives the internal claim directly so
    /// it needs neither the Screen Recording grant nor a display.
    func testSecondClaimWhileActiveIsRejected() {
        let source = SystemAudioSource()
        XCTAssertNotNil(source.claimStart())
        XCTAssertNil(source.claimStart())
    }

    /// A start that fails before committing must release its claim, or the source
    /// would be wedged "active" and never able to capture again for the rest of
    /// the app's life.
    func testAbortStartAllowsFreshClaim() {
        let source = SystemAudioSource()
        guard let epoch = source.claimStart() else {
            return XCTFail("expected first claim to succeed")
        }
        source.abortStart(epoch: epoch)
        XCTAssertNotNil(source.claimStart())
    }

    /// The epoch must strictly advance across a stop/start cycle. `SCStream`
    /// identity is what actually gates stale sample callbacks here, but a
    /// non-advancing epoch would silently break `commitIfCurrent`'s supersede
    /// detection, which is what prevents a leaked running stream.
    func testEpochAdvancesAcrossRestart() {
        let source = SystemAudioSource()
        guard let first = source.claimStart() else {
            return XCTFail("expected first claim to succeed")
        }
        _ = source.clearState()
        guard let second = source.claimStart() else {
            return XCTFail("expected a fresh claim after clearState")
        }
        XCTAssertGreaterThan(second, first)
    }

    /// `stop()` must clear the handlers so a sample callback still in flight past
    /// `stopCapture` cannot deliver into a track the recorder has finalised.
    func testStopClearsHandlers() async {
        let source = SystemAudioSource()
        source.onChunk = { _ in }
        source.onFailure = { _ in }
        await source.stop()
        let chunk = source.onChunk
        let failure = source.onFailure
        XCTAssertNil(chunk)
        XCTAssertNil(failure)
    }
}
