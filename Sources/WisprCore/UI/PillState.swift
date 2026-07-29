import SwiftUI

public final class PillState: ObservableObject {
    public enum Phase: Equatable {
        case recording
        case transcribing
        case cleaning
        case error(String)
    }

    @Published public var phase: Phase = .recording
    @Published public var levels: [Float] = []
    /// Two-letter dictation-language reminder shown under the waveform:
    /// "EN"/"FR" when pinned, "FT" for free (auto-detect) transcription.
    @Published public var languageBadge: String = "FT"
    /// Envelope-smoothed voice level (0...1) for display: fast attack,
    /// slow release, like an audio meter — avoids flicker from raw RMS.
    @Published public var displayLevel: Double = 0
    /// Whether the hold-recording has been "locked" via the shift-tap
    /// gesture, so the hotkey can be released without stopping it. Settable
    /// only within the module (`OverlayPill` resets it in `showRecording()`);
    /// flipped true only via `showLocked()`.
    @Published public internal(set) var locked = false

    public init() {}

    public func showLocked() {
        locked = true
    }

    public func pushLevel(_ level: Float) {
        levels.append(level)
        if levels.count > 30 { levels.removeFirst(levels.count - 30) }

        let target = pow(min(1, Double(level) * 1.8), 0.45)
        if target > displayLevel {
            displayLevel = displayLevel * 0.4 + target * 0.6
        } else {
            displayLevel = displayLevel * 0.88 + target * 0.12
        }
    }
}
