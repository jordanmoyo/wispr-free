import Foundation

/// Persists meetings as a single JSON file. Fail-open in the same way as
/// `HistoryStore` and `VocabularyStore`: every I/O error is logged via
/// `WisprLog` and swallowed, because a Meetings failure must never break
/// dictation.
public actor MeetingStore {
    private let directoryURL: URL
    private var cache: [Meeting]?

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    /// ~/Library/Application Support/Wispr/
    public static func defaultStore() -> MeetingStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Wispr")
        return MeetingStore(directoryURL: base)
    }

    private var fileURL: URL { directoryURL.appendingPathComponent("meetings.json") }

    /// All meetings, newest first.
    public func all() -> [Meeting] {
        loaded().sorted { $0.startedAt > $1.startedAt }
    }

    public func meeting(id: UUID) -> Meeting? {
        loaded().first { $0.id == id }
    }

    public func upsert(_ meeting: Meeting) {
        var meetings = loaded()
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.append(meeting)
        }
        persist(meetings)
        notifyChanged()
    }

    /// Read-modify-write against the CURRENT row, atomically: `loaded()`,
    /// `mutate`, and `persist` run with no suspension point between them, so
    /// the row a caller edits is the row on disk at that instant.
    ///
    /// Every concurrent writer must come through here rather than pairing
    /// `meeting(id:)` with `upsert(_:)`. That pair spans an actor hop, and
    /// whichever writer lands last silently discards every field the other
    /// changed in between. `MeetingPipeline.process` held its snapshot across
    /// the whole of transcription, diarization and summarization — minutes —
    /// so notes typed, a meeting renamed, or a speaker relabelled while it
    /// ran were erased when it finished, with no error and no undo.
    ///
    /// Returns the merged row, or nil when the meeting no longer exists. The
    /// nil case is deliberate: an edit racing a delete is dropped rather than
    /// resurrecting the row the user just deleted.
    @discardableResult
    public func update(id: UUID, _ mutate: @Sendable (inout Meeting) -> Void) -> Meeting? {
        var meetings = loaded()
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return nil }
        mutate(&meetings[index])
        let updated = meetings[index]
        persist(meetings)
        notifyChanged()
        return updated
    }

    public func delete(id: UUID) {
        persist(loaded().filter { $0.id != id })
        notifyChanged()
    }

    public func deleteAll() {
        persist([])
        notifyChanged()
    }

    // MARK: - Private

    /// Mirrors `HistoryStore.notifyChanged()`: every mutation posts
    /// `.wisprMeetingsDidChange` on the main queue, so an open Meetings pane
    /// (or anything else observing) refreshes even when the mutation came
    /// from outside it — e.g. a background `MeetingPipeline` run finishing
    /// while the pane is open. Without this, `MeetingsViewModel` only ever
    /// sees its own writes, and a completed or failed meeting can sit on
    /// screen still showing "Processing" indefinitely.
    private func notifyChanged() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .wisprMeetingsDidChange, object: nil)
        }
    }

    private func loaded() -> [Meeting] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL) else {
            cache = []
            return []
        }
        do {
            let decoded = try JSONDecoder().decode([Meeting].self, from: data)
            cache = decoded
            return decoded
        } catch {
            WisprLog.log("meeting store: decode FAILED: \(error)")
            cache = []
            return []
        }
    }

    private func persist(_ meetings: [Meeting]) {
        cache = meetings
        do {
            if !FileManager.default.fileExists(atPath: directoryURL.path) {
                try FileManager.default.createDirectory(
                    at: directoryURL, withIntermediateDirectories: true)
            }
            let data = try JSONEncoder().encode(meetings)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            WisprLog.log("meeting store: persist FAILED: \(error)")
            // Invalidate rather than emptying: `loaded()` short-circuits on a
            // non-nil cache, so `cache = []` would make `all()` report no
            // meetings for the rest of the actor's life AND make the next
            // successful write overwrite the still-valid file with that empty
            // list. Setting nil forces a re-read of the last good on-disk
            // state.
            cache = nil
        }
    }
}
