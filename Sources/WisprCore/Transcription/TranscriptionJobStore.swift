import Foundation

public extension Notification.Name {
    /// Posted whenever a transcription job is created, updated, or deleted,
    /// so an open Transcribe pane refreshes. Mirrors `.wisprMeetingsDidChange`.
    static let wisprTranscriptionsDidChange =
        Notification.Name("wisprTranscriptionsDidChange")
}

/// Persists transcription jobs as a single JSON file. Fail-open in the same
/// way as `MeetingStore` and `HistoryStore`: every I/O error is logged via
/// `WisprLog` and swallowed, because a Transcribe failure must never break
/// dictation.
public actor TranscriptionJobStore {
    private let directoryURL: URL
    private var cache: [TranscriptionJob]?

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    /// ~/Library/Application Support/Wispr/
    public static func defaultStore() -> TranscriptionJobStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Wispr")
        return TranscriptionJobStore(directoryURL: base)
    }

    private var fileURL: URL {
        directoryURL.appendingPathComponent("transcriptions.json")
    }

    /// All jobs, newest first.
    public func all() -> [TranscriptionJob] {
        loaded().sorted { $0.createdAt > $1.createdAt }
    }

    public func job(id: UUID) -> TranscriptionJob? {
        loaded().first { $0.id == id }
    }

    public func upsert(_ job: TranscriptionJob) {
        var jobs = loaded()
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.append(job)
        }
        persist(jobs)
        notifyChanged()
    }

    /// Read-modify-write against the CURRENT row, atomically: `loaded()`,
    /// `mutate`, and `persist` run with no suspension point between them.
    ///
    /// Every concurrent writer must come through here rather than pairing
    /// `job(id:)` with `upsert(_:)`. That pair spans an actor hop, and a
    /// two-hour transcription holds its snapshot for the whole run — a
    /// rename or a generated output landing in between would be erased when
    /// it finished, with no error and no undo.
    ///
    /// Returns nil when the job no longer exists, so an edit racing a delete
    /// is dropped rather than resurrecting the row the user just deleted.
    @discardableResult
    public func update(id: UUID,
                       _ mutate: @Sendable (inout TranscriptionJob) -> Void)
        -> TranscriptionJob? {
        var jobs = loaded()
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return nil }
        mutate(&jobs[index])
        let updated = jobs[index]
        persist(jobs)
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

    private func notifyChanged() {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .wisprTranscriptionsDidChange, object: nil)
        }
    }

    private func loaded() -> [TranscriptionJob] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL) else {
            cache = []
            return []
        }
        do {
            let decoded = try JSONDecoder().decode([TranscriptionJob].self, from: data)
            cache = decoded
            return decoded
        } catch {
            WisprLog.log("transcription store: decode FAILED: \(error)")
            cache = []
            return []
        }
    }

    private func persist(_ jobs: [TranscriptionJob]) {
        cache = jobs
        do {
            if !FileManager.default.fileExists(atPath: directoryURL.path) {
                try FileManager.default.createDirectory(
                    at: directoryURL, withIntermediateDirectories: true)
            }
            let data = try JSONEncoder().encode(jobs)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            WisprLog.log("transcription store: persist FAILED: \(error)")
            // Invalidate rather than emptying: `loaded()` short-circuits on a
            // non-nil cache, so `cache = []` would report no jobs for the rest
            // of the actor's life AND make the next successful write overwrite
            // the still-valid file with that empty list.
            cache = nil
        }
    }
}
