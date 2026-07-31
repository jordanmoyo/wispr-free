import Foundation

/// Owns `~/Library/Application Support/Wispr/meetings/` — the AAC tracks for
/// each meeting — and enforces retention by total size and age.
///
/// Mirrors `AudioArchiveStore`: fail-open, 0600, backup-excluded. The
/// difference is the eviction policy: meetings are capped by bytes and days
/// rather than by file count, because a meeting is thousands of times larger
/// than a dictation.
public actor MeetingAudioStore: MeetingAudioLocating {
    public static let defaultMaxBytes: Int64 = 5 * 1024 * 1024 * 1024
    public static let defaultMaxAgeDays = 90

    private let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public static func defaultStore() -> MeetingAudioStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Wispr")
        return MeetingAudioStore(directoryURL: base.appendingPathComponent("meetings"))
    }

    /// Destination path for the mic track. Returned whether or not it exists —
    /// the writer needs a path before there is a file.
    public func micURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString)-mic.m4a")
    }

    public func systemURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString)-system.m4a")
    }

    public func existingMicURL(for id: UUID) -> URL? {
        let url = micURL(for: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func existingSystemURL(for id: UUID) -> URL? {
        let url = systemURL(for: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func prepareDirectory() throws {
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(
                at: directoryURL, withIntermediateDirectories: true)
        }
    }

    /// Applies 0600 and backup exclusion to a track file the writer created.
    /// Fail-open: a permissions failure is logged, not thrown.
    public func secure(_ url: URL) {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            var mutable = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutable.setResourceValues(values)
        } catch {
            WisprLog.log("meeting audio: secure FAILED: \(error)")
        }
    }

    public func delete(id: UUID) {
        for url in [micURL(for: id), systemURL(for: id)] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func deleteAll() {
        for url in trackFiles() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func totalBytes() -> Int64 {
        trackFiles().reduce(0) { $0 + size(of: $1) }
    }

    /// Deletes oldest-first until BOTH caps are satisfied: nothing older than
    /// `maxAgeDays`, and total size at or under `maxBytes`.
    ///
    /// `maxAgeDays` is defensively clamped to at least 1 here, not only in
    /// `SettingsStore`'s getter: a zero or negative value pushes `cutoff`
    /// into the future, which makes EVERY file — including one written
    /// moments ago — look "older than the cutoff" and evicts it outright,
    /// discarding audio that was never given a chance to be kept.
    /// `maxBytes` needs no equivalent clamp: `total` is always >= 0 (a sum
    /// of file sizes), so any `maxBytes` <= 0 already evicts every survivor
    /// via the size loop below on its own — there's no distinct "negative"
    /// failure mode for it to guard against, and clamping it would be
    /// untestable dead code pretending to be a protection.
    ///
    /// `excludingMeetingIDs` (round 2, N2/N3): tracks belonging to any of
    /// these ids are never evicted by this sweep, regardless of age or the
    /// size cap — as if they were permanently exempt. `MeetingsCoordinatorImpl`
    /// passes the set of meeting ids with a currently-registered
    /// `MeetingPipeline` run, so a sweep can never delete a file that run
    /// might still be mid-read of. Exemption is a safe fail-open direction:
    /// a busy meeting's audio simply survives one extra sweep past its cap
    /// and gets picked up by the next one once its run clears, rather than
    /// the alternative (cancelling the run to make the sweep safe) which
    /// would make a cap change destructive.
    ///
    /// Their bytes DO still count toward `total`, though (round 3, D2): an
    /// earlier version filtered excluded files out before summing `total`
    /// at all, which let a large excluded file make the sweep UNDER-report
    /// how much space was actually in use — a 10 GB cap, one 9 GB busy
    /// meeting, and 3 GB of idle ones summed to "3 GB, under cap," evicting
    /// nothing while 12 GB sat on disk. Counting an excluded file's bytes
    /// toward `total` while still refusing to ever remove that file keeps
    /// the size cap meaningful — an excluded meeting genuinely eats into
    /// the budget it's exempt from being evicted to satisfy — without
    /// reintroducing the destructive cancel-its-run alternative.
    public func enforceRetention(maxBytes: Int64, maxAgeDays: Int,
                                  excludingMeetingIDs: Set<UUID> = []) {
        let maxAgeDays = max(1, maxAgeDays)

        // Split up front: `excludedBytes` counts toward `total` below (D2)
        // but its files never enter `survivors`, so neither the age cutoff
        // nor the size loop can ever touch them. A file whose name doesn't
        // parse as `<uuid>-mic`/`<uuid>-system` can't be matched against
        // `excludingMeetingIDs` at all — fail open by treating it as
        // eligible (unrecognized isn't the same as protected).
        var excludedBytes: Int64 = 0
        var files: [URL] = []
        for url in trackFiles() {
            if let id = meetingID(for: url), excludingMeetingIDs.contains(id) {
                excludedBytes += size(of: url)
            } else {
                files.append(url)
            }
        }
        guard !files.isEmpty else { return }

        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86_400)
        var survivors: [(url: URL, date: Date, size: Int64)] = []
        for url in files {
            let date = modificationDate(of: url)
            if date < cutoff {
                try? FileManager.default.removeItem(at: url)
            } else {
                survivors.append((url, date, size(of: url)))
            }
        }

        var total = survivors.reduce(excludedBytes) { $0 + $1.size }
        guard total > maxBytes else { return }
        for entry in survivors.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            if total <= maxBytes { break }
        }
    }

    // MARK: - Private

    /// Parses the meeting id a track file belongs to back out of its name
    /// (`<uuid>-mic.m4a` / `<uuid>-system.m4a`, per `micURL(for:)`/
    /// `systemURL(for:)`), for `enforceRetention`'s `excludingMeetingIDs`
    /// filter. `nil` for anything that doesn't match either suffix.
    private func meetingID(for url: URL) -> UUID? {
        let name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix("-mic") {
            return UUID(uuidString: String(name.dropLast(4)))
        }
        if name.hasSuffix("-system") {
            return UUID(uuidString: String(name.dropLast(7)))
        }
        return nil
    }

    private func trackFiles() -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "m4a" }
    }

    private func size(of url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }

    /// Fails open to "now" (not `.distantPast`) when the attributes read
    /// fails. A review found `.distantPast` fails open in the destructive
    /// direction: it makes an unreadable file look maximally ancient, so a
    /// transient I/O error here — unlike `size(of:)`'s safe `0` fallback,
    /// which only ever UNDERcounts — would guarantee eviction of a file we
    /// simply couldn't inspect, rather than defaulting to keeping it.
    private func modificationDate(of url: URL) -> Date {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return Date() }
        return date
    }
}
