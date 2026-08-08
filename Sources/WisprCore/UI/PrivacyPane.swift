import SwiftUI

/// The body of "Delete Everything", lifted out of the button closure so the
/// one guarantee that matters — that no store the app writes survives it —
/// is testable. A SwiftUI alert action is not.
///
/// Every store the app persists user content to must be listed here, and
/// every one listed here must appear in `PRIVACY.md`'s file inventory. A
/// store added to the app and not to this function is a promise the Privacy
/// pane breaks silently.
enum DeleteAllData {
    /// Returns false when meetings refused (one is recording or stopping)
    /// and nothing at all was deleted.
    ///
    /// Meetings are checked-and-deleted FIRST and everything else is gated on
    /// that succeeding, so a refusal leaves the user with everything intact
    /// rather than a silent partial wipe — see the alert's own comment.
    static func run(meetings: any MeetingsCoordinating,
                    history: HistoryStore,
                    corrections: CorrectionStore,
                    archive: AudioArchiveStore,
                    transcriptions: TranscriptionJobStore) async -> Bool {
        guard await meetings.deleteAllMeetings() else { return false }
        await history.clear()
        await corrections.removeAll()
        await archive.deleteAll()
        // Transcriptions hold the most sensitive content the app stores —
        // full transcripts of arbitrary uploaded audio, plus every summary
        // and report generated from them. A button labelled "Delete
        // Everything" that leaves them on disk is the one failure this pane
        // cannot have.
        await transcriptions.deleteAll()
        return true
    }
}

struct PrivacyPane: View {
    let context: MainWindowContext

    @State private var historyEnabled: Bool
    @State private var retainAudio: Bool
    @State private var showDeleteConfirm = false
    @State private var retentionGB: Int
    @State private var retentionDays: Int
    @State private var autoDetect: Bool
    @State private var meetingBytes: Int64 = 0
    @State private var showDeleteMeetingsConfirm = false

    private static let retentionGBOptions = [1, 2, 5, 10, 25]
    private static let retentionDaysOptions = [30, 60, 90, 180, 365]

    /// Seeds every persisted toggle/picker from `context.settings` here, via
    /// `State(initialValue:)`, instead of the previous shape: literal
    /// defaults above (`retentionGB = 5`, etc.) plus an `.onAppear` that
    /// overwrote them with the real values. A review found that shape was
    /// destructive: a `@State` literal default almost never matches what's
    /// actually persisted, so the very first `.onChange` fired by
    /// `.onAppear`'s OWN assignment ran a real side effect. For
    /// `retentionGB`/`retentionDays` that side effect was
    /// `MeetingAudioStore.enforceRetention` — not a no-op — so merely
    /// *opening this pane* re-ran eviction against whatever was already
    /// persisted, every single time. Seeding here means `.onAppear` below
    /// only ever does the one thing that genuinely can't happen at `init`
    /// time — the async `meetingBytes` fetch — so no hydration-triggered
    /// `.onChange` fires at all.
    init(context: MainWindowContext) {
        self.context = context
        _historyEnabled = State(initialValue: context.settings.historyEnabled)
        _retainAudio = State(initialValue: context.settings.retainAudio)
        _retentionGB = State(initialValue: Self.nearestOption(
            context.settings.meetingRetentionGB, in: Self.retentionGBOptions))
        _retentionDays = State(initialValue: Self.nearestOption(
            context.settings.meetingRetentionDays, in: Self.retentionDaysOptions))
        _autoDetect = State(initialValue: context.settings.meetingAutoDetect)
    }

