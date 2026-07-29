import SwiftUI

struct LearningPane: View {
    let context: MainWindowContext

    @State private var corrections: [Correction] = []
    @State private var learningEnabled = true
    @State private var showForgetAllConfirm = false

    var body: some View {
        PaneScaffold(
            title: "Learning",
            subtitle: "Corrections you make to delivered text are remembered and applied to future dictations. Everything stays on this Mac."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(title: "Learn from your corrections",
                            caption: "Learns wrong → right word pairs when you edit past dictations") {
                    ThemeToggle(isOn: $learningEnabled)
                }
                .padding(.bottom, 14)

                correctionsTable

                HStack {
                    Spacer()
                    Button("Forget All…") { showForgetAllConfirm = true }
                        .buttonStyle(DestructiveOutlineButtonStyle())
                        .disabled(corrections.isEmpty)
                        .opacity(corrections.isEmpty ? 0.5 : 1)
                }
                .padding(.top, 14)
            }
        }
        .onAppear { Task { await refresh() } }
        .onChange(of: learningEnabled) { _, enabled in
            context.settings.learningEnabled = enabled
        }
        .confirmationDialog(
            "Forget all learned corrections?",
            isPresented: $showForgetAllConfirm, titleVisibility: .visible
        ) {
            Button("Forget All", role: .destructive) {
                Task {
                    await context.correctionStore.removeAll()
                    await refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var correctionsTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("HEARD").frame(maxWidth: .infinity, alignment: .leading)
                Text("CORRECTED TO").frame(maxWidth: .infinity, alignment: .leading)
                Text("USES").frame(width: 100, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(Theme.secondaryText)
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            .background(Theme.card)

            if corrections.isEmpty {
                Text("No learned corrections yet. Edit a dictation in History and its word fixes land here.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(corrections.sorted { $0.count > $1.count }, id: \.wrong) { correction in
                    VStack(spacing: 0) {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                        HStack {
                            Text(correction.wrong)
                                .strikethrough()
                                .foregroundStyle(Theme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(correction.right)
                                .fontWeight(.semibold)
                                .foregroundStyle(Theme.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(correction.count)")
                                .foregroundStyle(Theme.secondaryText)
                                .frame(width: 100, alignment: .trailing)
                        }
                        .font(.system(size: 13))
                        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                        .contextMenu {
                            Button("Forget This Correction", role: .destructive) {
                                Task {
                                    await context.correctionStore.remove(wrong: correction.wrong)
                                    await refresh()
                                }
                            }
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }

    private func refresh() async {
        corrections = await context.correctionStore.all()
        learningEnabled = context.settings.learningEnabled
    }
}
