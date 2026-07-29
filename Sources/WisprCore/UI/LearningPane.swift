import SwiftUI

struct LearningPane: View {
    let context: MainWindowContext

    @State private var corrections: [Correction] = []
    @State private var learningEnabled = true
    @State private var showForgetAllConfirm = false
    @State private var vocabulary: [String] = []
    @State private var newTerm = ""

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

                dictionarySection
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

    private var dictionarySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("DICTIONARY")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, 24)
                .padding(.bottom, 4)
            Text("Words Wispr should spell exactly — names, brands, jargon.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .padding(.bottom, 10)

            HStack(spacing: 8) {
                TextField("Add a word…", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit { addTerm() }
                Button("Add") { addTerm() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.bottom, 12)

            if vocabulary.isEmpty {
                Text("No dictionary words yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(vocabulary, id: \.self) { term in
                        termChip(term)
                    }
                }
            }
        }
    }

    private func termChip(_ term: String) -> some View {
        HStack(spacing: 6) {
            Text(term)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
            Button {
                Task {
                    await context.vocabularyStore.remove(term)
                    await refresh()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 8))
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().stroke(Theme.hairline))
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        newTerm = ""
        Task {
            await context.vocabularyStore.add(term)
            await refresh()
        }
    }

    private func refresh() async {
        corrections = await context.correctionStore.all()
        learningEnabled = context.settings.learningEnabled
        vocabulary = await context.vocabularyStore.all()
    }
}

/// Minimal left-to-right wrapping layout for the dictionary chips —
/// SwiftUI ships no flow container, and a fixed-column grid would stretch
/// variable-width chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(in: bounds.width, subviews: subviews)
        for (subview, position) in zip(subviews, arrangement.positions) {
            subview.place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified)
        }
    }

    private func arrange(in width: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
