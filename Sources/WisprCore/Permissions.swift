import AVFoundation
import AppKit
import ApplicationServices

public enum Permissions {
    public enum Pane {
        case microphone, accessibility, inputMonitoring

        var settingsURL: String {
            switch self {
            case .microphone:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            case .accessibility:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .inputMonitoring:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            }
        }
    }

    public static func microphoneGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public static func accessibilityGranted() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static func inputMonitoringGranted() -> Bool {
        CGPreflightListenEventAccess()
    }

    /// Prompts the system dialog for input monitoring if not yet determined.
    public static func requestInputMonitoring() {
        CGRequestListenEventAccess()
    }

    public static func openSystemSettings(pane: Pane) {
        if let url = URL(string: pane.settingsURL) {
            NSWorkspace.shared.open(url)
        }
    }
}

public enum DictationGate {
    public static let minimumSeconds = 0.3

    public static func shouldTranscribe(samples: [Float]) -> Bool {
        Double(samples.count) / AudioResampler.targetSampleRate >= minimumSeconds
    }

    /// Same gate as `shouldTranscribe(samples:)`, but against a sample count
    /// directly (used when the samples array includes pre-roll seed audio
    /// that shouldn't count toward the "did the user actually speak" check).
    public static func shouldTranscribe(sampleCount: Int) -> Bool {
        Double(sampleCount) / AudioResampler.targetSampleRate >= minimumSeconds
    }
}
