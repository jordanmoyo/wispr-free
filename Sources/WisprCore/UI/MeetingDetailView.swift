import AVFoundation
import AppKit
import SwiftUI

/// The right-hand side of the Meetings pane: notes, summary, action items,
/// decisions, speaker names, and the transcript, plus export and playback.
struct MeetingDetailView: View {
    @ObservedObject var model: MeetingsViewModel
    let context: MainWindowContext

    @State private var notesDraft = ""
    @State private var titleDraft = ""
    @State private var speakerDrafts: [String: String] = [:]
    @State private var player: AVAudioPlayer?
    /// The URL currently playing, if any — lets the mic/system buttons show
    /// "Stop" only for the track that's actually sounding, the same idiom
    /// `HistoryPane.togglePlay` uses for its single play/stop pill.
    @State private var playingURL: URL?
    @State private var enhancing = false
    @State private var confirmDelete = false
    @State private var confirmUseEnhanced = false

    var body: some View {
        if let meeting = model.selectedMeeting {
            content(meeting)
                // .id() forces onAppear to refire on every selection change,
                // which is what re-seeds the drafts below — switching
                // selection must not carry a half-typed note, title edit, or
                // speaker rename into another meeting.
                .id(meeting.id)
                .onAppear { seedDrafts(meeting) }
                .task(id: meeting.id) {
                    // Playback is view-owned presentation state: stop it here
                    // rather than leaving the previous meeting's audio
                    // sounding under the newly-selected meeting's transcript.
                    // Resolving the URLs themselves is the view model's job
                    // (`MeetingsViewModel.loadAudioURLs`) — it owns the
                    // stale-result guard against a fast switch landing
                    // mid-lookup, since that needs to be independently
                    // testable.
                    stopPlayback()
                    await model.loadAudioURLs(for: meeting.id)
                }
        } else {
            Text("Select a meeting")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ meeting: Meeting) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    titleBlock(meeting)
                    if meeting.status == .partial { partialNotice }
                    if meeting.status == .failed { failedNotice }
                    notesBlock(meeting)
                    if !meeting.summary.isEmpty { summaryBlock(meeting) }
                    if !meeting.actionItems.isEmpty {
                        listBlock("Action items", meeting.actionItems)
                    }
                    if !meeting.decisions.isEmpty {
                        listBlock("Decisions", meeting.decisions)
                    }
                    if !MeetingFormatting.speakerIDs(in: meeting).isEmpty {
                        speakerBlock(meeting)
                    }
                    if !meeting.segments.isEmpty { transcriptBlock(meeting) }
                }
                .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            footer(meeting)
        }
        .alert("Delete this meeting?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await model.delete(id: meeting.id) }
            }
        } message: {
            Text("Permanently deletes the recording, transcript, and summary. "
                 + "This cannot be undone.")
        }
    }

    // MARK: - Blocks

    private func titleBlock(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Meeting title", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.text)
                .onSubmit {
                    Task { await model.renameMeeting(meeting.id, to: titleDraft) }
                }
            HStack(spacing: 6) {
                Text(MeetingsViewModel.statusLabel(meeting.status))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor(meeting.status))
                Text("·").foregroundStyle(Theme.secondaryText)
                Text(MeetingFormatting.timestamp(meeting.durationSeconds))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Text("·").foregroundStyle(Theme.secondaryText)
                Text(meeting.startedAt, style: .date)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func notesBlock(_ meeting: Meeting) -> some View {
        // While the meeting is still recording this button only saves —
        // `MeetingsViewModel.saveNotes` deliberately skips the LLM tidy-up
        // for a live meeting so no pipeline run is registered for its id,
        // which is what would otherwise make the pane's Stop button wait out
        // a full generation (see `saveNotes`' doc comment). The title says so
        // rather than promising a tidy-up that isn't going to happen.
        let liveMeeting = meeting.status == .recording
        let idleTitle = liveMeeting ? "Save my notes" : "Tidy up my notes"
        let busyTitle = liveMeeting ? "Saving…" : "Tidying up…"
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Your notes")
            TextEditor(text: $notesDraft)
                .font(.system(size: 12))
                .frame(minHeight: 90)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            HStack {
                Button(enhancing ? busyTitle : idleTitle) {
                    enhancing = true
                    Task {
                        await model.saveNotes(notesDraft, for: meeting.id)
                        enhancing = false
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(enhancing
                          || notesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                              .isEmpty)
                Spacer()
            }
            if !meeting.enhancedNotes.isEmpty, meeting.enhancedNotes != notesDraft {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tidied version")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                    Text(meeting.enhancedNotes)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Use this") {
                        // The editor has no autosave, so anything typed here
                        // and not yet submitted only exists in `notesDraft`.
                        // Replacing it outright on a stray click would
                        // destroy that silently, with no undo — confirm
                        // first whenever the draft has diverged from what's
                        // actually persisted.
                        if MeetingFormatting.hasUnsavedNotes(draft: notesDraft,
                                                             savedUserNotes: meeting.userNotes) {
                            confirmUseEnhanced = true
                        } else {
                            useEnhancedNotes(meeting)
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paleNavy))
            }
        }
        .alert("Replace your notes with the tidied version?",
               isPresented: $confirmUseEnhanced) {
            Button("Cancel", role: .cancel) {}
            Button("Replace", role: .destructive) { useEnhancedNotes(meeting) }
        } message: {
            Text("Your notes have unsaved changes. Using the tidied version will "
                 + "replace them, and this cannot be undone.")
        }
    }

    private func summaryBlock(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Summary")
            Text(meeting.summary)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func listBlock(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(title)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(Theme.darkGold)
                    Text(item)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func speakerBlock(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Speakers")
            ForEach(MeetingFormatting.speakerIDs(in: meeting), id: \.self) { id in
                HStack(spacing: 8) {
                    Text("Speaker \(id)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 90, alignment: .leading)
                    TextField("Name", text: Binding(
                        get: { speakerDrafts[id] ?? meeting.speakerNames[id] ?? "" },
                        set: { speakerDrafts[id] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .onSubmit {
                            Task {
                                await model.rename(speaker: id,
                                                   to: speakerDrafts[id] ?? "",
                                                   in: meeting.id)
                            }
                        }
                }
            }
        }
    }

    private func transcriptBlock(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Transcript")
            ForEach(meeting.segments) { segment in
                HStack(alignment: .top, spacing: 8) {
                    Text(MeetingFormatting.timestamp(segment.start))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 56, alignment: .leading)
                    Text(meeting.displayName(for: segment.speaker))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.navy)
                        .frame(width: 84, alignment: .leading)
                    Text(segment.text)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var partialNotice: some View {
        Text("This transcript is incomplete — part of the recording couldn't be "
             + "processed. Press Reprocess to try the rest again.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.darkGold)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var failedNotice: some View {
        Text("Wispr couldn't transcribe this recording. The audio is still on "
             + "this Mac — press Reprocess to try again.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.destructive)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func statusColor(_ status: MeetingStatus) -> Color {
        switch status {
        case .failed: return Theme.destructive
        case .partial: return Theme.darkGold
        default: return Theme.secondaryText
        }
    }

    private func footer(_ meeting: Meeting) -> some View {
        HStack(spacing: 8) {
            Button("Copy as Markdown") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(MeetingFormatting.markdown(meeting),
                                               forType: .string)
            }
            .buttonStyle(SecondaryButtonStyle())

            if let url = model.audioURLs.mic {
                Button(playingURL == url ? "Stop" : "Play your audio") { toggle(url) }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if let url = model.audioURLs.system {
                Button(playingURL == url ? "Stop" : "Play others") { toggle(url) }
                    .buttonStyle(SecondaryButtonStyle())
            }

            Spacer()

            Button("Reprocess") {
                Task { await model.reprocess(id: meeting.id) }
            }
            .buttonStyle(SecondaryButtonStyle())
            // Gated on audio existing the same way the Play buttons above
            // are (`model.audioURLs.mic`/`.system`): a review found
            // Reprocess stayed enabled even after both tracks were gone
            // (evicted by retention, or never captured), which used to let
            // it run the pipeline's now-fixed "no audio" branch and, before
            // that fix, silently wipe a meeting's transcript/summary.
            .disabled(meeting.status == .recording || meeting.status == .processing
                      || (model.audioURLs.mic == nil && model.audioURLs.system == nil))

            Button("Delete…") { confirmDelete = true }
                .buttonStyle(DestructiveOutlineButtonStyle())
                // Mirrors MeetingsPane's list-row context menu: deleting the
                // actively-recording meeting is refused (with a banner) at
                // the AppController level regardless, but disabling this
                // here means the confirm sheet never even appears for the
                // common case. Keyed on stored status, same as the list —
                // see AppController.bootstrap's startup reconciliation for
                // why a crash-orphaned `.recording` row doesn't stay stuck
                // showing this disabled forever.
                .disabled(meeting.status == .recording)
        }
        .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(Theme.secondaryText)
    }

    private func seedDrafts(_ meeting: Meeting) {
        titleDraft = meeting.title
        notesDraft = meeting.userNotes
        speakerDrafts = meeting.speakerNames
    }

    private func useEnhancedNotes(_ meeting: Meeting) {
        notesDraft = meeting.enhancedNotes
        Task { await model.saveNotes(notesDraft, for: meeting.id) }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        playingURL = nil
    }

    /// Mirrors `HistoryPane.togglePlay`: `try?` around construction, only
    /// claim "playing" once `play()` actually returns true, and — since two
    /// tracks (mic/system) can be selected here, unlike HistoryPane's single
    /// row — explicitly stop whatever was playing before starting the new
    /// one rather than relying on the old player being deallocated.
    private func toggle(_ url: URL) {
        if playingURL == url {
            stopPlayback()
            return
        }
        stopPlayback()
        guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else {
            WisprLog.log("meeting detail: playback FAILED for \(url.lastPathComponent)")
            return
        }
        guard newPlayer.play() else {
            WisprLog.log("meeting detail: playback failed to start for "
                         + "\(url.lastPathComponent)")
            return
        }
        player = newPlayer
        playingURL = url
    }
}
