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
                // The language initials sit under the bars as a reminder of
                // the dictation language (EN / FR / FT).
                VStack(spacing: 1) {
                    WaveformBars()
                    Text(state.languageBadge)
                        .font(.system(size: 7, weight: .bold))
                        .kerning(1.2)
                        .foregroundStyle(Self.brandNavy.opacity(0.55))
                }
            case .transcribing:
                // Inverse of the recording state: the brand bars in gold
                // ripple on a navy capsule while the model works.
                TranscribingBars()
                Text("Transcribing")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.92))
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message).font(.caption).lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            switch state.phase {
            case .recording:
                let level = state.displayLevel
                Capsule()
                    .fill(Self.brandYellow)
                    .shadow(color: Self.brandYellow.opacity(0.3 + 0.7 * level),
                            radius: 3 + 9 * level)
                    .animation(.easeInOut(duration: 0.2), value: level)
            case .transcribing:
                Capsule()
                    .fill(Self.brandNavy)
                    .shadow(color: Self.brandYellow.opacity(0.35), radius: 6)
            case .error:
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

/// The brand bars in gold, running a continuous staggered ripple on the
/// navy capsule while the model transcribes — the app's own "spinner".
private struct TranscribingBars: View {
    @State private var animating = false
    private static let heights: [CGFloat] = [5, 9, 13, 9, 5]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(PillView.brandYellow)
                    .frame(width: 3, height: Self.heights[index])
                    .scaleEffect(y: animating ? 0.3 : 1, anchor: .center)
                    .opacity(animating ? 0.45 : 1)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.12),
                        value: animating)
            }
        }
        .frame(height: 13)
        .onAppear { animating = true }
    }
}
