import SwiftUI

/// The Meetings tab: record controls, the meeting list, and the selected
/// meeting's detail. All behaviour lives in `MeetingsViewModel`; this is the
/// projection.
struct MeetingsPane: View {
    let context: MainWindowContext

    @StateObject private var model: MeetingsViewModel
    @State private var confirmDeleteID: UUID?

    init(context: MainWindowContext) {
        self.context = context
        _model = StateObject(wrappedValue: MeetingsViewModel(
            store: context.meetingStore, coordinator: context.meetingsCoordinator,
            audioStore: context.meetingAudioStore))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let banner = model.banner {
                bannerView(banner)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if model.meetings.isEmpty {
                emptyState
            } else {
                HSplitView {
                    meetingList
                        .frame(minWidth: 260, idealWidth: 320)
                    MeetingDetailView(model: model, context: context)
                        .frame(minWidth: 420)
                }
            }
        }
        .background(Color.white)
        .onAppear {
            context.meetingsCoordinator.register(model: model)
            Task { await model.load() }
        }
        // No .onReceive(.wisprMeetingsDidChange) here: MeetingsViewModel
        // subscribes to that notification itself and reloads, since staying
        // current with out-of-band store mutations is behaviour, not
        // presentation — see its `changeObserver`.
        .alert("Delete this meeting?", isPresented: Binding(
            get: { confirmDeleteID != nil },
            set: { if !$0 { confirmDeleteID = nil } })) {
            Button("Cancel", role: .cancel) { confirmDeleteID = nil }
            Button("Delete", role: .destructive) {
                if let id = confirmDeleteID {
                    Task { await model.delete(id: id) }
                }
                confirmDeleteID = nil
            }
        } message: {
            Text("Permanently deletes the recording, transcript, and summary. "
                 + "This cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Meetings")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if let progress = model.progress, progress.stage != .done {
                HStack(spacing: 8) {
                    ProgressView(value: progress.fraction)
                        .frame(width: 120)
                    Text(progress.stage.label)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            recordButton
        }
        .padding(EdgeInsets(top: 18, leading: 24, bottom: 14, trailing: 24))
    }

    private var subtitle: String {
        if model.isRecording {
            return "Recording · \(MeetingsViewModel.elapsedLabel(model.elapsedSeconds))"
        }
        return "Recorded and summarised entirely on this Mac"
    }

    private var recordButton: some View {
        Button(model.isRecording ? "Stop Recording" : "Record Meeting") {
            Task {
                if model.isRecording {
                    await model.stopRecording()
                } else {
                    await model.startRecording()
                }
            }
        }
        .buttonStyle(SecondaryButtonStyle())
    }

    private func bannerView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if model.permissionMissing {
                Button("Open Settings") {
                    SystemAudioSource.openScreenRecordingSettings()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            Button("Dismiss") { model.dismissBanner() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(EdgeInsets(top: 10, leading: 24, bottom: 10, trailing: 24))
        .background(Theme.paleNavy)
    }

    // MARK: - List

    private var meetingList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(model.meetings) { meeting in
                    Button {
                        model.select(meeting.id)
                    } label: {
                        row(meeting)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        // The live recording's row offers Delete too, but
                        // `AppController.deleteMeeting` refuses it (its
                        // recorder/timer are still capturing into the files
                        // this would delete) — disabled here instead of
                        // just letting the confirm sheet appear and then
                        // silently fail to remove the row.
                        Button("Delete…") { confirmDeleteID = meeting.id }
                            .disabled(meeting.status == .recording)
                    }
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
            }
        }
    }

    private func row(_ meeting: Meeting) -> some View {
        let selected = model.selection == meeting.id
        return VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(MeetingsViewModel.statusLabel(meeting.status))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor(meeting.status))
                Text("·").foregroundStyle(Theme.secondaryText)
                Text(MeetingsViewModel.elapsedLabel(meeting.durationSeconds))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.card : Color.clear)
        .contentShape(Rectangle())
    }

    /// A `.partial` or `.failed` meeting must read as different from a
    /// complete one in the list, not just once it's opened — the list is
    /// the more-seen of the two views, so this can't only live in the
    /// detail view's chip. Mirrors `MeetingDetailView.statusColor`.
    private func statusColor(_ status: MeetingStatus) -> Color {
        switch status {
        case .failed: return Theme.destructive
        case .partial: return Theme.darkGold
        default: return Theme.secondaryText
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            BrandIcon(size: 44)
            Text("No meetings yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Press Record Meeting when a call starts. Wispr captures your "
                 + "mic and the other participants, then writes a summary — all "
                 + "on this Mac.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
