import SwiftUI
import AppKit
import AVFoundation

/// The History tab of the unified main window: stat cards, search,
/// master/detail list, per-entry editing (which feeds correction learning),
/// and a Clear History footer. Ported from the pre-0.3 standalone History
/// window; the editing state discipline (`.id()`-scoped detail, pinned diff
/// baseline, cancellable save task) is unchanged.
struct HistoryPane: View {
    let context: MainWindowContext

    @State private var entries: [HistoryEntry] = []
    @State private var query = ""
    @State private var selection: UUID?
    @State private var showClearConfirm = false
    @State private var alsoForgetCorrections = false
    /// Archived-audio URLs for currently loaded entries, resolved
    /// asynchronously since `AudioArchiveStore` is an actor; a Play/
    /// Re-transcribe button only appears once an entry's id is a key here.
    @State private var audioURLs: [UUID: URL] = [:]
    @State private var player: AVAudioPlayer?
    @State private var playingID: UUID?

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
            VStack(spacing: 0) {
                statsGrid
                searchField
                    .padding(.vertical, 14)
            }
            .padding(EdgeInsets(top: 18, leading: 24, bottom: 0, trailing: 24))

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HSplitView {
                entryList
                    .frame(minWidth: 300, idealWidth: 420)
                detail
                    .frame(minWidth: 380)
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)
            footer
        }
        .background(Color.white)
        .onAppear {
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wisprHistoryDidChange)) { _ in
            Task { await refresh() }
        }
        .task(id: entries) {
            await loadAudioURLs()
        }
    }

    // MARK: - Header

    private var statsGrid: some View {
        HStack(spacing: 12) {
            statCard("\(summary.totalDictations)", "Dictations")
            statCard("\(summary.totalWords)", "Words")
            statCard("\(summary.wordsThisWeek)", "This week")
            statCard(String(format: "%.1f", summary.wordsPerMinute), "Words/min")
        }
    }

    private func statCard(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
    }

    private var searchField: some View {
        TextField("Search history…", text: $query)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0xfa / 255, green: 0xfa / 255, blue: 0xfa / 255)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    // MARK: - Entry list

    private var entryList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if filteredEntries.isEmpty {
                    Text(entries.isEmpty
                         ? "No dictations yet. Hold your push-to-talk key and speak."
                         : "No dictations match your search.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.top, 24)
                } else {
                    ForEach(filteredEntries) { entry in
                        EntryCard(
                            entry: entry, selected: entry.id == selection,
                            audioURL: audioURLs[entry.id], isPlaying: playingID == entry.id,
                            onPlay: { togglePlay(entry) },
                            onRetranscribe: { context.retranscribe(entry) })
                            .onTapGesture { selection = entry.id }
                            .contextMenu {
                                Button("Copy") { copy(entry) }
                                Button("Delete", role: .destructive) { delete(entry) }
                            }
                    }
                }
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.hairline).frame(width: 1)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let selectedEntry {
            // `.id` forces a fresh detail view (and fresh @State) per entry —
            // see HistoryDetail's doc comment.
            HistoryDetail(
                entry: selectedEntry,
                onSave: { [entryID = selectedEntry.id] original, edited in
                    await saveEdit(entryID: entryID, original: original, edited: edited)
                })
                .id(selectedEntry.id)
        } else {
            Text("Select a dictation to view details")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Clear History…") {
                alsoForgetCorrections = false
                showClearConfirm = true
            }
            .buttonStyle(DestructiveOutlineButtonStyle())
        }
        .padding(EdgeInsets(top: 10, leading: 24, bottom: 10, trailing: 24))
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
        entries = await context.historyStore.entries()
        if let selection, !entries.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
        if selection == nil {
            selection = entries.first?.id
        }
    }

    private func copy(_ entry: HistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.cleanedText, forType: .string)
    }

    private func delete(_ entry: HistoryEntry) {
        Task {
            await context.historyStore.delete(id: entry.id)
            // HistoryStore stays audio-agnostic — the pane is the call site
            // that knows a deleted entry's archived audio (if any) should
            // go with it.
            await context.audioArchive.delete(id: entry.id)
            if selection == entry.id { selection = nil }
            await refresh()
        }
    }

    /// Resolves archived-audio URLs for the currently loaded entries so
    /// Play/Re-transcribe buttons only render where audio actually exists.
    private func loadAudioURLs() async {
        var urls: [UUID: URL] = [:]
        for entry in entries {
            if let url = await context.audioArchive.url(for: entry.id) {
                urls[entry.id] = url
            }
        }
        audioURLs = urls
    }

    /// No delegate: the pill icon just resets to "play" on the next
    /// interaction with a different (or the same, after it finishes) row —
    /// acceptable per the design for this release.
    private func togglePlay(_ entry: HistoryEntry) {
        guard let url = audioURLs[entry.id] else { return }
        if playingID == entry.id {
            player?.stop()
            player = nil
            playingID = nil
        } else {
            let newPlayer = try? AVAudioPlayer(contentsOf: url)
            // Only claim "playing" state if a player was actually
            // constructed and started — a vanished file must not leave a
            // stale stop icon on a row that's silently doing nothing.
            guard let newPlayer, newPlayer.play() else { return }
            player = newPlayer
            playingID = entry.id
        }
    }

    /// `original` is the baseline pinned by `HistoryDetail` when editing
    /// began — not a live re-read of `entry.cleanedText`, which can change
    /// out from under an in-progress edit. See the pre-0.3 HistoryView for
    /// the full rationale.
    private func saveEdit(entryID: UUID, original: String, edited: String) async {
        let diffs = WordDiff.corrections(from: original, to: edited)
        if context.settings.learningEnabled {
            for pair in diffs {
                await context.correctionStore.record(wrong: pair.wrong, right: pair.right)
            }
        }
        guard var updated = entries.first(where: { $0.id == entryID }) else { return }
        updated.cleanedText = edited
        await context.historyStore.update(updated)
        await refresh()
    }

    private func clearHistory(alsoForgetCorrections: Bool) async {
        await context.historyStore.clear()
        await context.audioArchive.deleteAll()
        if alsoForgetCorrections {
            await context.correctionStore.removeAll()
        }
        selection = nil
        await refresh()
    }
}

