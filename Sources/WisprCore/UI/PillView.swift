import SwiftUI

public struct PillView: View {
    @ObservedObject var state: PillState

    static let brandYellow = Color(red: 0xF5 / 255, green: 0xC5 / 255, blue: 0x18 / 255)
    static let brandNavy = Color(red: 0x1A / 255, green: 0x1D / 255, blue: 0x3A / 255)

    public init(state: PillState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 8) {
            switch state.phase {
            case .recording:
                // Brand waveform pill: dark bars pulse in a staggered
                // ripple; the capsule's glow reacts to the live voice level.
                WaveformBars()
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Transcribing…").font(.caption)
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message).font(.caption).lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            if case .recording = state.phase {
                let level = state.displayLevel
                Capsule()
                    .fill(Self.brandYellow)
                    .shadow(color: Self.brandYellow.opacity(0.3 + 0.7 * level),
                            radius: 3 + 9 * level)
                    .animation(.easeInOut(duration: 0.2), value: level)
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// The five bars of the brand mark, pulsing in a gentle staggered ripple
/// (~1.2 s loop, soft ease) while recording.
private struct WaveformBars: View {
    @State private var animating = false
    // Bar height ratios from the brand mark (56/108/152/108/56 of 152).
    private static let heights: [CGFloat] = [6, 11, 16, 11, 6]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(PillView.brandNavy)
                    .frame(width: 3.5, height: Self.heights[index])
                    .scaleEffect(y: animating ? 0.35 : 1, anchor: .center)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animating)
            }
        }
        .frame(height: 16)
        .onAppear { animating = true }
    }
}
