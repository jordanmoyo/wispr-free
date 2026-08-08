import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Transcribe tab: pick an audio file already on this Mac, transcribe it
/// here, and generate documents from the result. All behaviour lives in
/// `TranscriptionViewModel`; this is the projection — the `MeetingsPane`
/// idiom, right down to the library/detail split.
struct TranscribePane: View {
    let context: MainWindowContext

    @StateObject private var model: TranscriptionViewModel
    @State private var confirmDeleteID: UUID?
    @State private var titleDraft = ""
    @State private var dropTargeted = false

    init(context: MainWindowContext) {
        self.context = context
        // Both pickers open on the user's own dictation choices. Someone who
        // deliberately runs small models because the large ones thrash their
        // machine must not find this pane pre-set to the large ones — the
        // registry defaults only look right by coincidence, because today
        // they equal `models[0]` in both registries.
        _model = StateObject(wrappedValue: TranscriptionViewModel(
            store: context.transcriptionStore,
            coordinator: context.transcriptionCoordinator,
            defaultTranscriptionModelID: context.settings.selectedModelID,
            defaultEnhancementModelID: context.settings.cleanupModelID))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let banner = model.banner {
                bannerView(banner)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HSplitView {
                library
                    .frame(minWidth: 260, idealWidth: 320)
                detail
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.white)
        .task { await model.load() }
        // Registering here, not in `.task`, mirrors MeetingsPane: the
        // coordinator holds the model weakly and pushes progress into it, so
        // it must be handed over as soon as the pane exists.
        .onAppear { context.transcriptionCoordinator.register(model: model) }
        .alert("Delete this transcription?", isPresented: Binding(
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
            // Deliberately explicit that the source file is untouched: the
            // job stores a REFERENCE to it (`TranscriptionJob.sourcePath`),
            // and a delete that read as "deletes my recording" would stop
            // people cleaning up their library.
            Text("Permanently deletes the transcript and everything generated "
                 + "from it. Your audio file is not touched. This cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Transcribe")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text("Transcribed and summarised entirely on this Mac")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button("New Transcription") {
                model.select(nil)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.isRunning)
        }
        .padding(EdgeInsets(top: 18, leading: 24, bottom: 14, trailing: 24))
    }

    private func bannerView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss") { model.dismissBanner() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(EdgeInsets(top: 10, leading: 24, bottom: 10, trailing: 24))
        .background(Theme.paleNavy)
    }

    // MARK: - Library

    @ViewBuilder
    private var library: some View {
        if model.jobs.isEmpty {
            emptyLibrary
        } else {
            List {
                ForEach(model.jobs) { job in
                    libraryRow(job)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                confirmDeleteID = job.id
                            }
                        }
                        .contextMenu {
                            Button("Delete…") { confirmDeleteID = job.id }
                        }
                }
            }
            .listStyle(.plain)
        }
    }

    private func libraryRow(_ job: TranscriptionJob) -> some View {
        let selected = model.selection == job.id
        return Button {
            model.select(job.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(TranscriptionViewModel.statusLabel(job.status))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusColor(job.status))
                    Text("·").foregroundStyle(Theme.secondaryText)
                    Text(TranscriptionViewModel.durationLabel(job.durationSeconds))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                    Text("·").foregroundStyle(Theme.secondaryText)
                    Text(job.createdAt, style: .relative)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.card : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyLibrary: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No transcriptions yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Add a file on the right to start one.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
    }

    /// Mirrors `MeetingsPane.statusColor`: a partial or failed job must read
    /// as different from a finished one in the list, not only once opened.
    private func statusColor(_ status: TranscriptionJobStatus) -> Color {
        switch status {
        case .failed: return Theme.destructive
        case .partial: return Theme.darkGold
        default: return Theme.secondaryText
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        // A document generation pushes progress into the same property a
        // transcription run does, so `model.generating != nil` must be
        // checked FIRST. Otherwise pressing Summary on a finished job hides
        // the transcript and every document already generated behind a
        // full-screen bar with a Cancel button that cannot cancel a
        // generation. Generation progress belongs inline, next to the button
        // that started it — which `generateBar` already shows.
        if let progress = model.progress, model.generating == nil {
            progressState(progress)
        } else if let job = model.selectedJob {
            if job.status == .processing {
                processingNotice
            } else {
                resultState(job)
            }
        } else {
            setupState
        }
    }

    // MARK: - Setup state

    private var setupState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                dropZone
                if model.pendingURL != nil {
                    pendingFileBlock
                }
                optionsBlock
                startRow
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            BrandIcon(size: 34)
            Text("Drop an audio file here")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("WAV, M4A, MP3, AIFF or CAF, up to 2 hours. The file stays "
                 + "where it is — Wispr reads it, never copies or uploads it.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Choose File…") { chooseFile() }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(dropTargeted ? Theme.paleNavy : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(dropTargeted ? Theme.navy : Theme.border,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
    }

    private var pendingFileBlock: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.pendingTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(pendingSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button("Remove") { model.clearSelection() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isRunning)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paleNavy))
    }

    private var pendingSubtitle: String {
        var parts = [TranscriptionViewModel.durationLabel(model.pendingDurationSeconds)]
        if let url = model.pendingURL, let size = Self.fileSizeLabel(url) {
            parts.append(size)
        }
        return parts.joined(separator: " · ")
    }

    private var optionsBlock: some View {
        VStack(spacing: 0) {
            SettingsRow(title: "Transcription model") {
                Picker("", selection: $model.transcriptionModelID) {
                    ForEach(ModelRegistry.models) { whisperModel in
                        Text(Self.modelMenuLabel(
                            displayName: whisperModel.displayName,
                            approxSizeMB: whisperModel.approxSizeMB,
                            installed: context.modelStore.isInstalled(whisperModel)))
                            .tag(whisperModel.id)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }
            SettingsRow(title: "Document model",
                        caption: "Writes the summary, report and chapters") {
                Picker("", selection: $model.enhancementModelID) {
                    ForEach(CleanupModelRegistry.models) { cleanupModel in
                        Text(Self.modelMenuLabel(
                            displayName: cleanupModel.displayName,
                            approxSizeMB: cleanupModel.approxSizeMB,
                            installed: context.modelStore.isInstalled(cleanupModel)))
                            .tag(cleanupModel.id)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }
            SettingsRow(title: "Language") {
                Picker("", selection: $model.language) {
                    Text("Auto-detect").tag(String?.none)
                    ForEach(TranscriptionOptions.languages, id: \.code) { language in
                        Text(language.name).tag(String?.some(language.code))
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }
            speakerRow
        }
    }

    private var speakerRow: some View {
        SettingsRow(title: "Identify speakers",
                    caption: model.diarizationUnavailableReason,
                    showDivider: false) {
            ThemeToggle(isOn: $model.diarize)
                .disabled(!model.diarizationAvailable)
                .opacity(model.diarizationAvailable ? 1 : 0.5)
        }
    }

    private var startRow: some View {
        HStack(spacing: 8) {
            Button("Start Transcription") {
                Task { await model.start() }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.pendingURL == nil || model.isRunning)
            Spacer()
        }
    }

    // MARK: - Progress state

    private func progressState(_ progress: TranscriptionProgress) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Text(model.selectedJob?.title ?? model.pendingTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            ProgressView(value: progress.fraction)
                .frame(width: 280)
            Text(model.cancelling
                 ? "Cancelling… finishing the part already in progress."
                 : "\(Int((progress.fraction * 100).rounded()))% · \(progress.stage.label)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            Button("Cancel") { Task { await model.cancel() } }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.cancelling)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var processingNotice: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("Transcribing…")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("This transcription is still running. Its transcript appears "
                 + "here as soon as it finishes.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Result state

    private func resultState(_ job: TranscriptionJob) -> some View {
        VStack(spacing: 0) {
            generateBar(job)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    resultHeader(job)
                    if !job.failureNote.isEmpty { failureNotice(job) }
                    documents(job)
                    if !job.segments.isEmpty { transcriptBlock(job) }
                }
                .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
            }
        }
        // Re-seeds the title draft on every selection change, so a half-typed
        // rename never carries into another job — the `MeetingDetailView` idiom.
        .id(job.id)
        .onAppear { titleDraft = job.title }
    }

    private func generateBar(_ job: TranscriptionJob) -> some View {
        HStack(spacing: 8) {
            ForEach(TranscriptOutputKind.allCases, id: \.self) { kind in
                Button {
                    Task { await model.generate(kind) }
                } label: {
                    HStack(spacing: 6) {
                        if model.generating == kind {
                            ProgressView().controlSize(.small)
                        }
                        Text(kind.label)
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                // Every generation reduces from the same transcript through
                // the same LLM, so a second one while the first runs would
                // contend for one loaded model — one at a time, like the
                // transcription itself.
                .disabled(model.generating != nil || job.segments.isEmpty)
            }
            Spacer()
        }
        .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
    }

    private func resultHeader(_ job: TranscriptionJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.text)
                .onSubmit {
                    Task { await model.rename(job.id, to: titleDraft) }
                }
            HStack(spacing: 6) {
                Text(TranscriptionViewModel.statusLabel(job.status))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor(job.status))
                Text("·").foregroundStyle(Theme.secondaryText)
                Text(TranscriptionViewModel.durationLabel(job.durationSeconds))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Text("·").foregroundStyle(Theme.secondaryText)
                Text(job.createdAt, style: .date)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func failureNotice(_ job: TranscriptionJob) -> some View {
        Text(job.failureNote)
            .font(.system(size: 12))
            .foregroundStyle(job.status == .failed ? Theme.destructive : Theme.darkGold)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func documents(_ job: TranscriptionJob) -> some View {
        if !job.cleanTranscript.isEmpty {
            documentBlock("Clean transcript", job.cleanTranscript)
        }
        if !job.summary.isEmpty {
            documentBlock("Summary", job.summary)
        }
        if !job.actionItems.isEmpty {
            listBlock("Action items", job.actionItems)
        }
        if !job.decisions.isEmpty {
            listBlock("Decisions", job.decisions)
        }
        if !job.report.isEmpty {
            documentBlock("Report", job.report)
        }
        if !job.chapters.isEmpty {
            chaptersBlock(job.chapters)
        }
    }

    private func documentBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle(title)
                Spacer()
                copyButton(text)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func listBlock(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle(title)
                Spacer()
                copyButton(items.map { "- \($0)" }.joined(separator: "\n"))
            }
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

    private func chaptersBlock(_ chapters: [TranscriptChapter]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("Chapters")
                Spacer()
                copyButton(chapters
                    .map { "[\(MeetingFormatting.timestamp($0.start))] \($0.title)" }
                    .joined(separator: "\n"))
            }
            ForEach(chapters) { chapter in
                HStack(alignment: .top, spacing: 8) {
                    Text(MeetingFormatting.timestamp(chapter.start))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 62, alignment: .leading)
                    Text(chapter.title)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func transcriptBlock(_ job: TranscriptionJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("Transcript")
                Spacer()
                copyButton(Self.transcriptText(job))
            }
            ForEach(job.segments) { segment in
                HStack(alignment: .top, spacing: 8) {
                    Text("[\(MeetingFormatting.timestamp(segment.start))]")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 74, alignment: .leading)
                    Text(job.displayName(for: segment.speaker))
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

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(Theme.secondaryText)
    }

    private func copyButton(_ text: String) -> some View {
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        .buttonStyle(SecondaryButtonStyle())
    }

    private static func transcriptText(_ job: TranscriptionJob) -> String {
        job.segments.map { segment in
            "[\(MeetingFormatting.timestamp(segment.start))] "
                + "\(job.displayName(for: segment.speaker)): \(segment.text)"
        }.joined(separator: "\n")
    }

    /// "Large v3 Turbo  (↓ 1.6 GB)" — matches the menu-bar submenus, so the
    /// same model reads the same way everywhere.
    static func modelMenuLabel(displayName: String, approxSizeMB: Int,
                               installed: Bool) -> String {
        guard !installed else { return displayName }
        let sizeGB = String(format: "%.1f", Double(approxSizeMB) / 1000)
        return "\(displayName)  (↓ \(sizeGB) GB)"
    }

    private static func fileSizeLabel(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    // MARK: - File selection

    private func chooseFile() {
        let panel = NSOpenPanel()
        // The same `.audio` restriction `AppController.importAudioFile` uses:
        // `AudioFileReader` opens files with `AVAudioFile`, so offering video
        // containers would let the user pick something that can only fail.
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adopt(url)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let target = model
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in await Self.adopt(url, into: target) }
        }
        return true
    }

    private func adopt(_ url: URL) {
        Task { await Self.adopt(url, into: model) }
    }

    /// Records the picked file on the view model.
    ///
    /// `diarize` is turned back ON whenever the gate allows it: speaker
    /// labels are the main reason to run an interview through this pane, and
    /// the approved setup design shows the toggle checked. It stays OFF when
    /// the gate refuses — `selectFile` forces that, and this must not undo it,
    /// which is why it reads `diarizationAvailable` rather than assigning true.
    @MainActor
    private static func adopt(_ url: URL, into target: TranscriptionViewModel) async {
        let seconds = await durationSeconds(of: url)
        target.selectFile(url: url, durationSeconds: seconds)
        target.diarize = target.diarizationAvailable
    }

    /// Duration for the setup screen only. A file macOS cannot read reports
    /// 0, which the diarization gate already treats as unavailable, and
    /// `AudioFileReader` re-checks the file for real when the run starts —
    /// this never decides whether a transcription may proceed.
    private static func durationSeconds(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? max(0, seconds) : 0
    }
}
