import SwiftUI

struct PrivacyPane: View {
    let context: MainWindowContext

    @State private var historyEnabled = true
    @State private var showDeleteConfirm = false

    var body: some View {
        PaneScaffold(title: "Privacy") {
            VStack(alignment: .leading, spacing: 0) {
                heroCard
                    .padding(.bottom, 20)

                factRow("Audio recordings stored", "Never")
                factRow("Transcripts stored", "On this Mac only")
                factRow("Network access",
                        "Optional update check · model downloads")

                SettingsRow(title: "Keep dictation history",
                            caption: "Turn off to transcribe without saving anything") {
                    ThemeToggle(isOn: $historyEnabled)
                }

                HStack {
                    Spacer()
                    Button("Delete All Data…") { showDeleteConfirm = true }
                        .buttonStyle(DestructiveOutlineButtonStyle())
                }
                .padding(.vertical, 16)
            }
        }
        .onAppear { historyEnabled = context.settings.historyEnabled }
        .onChange(of: historyEnabled) { _, enabled in
            context.settings.historyEnabled = enabled
        }
        .alert("Delete all data?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Everything", role: .destructive) {
                Task {
                    await context.historyStore.clear()
                    await context.correctionStore.removeAll()
                    NotificationCenter.default.post(name: .wisprHistoryDidChange, object: nil)
                }
            }
        } message: {
            Text("Permanently deletes all dictation history and learned corrections. This cannot be undone.")
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Local by design.")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.gold)
            Text("Audio is transcribed on-device and discarded immediately — your voice and text never leave this Mac. The only network calls Wispr Free ever makes are one-time model downloads and an optional daily update check, both of which you control. See PRIVACY.md for the full accounting.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.lightLavender)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.deepNavy))
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(value)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.vertical, 13)
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}
