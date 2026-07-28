import SwiftUI

public final class PillState: ObservableObject {
    public enum Phase: Equatable {
        case recording
        case transcribing
        case error(String)
    }

    @Published public var phase: Phase = .recording
    @Published public var levels: [Float] = []
    /// Envelope-smoothed voice level (0...1) for display: fast attack,
    /// slow release, like an audio meter — avoids flicker from raw RMS.
    @Published public var displayLevel: Double = 0

    public init() {}

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
