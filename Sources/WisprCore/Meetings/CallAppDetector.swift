import AppKit
import CoreAudio
import Foundation

public struct CallApp: Sendable, Equatable {
    public let bundleID: String
    public let name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Detects that a call is in progress so Wispr can offer to record it.
///
/// The test is deliberately conjunctive: a conferencing app must be running
/// AND the input device must be in use. Zoom idling in the Dock is not a
/// call, and a busy mic alone is any recording app. This is a heuristic, not
/// a certainty — a call over a browser tab, or a headset that reports
/// "running" while muted, can both go undetected or misfire. Callers must
/// treat a detection as an offer to record, never as proof a call exists.
public enum CallAppDetector {
    /// Deliberately excludes general-purpose browsers (Safari, Chrome, etc.).
    /// Having one open is the normal state of a Mac and would make the mic
    /// conjunction meaningless — nearly everyone has a browser tab capturing
    /// microphone-adjacent focus at some point in the day. Every entry here
    /// is a dedicated calling/conferencing client instead.
    public static let knownApps: [CallApp] = [
        CallApp(bundleID: "us.zoom.xos", name: "Zoom"),
        CallApp(bundleID: "com.microsoft.teams2", name: "Teams"),
        CallApp(bundleID: "com.microsoft.teams", name: "Teams"),
        CallApp(bundleID: "com.apple.FaceTime", name: "FaceTime"),
        CallApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
        CallApp(bundleID: "com.cisco.webexmeetingsapp", name: "Webex"),
        CallApp(bundleID: "Cisco-Systems.Spark", name: "Webex"),
        CallApp(bundleID: "com.hnc.Discord", name: "Discord"),
    ]

    /// First registry match among the running apps, so the answer is stable
    /// across polls rather than depending on process enumeration order.
    public static func callApp(among runningBundleIDs: Set<String>) -> CallApp? {
        knownApps.first { runningBundleIDs.contains($0.bundleID) }
    }

    public static func shouldOffer(
        callApp: CallApp?, micInUse: Bool, alreadyOffered: Bool, isRecording: Bool
    ) -> Bool {
        guard callApp != nil, micInUse, !alreadyOffered, !isRecording else { return false }
        return true
    }

    /// True when something on the system is currently pulling from the
    /// default input device. Requires no permission of its own — it is a
    /// device-level flag, not a per-app read of the mic stream.
    public static func inputDeviceInUse() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
            deviceID != kAudioObjectUnknown
        else {
            return false
        }

        var running = UInt32(0)
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            deviceID, &runningAddress, 0, nil, &runningSize, &running) == noErr
        else {
            return false
        }
        return running != 0
    }
}

/// Polls for a call in progress and fires `onDetected` once per call.
///
/// Owns its own `Timer` for the poll loop. `start()`/`stop()` are idempotent
/// so a caller can call either freely without tracking whether the monitor
/// is already running, and `deinit` invalidates any live timer so the loop
/// can never outlive the monitor that owns it (a leaked `Timer` with only a
/// weak self would otherwise fire forever as a silent no-op).
@MainActor
public final class CallAppMonitor {
    public var onDetected: ((CallApp) -> Void)?
    /// Suppresses detection while a meeting or dictation is already running.
    public var isRecordingProvider: (() -> Bool)?

    /// Test seam: defaults to the real running-application registry.
    var runningBundleIDsProvider: () -> Set<String> = {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
    /// Test seam: defaults to the real CoreAudio probe.
    var micInUseProvider: () -> Bool = { CallAppDetector.inputDeviceInUse() }

    private let interval: TimeInterval
    private var timer: Timer?
    private var alreadyOffered = false
    /// Guards against a straggler: the Timer fires and schedules the relay
    /// `Task`, then `stop()` runs, then the already-queued `Task` finally
    /// gets its MainActor turn. `self` is still alive at that point (`[weak
    /// self]` alone does not help), so without this flag the straggler would
    /// call `poll()` — and possibly fire `onDetected` — after the user
    /// turned detection off.
    private var isRunning = false

    public init(interval: TimeInterval = 5) {
        self.interval = interval
    }

    deinit {
        timer?.invalidate()
    }

    public func start() {
        guard timer == nil else { return }
        isRunning = true
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.relayPoll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    /// What the Timer's relay `Task` actually calls. Separated from `poll()`
    /// so `poll()` itself stays directly callable by tests regardless of
    /// `start()`/`stop()` state (as the brief's own tests do), while this
    /// method carries the "did we get stopped before our turn?" check that
    /// only applies to the real timer-driven path. Internal so tests can
    /// invoke it directly to reproduce the straggler ordering deterministically,
    /// without depending on real Timer/RunLoop race timing.
    func relayPoll() {
        guard isRunning else { return }
        poll()
    }

    /// One detection pass. Public so tests can drive it without a run loop.
    public func poll() {
        let running = runningBundleIDsProvider()
        let app = CallAppDetector.callApp(among: running)
        let micInUse = micInUseProvider()
        let isRecording = isRecordingProvider?() ?? false

        guard CallAppDetector.shouldOffer(
            callApp: app, micInUse: micInUse, alreadyOffered: alreadyOffered,
            isRecording: isRecording)
        else {
            // Reset the latch when the call ends so the next one is offered.
            // isRecording never touches the latch: a call that started
            // before Wispr's own recording must still be offered once that
            // recording ends, not silently dropped.
            if app == nil || !micInUse { alreadyOffered = false }
            return
        }
        alreadyOffered = true
        if let app { onDetected?(app) }
    }
}
