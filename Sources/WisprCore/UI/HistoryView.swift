import SwiftUI
import AppKit

/// The full History window content: stat cards, search, master/detail list,
/// a learned-corrections list, and a "Clear History" footer.
///
/// Kept intentionally split into small subviews (`StatCardsRow`,
/// `HistoryListView`, `HistoryDetailView`, `CorrectionsListView`) rather than
/// one large `body` — the window mixes several independent concerns
/// (analytics, search/list, editing, correction management) that are each
/// easier to read and test in isolation.
struct HistoryView: View {
    let historyStore: HistoryStore
    let correctionStore: CorrectionStore
    let settings: SettingsStore

    @State private var entries: [HistoryEntry] = []
    @State private var corrections: [Correction] = []
    @State private var query: String = ""
    @State private var selection: UUID?
    @State private var showClearConfirm = false
    @State private var alsoForgetCorrections = false

    private var summary: HistoryStats.Summary {
        HistoryStats.summarize(entries)
    }

    private var filteredEntries: [HistoryEntry] {
        HistorySearch.filter(entries, query: query)
    }

    private var selectedEntry: HistoryEntry? {
        guard let selection else { return nil }
        return entries.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            StatCardsRow(summary: summary)
                .padding()

            TextField("Search history…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)

            HSplitView {
                HistoryListView(
                    entries: filteredEntries,
                    selection: $selection,
                    onCopy: copy,
                    onDelete: delete)
                    .frame(minWidth: 260)

                VStack(spacing: 0) {
                    if let selectedEntry {
                        // `.id(selectedEntry.id)` forces SwiftUI to tear down
                        // and recreate HistoryDetailView (and thus its
                        // @State — edited/original text, in-flight save
                        // confirmation) whenever the selected entry changes,
                        // rather than reusing one persistent view identity
                        // across entries. Without this, editing entry A then
                        // selecting entry B within the "Learned N
                        // corrections" 2s window would show A's confirmation
                        // over B's detail pane.
                        HistoryDetailView(
                            entry: selectedEntry,
                            settings: settings,
                            onSave: { [entryID = selectedEntry.id] original, edited in
                                await saveEdit(entryID: entryID, original: original, edited: edited)
                            })
                            .id(selectedEntry.id)
                    } else {
                        Text("Select a dictation to view details")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Divider()
                    CorrectionsListView(
                        corrections: corrections,
                        onDelete: deleteCorrection,
                        onForgetAll: forgetAllCorrections)
                        .frame(height: 180)
                }
                .frame(minWidth: 320)
            }

            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 520)
        .onAppear { Task { await refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .wisprHistoryDidChange)) { _ in
            Task { await refresh() }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Clear History…", role: .destructive) {
                alsoForgetCorrections = false
                showClearConfirm = true
            }
            .padding()
        }
        .alert("Clear all history?", isPresented: $showClearConfirm) {
            Toggle("Also forget learned corrections", isOn: $alsoForgetCorrections)
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) {
                Task { await clearHistory(alsoForgetCorrections: alsoForgetCorrections) }
            }
        } message: {
            Text("This permanently deletes all dictation history. This cannot be undone.")
        }
    }

    // MARK: - Actions

    private func refresh() async {
        entries = await historyStore.entries()
        corrections = await correctionStore.all()
    }

    private func copy(_ entry: HistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.cleanedText, forType: .string)
    }

    private func delete(_ entry: HistoryEntry) {
        Task {
            await historyStore.delete(id: entry.id)
            if selection == entry.id { selection = nil }
            await refresh()
        }
    }

    /// `original` is the baseline pinned by `HistoryDetailView` when editing
    /// began (its own `originalText`, captured once in `onAppear`) — not a
    /// live re-read of `entry.cleanedText` from this view's `entries` state,
    /// which can change out from under an in-progress edit (e.g. a refresh
    /// triggered by another action) and would otherwise diff against the
    /// wrong baseline. The current entry is looked up by id fresh at save
    /// time for its other fields (only `cleanedText` is being replaced).
    private func saveEdit(entryID: UUID, original: String, edited: String) async {
        let diffs = WordDiff.corrections(from: original, to: edited)
        if settings.learningEnabled {
            for pair in diffs {
                await correctionStore.record(wrong: pair.wrong, right: pair.right)
            }
        }
        guard var updated = entries.first(where: { $0.id == entryID }) else { return }
        updated.cleanedText = edited
        await historyStore.update(updated)
        await refresh()
    }

    private func deleteCorrection(_ correction: Correction) {
        Task {
            await correctionStore.remove(wrong: correction.wrong)
            await refresh()
        }
    }

    private func forgetAllCorrections() {
        Task {
            await correctionStore.removeAll()
            await refresh()
        }
    }

    private func clearHistory(alsoForgetCorrections: Bool) async {
        await historyStore.clear()
        if alsoForgetCorrections {
            await correctionStore.removeAll()
        }
        selection = nil
        await refresh()
    }
}