    /// Snaps a persisted value to the closest picker option.
    /// `SettingsStore.meetingRetentionGB`/`meetingRetentionDays` clamp to a
    /// much wider range (1...100 GB, 1...3650 days) than these five discrete
    /// choices, so a persisted value need not land exactly on one of them.
    /// `Picker` has no notion of "closest" on its own — a `selection` that
    /// matches no `.tag` renders with nothing visibly selected — so this
    /// picks the nearest tick instead of leaving the control blank.
    ///
    /// N10 (round 2): kept internal (not `private`) specifically so
    /// `PrivacyPaneTests` can exercise this directly — it's pure, needs no
    /// SwiftUI host, and had no coverage at all. Deliberately NOT paired
    /// with a write-back of the coerced value into `SettingsStore`: the only
    /// writer of `meetingRetentionGB`/`meetingRetentionDays` in the running
    /// app is this same picker, restricted to exactly these five options, so
    /// a persisted value landing off-list is unreachable through any in-app
    /// action — it can only happen from an out-of-band `UserDefaults` edit
    /// or a value written by a future/older build with different options.
    /// For that narrow case, silently rewriting the user's stored setting
    /// the moment they open Settings — before they have touched anything —
    /// felt like a worse surprise than a display that's snapped-but-labeled
    /// consistently; the honest fix for that edge (widening `Picker`'s
    /// options to include an off-list persisted value verbatim) needs the
    /// options lists to stop being `static let` and become instance state
    /// derived from `context`, which is a larger, riskier change than this
    /// round's other fixes. Flagging this here rather than silently doing
    /// nothing about it.
    static func nearestOption(_ value: Int, in options: [Int]) -> Int {
        options.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
    }

