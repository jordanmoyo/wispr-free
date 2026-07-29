import SwiftUI
import AppKit

struct AboutPane: View {
    @State private var showAcknowledgements = false

    var body: some View {
        VStack(spacing: 8) {
            BrandIcon(size: 96)
            Text("Wispr Free")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.top, 12)
            Text("Version \(version) · Free & open source")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
            Text("Push-to-talk dictation that never leaves your Mac.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: 12) {
                Button("View on GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/jordanmoyo/wispr-free")!)
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("Acknowledgements") { showAcknowledgements = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .popover(isPresented: $showAcknowledgements) {
                        acknowledgements
                    }
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private var acknowledgements: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wispr Free is built on:")
                .font(.system(size: 13, weight: .semibold))
            ackLink("WhisperKit — on-device speech recognition",
                    "https://github.com/argmaxinc/WhisperKit")
            ackLink("OpenAI Whisper — the speech models",
                    "https://github.com/openai/whisper")
            ackLink("MLX Swift — on-device LLM inference",
                    "https://github.com/ml-explore/mlx-swift")
        }
        .padding(16)
        .frame(width: 340)
    }

    private func ackLink(_ label: String, _ url: String) -> some View {
        Button {
            NSWorkspace.shared.open(URL(string: url)!)
        } label: {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.navy)
                .underline()
        }
        .buttonStyle(.plain)
    }
}