// MARK: - Stat cards

private struct StatCardsRow: View {
    let summary: HistoryStats.Summary

    var body: some View {
        HStack(spacing: 12) {
            StatCard(value: "\(summary.totalDictations)", caption: "Dictations")
            StatCard(value: "\(summary.totalWords)", caption: "Words")
            StatCard(value: "\(summary.wordsThisWeek)", caption: "This week")
            StatCard(value: String(format: "%.1f", summary.wordsPerMinute), caption: "Words/min")
        }
    }
}

private struct StatCard: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }
}

// MARK: - History list

private struct HistoryListView: View {
    let entries: [HistoryEntry]
    @Binding var selection: UUID?
    let onCopy: (HistoryEntry) -> Void
    let onDelete: (HistoryEntry) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(entries) { entry in
                HistoryRow(entry: entry)
                    .tag(entry.id)
                    .contextMenu {
                        Button("Copy") { onCopy(entry) }
                        Button("Delete", role: .destructive) { onDelete(entry) }
                    }
            }
        }
        .listStyle(.inset)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.date, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(entry.appName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(entry.cleanedText)
                .lineLimit(2)
                .font(.body)
            Text("\(entry.wordCount) words")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.quaternary))
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail / edit

private struct HistoryDetailView: View {
    let entry: HistoryEntry
    let settings: SettingsStore
    let onSave: (_ original: String, _ edited: String) async -> Void

    @State private var editedText: String = ""
    /// The delivered text as it stood when editing began for *this* entry
    /// (set once in `onAppear`). Used as the diff baseline instead of
    /// `entry.cleanedText` directly, since the latter can change between
    /// the start of an edit and Save being tapped — see `saveEdit` in the
    /// parent view.
    @State private var originalText: String = ""
    @State private var confirmationText: String?
    /// Handle to the in-flight save/confirmation `Task`, so a teardown
    /// (entry deselected — this view is `.id()`-scoped per entry by the
    /// parent, so a new entry means a fresh instance) can cancel it instead
    /// of leaving it to fire its 2s-later `confirmationText = nil` into a
    /// view nobody's looking at, or worse, into a stale state box.
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading) {
                        Text("Raw transcript").font(.headline)
                        ScrollView {
                            Text(entry.rawText)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 80, maxHeight: 140)
                    }
                    VStack(alignment: .leading) {
                        Text("Delivered text").font(.headline)
                        ScrollView {
                            Text(entry.cleanedText)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 80, maxHeight: 140)
                    }
                }

                if let applied = entry.appliedCorrections, !applied.isEmpty {
                    Text("Learned corrections applied: \(applied.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text("Edit delivered text").font(.headline)
                TextEditor(text: $editedText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100)
                    .border(Color.secondary.opacity(0.3))

                HStack {
                    Button("Save") {
                        let original = originalText
                        let edited = editedText
                        saveTask?.cancel()
                        saveTask = Task {
                            await onSave(original, edited)
                            // Re-pin the diff baseline: a second edit-and-save
                            // in the same session must diff against what was
                            // just saved, not the pre-first-save text —
                            // otherwise the first save's corrections get
                            // re-learned and their counts inflated.
                            originalText = edited
                            guard !Task.isCancelled else { return }
                            confirmationText = confirmationMessage(original: original, edited: edited)
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            guard !Task.isCancelled else { return }
                            confirmationText = nil
                        }
                    }
                    .disabled(editedText == entry.cleanedText || editedText.isEmpty)
                    if let confirmationText {
                        Text(confirmationText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .onAppear {
            editedText = entry.cleanedText
            originalText = entry.cleanedText
        }
        .onDisappear { saveTask?.cancel() }
    }

    private func confirmationMessage(original: String, edited: String) -> String {
        let count = WordDiff.corrections(from: original, to: edited).count
        return count > 0 ? "Learned \(count) correction\(count == 1 ? "" : "s")" : "Saved"
    }
}

// MARK: - Corrections list

private struct CorrectionsListView: View {
    let corrections: [Correction]
    let onDelete: (Correction) -> Void
    let onForgetAll: () -> Void

    @State private var showForgetAllConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Learning").font(.headline)
                Spacer()
                Button("Forget All") { showForgetAllConfirm = true }
                    .disabled(corrections.isEmpty)
                    .font(.caption)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if corrections.isEmpty {
                Text("No learned corrections yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                Spacer()
            } else {
                List {
                    ForEach(corrections.sorted { $0.count > $1.count }, id: \.wrong) { correction in
                        HStack {
                            Text("\(correction.wrong) → \(correction.right)")
                            Spacer()
                            Text("×\(correction.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(role: .destructive) { onDelete(correction) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .confirmationDialog(
            "Forget all learned corrections?", isPresented: $showForgetAllConfirm, titleVisibility: .visible
        ) {
            Button("Forget All", role: .destructive) { onForgetAll() }
            Button("Cancel", role: .cancel) {}
        }
    }
}