    var body: some View {
        PaneScaffold(title: "Privacy") {
            VStack(alignment: .leading, spacing: 0) {
                heroCard
                    .padding(.bottom, 20)

                factRow("Audio recordings stored",
                        "Dictation: only if you opt in · Meetings: kept until the limits below")
                factRow("Transcripts stored", "On this Mac only")
                factRow("Network access",
                        "Optional update check · model downloads")

                SettingsRow(title: "Keep dictation history",
                            caption: "Turn off to transcribe without saving anything") {
                    ThemeToggle(isOn: $historyEnabled)
                }

                SettingsRow(title: "Keep audio with history",
                            caption: "Stores each dictation's audio on this Mac (last 100, WAV) so History can replay and re-transcribe it. Turning this off deletes stored audio.") {
                    ThemeToggle(isOn: $retainAudio)
                }

                SettingsRow(title: "Meeting audio on disk",
                            caption: "Recorded meetings are stored on this Mac as compressed audio so you can replay and reprocess them.") {
                    Text(ByteCountFormatter.string(fromByteCount: meetingBytes,
                                                   countStyle: .file))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }

                SettingsRow(title: "Keep at most",
                            caption: "Oldest meeting audio is deleted first once the limit is reached.") {
                    Picker("", selection: $retentionGB) {
                        ForEach(Self.retentionGBOptions, id: \.self) { Text("\($0) GB").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }

                SettingsRow(title: "Delete meeting audio after",
                            caption: "Transcripts and summaries are kept; only the audio is removed.") {
                    Picker("", selection: $retentionDays) {
                        ForEach(Self.retentionDaysOptions, id: \.self) { Text("\($0) days").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }

                SettingsRow(title: "Detect calls automatically",
                            caption: "Notices when a call starts in Zoom, Teams, FaceTime, Slack, Webex, or Discord and reminds you that you can record it — calls in a browser tab aren't detected. Never starts recording on its own.") {
                    ThemeToggle(isOn: $autoDetect)
                }

                HStack {
                    Spacer()
                    Button("Delete All Meetings…") { showDeleteMeetingsConfirm = true }
                        .buttonStyle(DestructiveOutlineButtonStyle())
                }
                .padding(.vertical, 10)

                HStack {
                    Spacer()
                    Button("Delete All Data…") { showDeleteConfirm = true }
                        .buttonStyle(DestructiveOutlineButtonStyle())
                }
                .padding(.vertical, 16)
            }
        }
        .onAppear {
            // Hydration lives in `init` now (see its doc comment) — this is
            // deliberately the ONLY thing left here: the one piece of state
            // that genuinely cannot be resolved synchronously at init time.
            Task { meetingBytes = await context.meetingAudioStore.totalBytes() }
        }
        .onChange(of: historyEnabled) { _, enabled in
            context.settings.historyEnabled = enabled
        }
        .onChange(of: retainAudio) { _, enabled in
            context.settings.retainAudio = enabled
            if !enabled {
                Task { await context.audioArchive.deleteAll() }
            }
        }
        .onChange(of: retentionGB) { _, value in
            context.settings.meetingRetentionGB = value
            Task {
                await context.meetingsCoordinator.enforceRetention(
                    maxBytes: context.settings.meetingRetentionBytes,
                    maxAgeDays: context.settings.meetingRetentionDays)
                meetingBytes = await context.meetingAudioStore.totalBytes()
            }
        }
        .onChange(of: retentionDays) { _, value in
            context.settings.meetingRetentionDays = value
            Task {
                await context.meetingsCoordinator.enforceRetention(
                    maxBytes: context.settings.meetingRetentionBytes,
                    maxAgeDays: context.settings.meetingRetentionDays)
                meetingBytes = await context.meetingAudioStore.totalBytes()
            }
        }
        .onChange(of: autoDetect) { _, value in
            context.settings.meetingAutoDetect = value
            context.actions.onMeetingAutoDetectToggle(value)
        }
        .alert("Delete all meetings?", isPresented: $showDeleteMeetingsConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All Meetings", role: .destructive) {
                Task {
                    // Routed through the coordinator, not `meetingStore`/
                    // `meetingAudioStore` directly: it refuses outright (pill
                    // feedback) while any meeting is actively recording,
                    // being set up, or being stopped, and drains in-flight
                    // pipeline runs before wiping the store — the same
                    // resurrection-race guard `deleteMeeting` already applies
                    // to a single meeting. It also posts
                    // `.wisprMeetingsDidChange` itself. Return value ignored
                    // here (unlike "Delete All Data…" below) — this button
                    // has nothing else queued after it to gate.
                    _ = await context.meetingsCoordinator.deleteAllMeetings()
                    meetingBytes = await context.meetingAudioStore.totalBytes()
                }
            }
        } message: {
            Text("Permanently deletes every meeting recording, transcript, and summary. "
                 + "This cannot be undone.")
        }
        .alert("Delete all data?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Everything", role: .destructive) {
                Task {
                    // N6 (round 2): meetings are checked-and-deleted FIRST,
                    // and everything else is gated on that succeeding. A
                    // review found the previous order — history, then
                    // corrections, then the audio archive, THEN meetings
                    // last — meant a busy-meeting refusal left the user with
                    // history/corrections/archive already irreversibly gone,
                    // meetings surviving, and no feedback beyond the generic
                    // pill about what had and hadn't happened, for an alert
                    // that promised to delete everything. Checking meetings
                    // first and aborting the WHOLE operation on refusal means
                    // either everything this alert promised is deleted, or
                    // nothing is — never a silent partial.
                    guard await DeleteAllData.run(
                        meetings: context.meetingsCoordinator,
                        history: context.historyStore,
                        corrections: context.correctionStore,
                        archive: context.audioArchive,
                        transcriptions: context.transcriptionStore) else { return }
                    NotificationCenter.default.post(name: .wisprHistoryDidChange, object: nil)
                }
            }
        } message: {
            Text("Permanently deletes all dictation history, learned corrections, meetings, and file transcriptions. This cannot be undone.")
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Local by design.")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.gold)
            Text("Audio is transcribed on-device — your voice and text never leave this Mac. Dictation audio is discarded immediately by default; meeting audio is kept on this Mac until the limits below remove it. The only network calls Wispr Free ever makes are one-time model downloads and an optional daily update check, both of which you control. See PRIVACY.md for the full accounting.")
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
