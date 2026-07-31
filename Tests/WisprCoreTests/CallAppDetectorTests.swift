import XCTest
@testable import WisprCore

final class CallAppDetectorTests: XCTestCase {
    func testKnownAppsCoverTheMajorClients() {
        let ids = Set(CallAppDetector.knownApps.map(\.bundleID))
        XCTAssertTrue(ids.contains("us.zoom.xos"))
        XCTAssertTrue(ids.contains("com.microsoft.teams2"))
        XCTAssertTrue(ids.contains("com.apple.FaceTime"))
        XCTAssertTrue(CallAppDetector.knownApps.allSatisfy { !$0.name.isEmpty })
    }

    func testCallAppFindsARunningClient() {
        let found = CallAppDetector.callApp(
            among: ["com.apple.Finder", "us.zoom.xos"])
        XCTAssertEqual(found?.bundleID, "us.zoom.xos")
        XCTAssertEqual(found?.name, "Zoom")
    }

    func testCallAppReturnsNilWithNoClientRunning() {
        XCTAssertNil(CallAppDetector.callApp(
            among: ["com.apple.Finder", "com.apple.Safari"]))
    }

    func testCallAppIsDeterministicWithSeveralRunning() {
        // Registry order decides, so repeated calls give the same answer.
        let running: Set<String> = ["us.zoom.xos", "com.apple.FaceTime"]
        let first = CallAppDetector.callApp(among: running)
        let second = CallAppDetector.callApp(among: running)
        XCTAssertEqual(first, second)
        XCTAssertNotNil(first)
    }

    func testShouldOfferRequiresBothSignals() {
        let zoom = CallApp(bundleID: "us.zoom.xos", name: "Zoom")
        XCTAssertTrue(CallAppDetector.shouldOffer(
            callApp: zoom, micInUse: true, alreadyOffered: false, isRecording: false))
        // App running but mic idle: Zoom is just open.
        XCTAssertFalse(CallAppDetector.shouldOffer(
            callApp: zoom, micInUse: false, alreadyOffered: false, isRecording: false))
        // Mic busy but no conferencing app: something else is recording.
        XCTAssertFalse(CallAppDetector.shouldOffer(
            callApp: nil, micInUse: true, alreadyOffered: false, isRecording: false))
    }

    func testShouldNotOfferTwiceForTheSameCall() {
        let zoom = CallApp(bundleID: "us.zoom.xos", name: "Zoom")
        XCTAssertFalse(CallAppDetector.shouldOffer(
            callApp: zoom, micInUse: true, alreadyOffered: true, isRecording: false))
    }

    func testShouldNotOfferWhileAlreadyRecording() {
        let zoom = CallApp(bundleID: "us.zoom.xos", name: "Zoom")
        XCTAssertFalse(CallAppDetector.shouldOffer(
            callApp: zoom, micInUse: true, alreadyOffered: false, isRecording: true))
    }

    func testInputDeviceProbeAnswersWithoutCrashing() {
        _ = CallAppDetector.inputDeviceInUse()
    }

    @MainActor
    func testMonitorStopIsSafeBeforeStart() {
        let monitor = CallAppMonitor()
        monitor.stop()
        monitor.stop()
    }

    /// Reproduces the exact ordering a shipped bug class in this project has
    /// hit three times: a Timer fires and queues its relay `Task` while the
    /// monitor is running, `stop()` runs before that `Task` gets its
    /// MainActor turn, and the straggler executes anyway because `self` is
    /// still alive. `relayPoll()` is the actual method the Timer callback
    /// invokes (not a re-derivation of its logic), so calling it directly
    /// after `start()` + `stop()` reproduces the race deterministically —
    /// no reliance on real Timer/RunLoop timing, so it can't be flaky.
    @MainActor
    func testStragglerRelayAfterStopIsANoOp() {
        let monitor = CallAppMonitor()
        let zoom = CallApp(bundleID: "us.zoom.xos", name: "Zoom")
        var fired = 0
        monitor.onDetected = { _ in fired += 1 }
        monitor.isRecordingProvider = { false }
        monitor.runningBundleIDsProvider = { [zoom.bundleID] }
        monitor.micInUseProvider = { true }

        monitor.start()
        monitor.stop()
        // The straggler: as if the Timer had already fired and queued this
        // before stop() ran, but only gets to execute now.
        monitor.relayPoll()

        XCTAssertEqual(fired, 0)
    }

    /// The real start()/stop() path (not just poll()) must not crash and
    /// must leave the monitor able to be started again cleanly.
    @MainActor
    func testMonitorStartStopStartIsSafeAndUsable() {
        let monitor = CallAppMonitor()
        let zoom = CallApp(bundleID: "us.zoom.xos", name: "Zoom")
        var fired = 0
        monitor.onDetected = { _ in fired += 1 }
        monitor.isRecordingProvider = { false }
        monitor.runningBundleIDsProvider = { [zoom.bundleID] }
        monitor.micInUseProvider = { true }

        monitor.start()
        monitor.stop()
        monitor.start()
        // A straggler relay from the second start() must still be honored.
        monitor.relayPoll()
        XCTAssertEqual(fired, 1)
        monitor.stop()
    }