// MARK: - Entry card

private struct EntryCard: View {
    let entry: HistoryEntry
    let selected: Bool
    /// Non-nil only when this entry's audio is still archived on disk —
    /// gates whether the Play/Re-transcribe buttons render at all.
    let audioURL: URL?
    let isPlaying: Bool
    let onPlay: () -> Void
    let onRetranscribe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.date, style: .relative)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Theme.lightLavender : Theme.secondaryText)
                Spacer()
                if audioURL != nil {
                    Button(action: onPlay) {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selected ? Theme.gold : Theme.secondaryText)
                    Button(action: onRetranscribe) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selected ? Theme.gold : Theme.secondaryText)
                }
                Text(entry.appName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? Theme.gold : Theme.secondaryText)
            }
            Text(entry.cleanedText)
                .font(.system(size: 13))
                .lineSpacing(3)
                .lineLimit(3)
                .foregroundStyle(selected ? .white : Theme.text)
                .padding(.vertical, 7)
            Text("\(entry.wordCount) words")
                .font(.system(size: 11, weight: .semibold))
                .padding(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                .background(Capsule().fill(selected
                    ? Theme.gold.opacity(0.2)
                    : Color(red: 0xe6 / 255, green: 0xe6 / 255, blue: 0xea / 255)))
                .foregroundStyle(selected
                    ? Theme.gold
                    : Color(red: 0x6a / 255, green: 0x6a / 255, blue: 0x72 / 255))
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(selected ? Theme.navy : Theme.card))
        .contentShape(Rectangle())
    }
}

// MARK: - Detail view

/// Recreated per entry via `.id()` in the parent so every entry gets fresh
/// @State (edit text, pinned baseline, in-flight confirmation task).
private struct HistoryDetail: View {
    let entry: HistoryEntry
    let onSave: (_ original: String, _ edited: String) async -> Void

    @State private var editedText = ""
    /// Diff baseline pinned when editing began; re-pinned after each save so
    /// repeat saves don't re-learn (and double-count) the same corrections.
    @State private var originalText = ""
    @State private var confirmationText: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 20) {
                    transcriptColumn("Raw transcript", entry.rawText, color: Color(red: 0x55 / 255, green: 0x55 / 255, blue: 0x5c / 255))
                    transcriptColumn("Delivered text", entry.cleanedText, color: Theme.text)
                }

                editSection
                learningSection
            }
            .padding(EdgeInsets(top: 18, leading: 24, bottom: 18, trailing: 24))
        }
        .onAppear {
            editedText = entry.cleanedText
            originalText = entry.cleanedText
        }
        .onDisappear { saveTask?.cancel() }
    }

    private func transcriptColumn(_ title: String, _ text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.text)
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(4)
                    .foregroundStyle(color)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
        }
        .frame(maxWidth: .infinity)
    }

    private var editSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Edit delivered text")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.text)
            TextEditor(text: $editedText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 120)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            HStack(spacing: 10) {
                Button("Save") { save() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(saveEnabled ? .white : Color(red: 0xa0 / 255, green: 0xa0 / 255, blue: 0xa8 / 255))
                    .padding(EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18))
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(saveEnabled ? Theme.navy : Theme.sidebar))
                    .disabled(!saveEnabled)
                Button(copied ? "Copied" : "Copy") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(editedText, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                .buttonStyle(SecondaryButtonStyle())
                if let confirmationText {
                    Text(confirmationText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    private var saveEnabled: Bool {
        editedText != originalText && !editedText.isEmpty
    }

    private func save() {
        let original = originalText
        let edited = editedText
        saveTask?.cancel()
        saveTask = Task {
            await onSave(original, edited)
            // Re-pin the diff baseline: a second edit-and-save must diff
            // against what was just saved, not the pre-first-save text.
            originalText = edited
            guard !Task.isCancelled else { return }
            let count = WordDiff.corrections(from: original, to: edited).count
            confirmationText = count > 0
                ? "Learned \(count) correction\(count == 1 ? "" : "s")" : "Saved"
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            confirmationText = nil
        }
    }

    private var learningSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text("Learning")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.top, 10)
            if let applied = entry.appliedCorrections, !applied.isEmpty {
                Text("Learned corrections applied: \(applied.joined(separator: ", "))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                Text("No learned corrections were applied to this dictation.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}