    @MainActor
    func testMonitorDoesNotFireWhileRecording() {
        let monitor = CallAppMonitor()
        var fired = 0
        monitor.onDetected = { (_: CallApp) in fired += 1 }
        monitor.isRecordingProvider = { true }
        monitor.poll()
        XCTAssertEqual(fired, 0)
    }

    /// Same scenario as above, but with the app-running and mic-busy signals
    /// forced true via the injectable providers. Without forcing both
    /// signals, the test above passes in CI purely because no real
    /// conferencing app happens to be running on the test host — it would
    /// pass even if the `isRecording` gate were deleted entirely. This
    /// version isolates the gate itself.
    @MainActor
    func testMonitorDoesNotFireWhileRecordingWithRealSignalsForced() {
        let monitor = CallAppMonitor()
        let zoom = CallApp(bundleID: "us.zoom.xos", name: "Zoom")
        var fired = 0
        monitor.onDetected = { _ in fired += 1 }
        monitor.isRecordingProvider = { true }
        monitor.runningBundleIDsProvider = { [zoom.bundleID] }
        monitor.micInUseProvider = { true }
        monitor.poll()
        XCTAssertEqual(fired, 0)
    }

    // MARK: - Regression coverage beyond the brief's minimum

    /// Drives the real monitor (not a re-derivation of the logic) through a
    /// full detect -> still-on-call -> call-ended -> new-call cycle via the
    /// injectable providers, proving the "reset only when the condition goes
    /// false" latch rule holds across repeated polls, not just a single call.
    @MainActor
    func testMonitorLatchResetsOnlyWhenConditionGoesFalse() {
        let monitor = CallAppMonitor()
        let zoom = CallApp(bundleID: "us.zoom.xos", name: "Zoom")
        var detections: [CallApp] = []
        monitor.onDetected = { detections.append($0) }
        monitor.isRecordingProvider = { false }

        monitor.runningBundleIDsProvider = { [zoom.bundleID] }
        monitor.micInUseProvider = { true }
        monitor.poll()
        XCTAssertEqual(detections.count, 1)

        // Still on the same call, steady conditions, multiple polls: latched,
        // no repeat offer. A reset that fires unconditionally on every
        // non-offering poll (instead of only when the condition goes false)
        // would un-latch here and double-fire on the next poll below, even
        // though the call never actually paused.
        monitor.poll()
        XCTAssertEqual(detections.count, 1)
        monitor.poll()
        XCTAssertEqual(detections.count, 1)

        // Call ends: mic goes idle, latch resets.
        monitor.micInUseProvider = { false }
        monitor.poll()
        XCTAssertEqual(detections.count, 1)

        // A new call starts: offered again.
        monitor.micInUseProvider = { true }
        monitor.poll()
        XCTAssertEqual(detections.count, 2)
    }

    /// The latch must also reset when the conferencing app itself quits,
    /// even if something else keeps the mic busy afterward (e.g. dictation).
    @MainActor
    func testMonitorLatchResetsWhenAppQuitsEvenIfMicStaysBusy() {
        let monitor = CallAppMonitor()
        let zoom = CallApp(bundleID: "us.zoom.xos", name: "Zoom")
        var detections: [CallApp] = []
        monitor.onDetected = { detections.append($0) }
        monitor.isRecordingProvider = { false }
        monitor.micInUseProvider = { true }

        monitor.runningBundleIDsProvider = { [zoom.bundleID] }
        monitor.poll()
        XCTAssertEqual(detections.count, 1)

        monitor.runningBundleIDsProvider = { [] }
        monitor.poll()
        XCTAssertEqual(detections.count, 1)

        monitor.runningBundleIDsProvider = { [zoom.bundleID] }
        monitor.poll()
        XCTAssertEqual(detections.count, 2)
    }

    /// isRecording must gate detection without ever mutating the latch, so a
    /// call that started before Wispr's own recording is still offered once
    /// that recording ends.
    @MainActor
    func testMonitorOffersAfterOwnRecordingEndsIfCallStillActive() {
        let monitor = CallAppMonitor()
        let zoom = CallApp(bundleID: "us.zoom.xos", name: "Zoom")
        var detections: [CallApp] = []
        monitor.onDetected = { detections.append($0) }
        monitor.runningBundleIDsProvider = { [zoom.bundleID] }
        monitor.micInUseProvider = { true }

        var recording = true
        monitor.isRecordingProvider = { recording }
        monitor.poll()
        XCTAssertEqual(detections.count, 0)

        recording = false
        monitor.poll()
        XCTAssertEqual(detections.count, 1)
    }
}
