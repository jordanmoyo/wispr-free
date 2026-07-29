import AVFoundation
import Foundation

/// Opt-in on-disk archive of raw dictation audio, keyed by the dictation's
/// `UUID`, so History can replay or re-transcribe a past dictation.
///
/// Mirrors `VocabularyStore`'s patterns: fail-open (every I/O or AVFoundation
/// failure is logged via `WisprLog` and swallowed — this is a convenience
/// feature that must never break dictation or history), a 0600/backup-excluded
/// file per entry, and a directory created lazily on first write.
///
/// Capped at `maxFiles` entries: once full, saving a new file evicts the
/// file with the oldest modification date.
public actor AudioArchiveStore {
    public static let maxFiles = 100

    private let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    /// Default store used by the app: ~/Library/Application Support/Wispr/audio/
    public static func defaultStore() -> AudioArchiveStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Wispr")
        return AudioArchiveStore(directoryURL: base.appendingPathComponent("audio"))
    }

    /// Writes `samples` (16 kHz mono Float32) to `<id>.wav`, then evicts the
    /// oldest file(s) if the archive now exceeds `maxFiles`. Fail-open: any
    /// error is logged and swallowed — dictation must never be blocked by
    /// archive failures.
    public func save(samples: [Float], id: UUID) async {
        // AVAudioFrameCount is UInt32 — an oversized array would trap in the
        // conversion below, violating fail-open. Real callers cap well under
        // this (AudioFileImporter.maxSamples), but the store defends itself.
        guard !samples.isEmpty, samples.count <= Int(UInt32.max) else {
            WisprLog.log("audio archive: refusing save of \(samples.count) samples")
            return
        }
        let fileURL = self.fileURL(for: id)
        do {
            if !FileManager.default.fileExists(atPath: directoryURL.path) {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            }
            try Self.writeWAV(samples: samples, to: fileURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            WisprLog.log("audio archive: save FAILED: \(error)")
            return
        }
        evictOldestIfNeeded()
    }

    /// Returns the on-disk URL for `id`, or nil if no file exists for it.
    public func url(for id: UUID) async -> URL? {
        let fileURL = self.fileURL(for: id)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    public func delete(id: UUID) async {
        let fileURL = self.fileURL(for: id)
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            WisprLog.log("audio archive: delete FAILED: \(error)")
        }
    }

    public func deleteAll() async {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: directoryURL, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "wav" {
                try? FileManager.default.removeItem(at: file)
            }
        } catch {
            WisprLog.log("audio archive: deleteAll FAILED: \(error)")
        }
    }

    /// Removes wavs whose UUID stem is not in `ids`.
    public func prune(keeping ids: Set<UUID>) async {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: directoryURL, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "wav" {
                let stem = file.deletingPathExtension().lastPathComponent
                if let stemID = UUID(uuidString: stem), ids.contains(stemID) { continue }
                try? FileManager.default.removeItem(at: file)
            }
        } catch {
            WisprLog.log("audio archive: prune FAILED: \(error)")
        }
    }

    // MARK: - Private

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).wav")
    }

    /// Lists `*.wav` files in the directory; if there are more than
    /// `maxFiles`, deletes the oldest (by modification date) until exactly
    /// `maxFiles` remain. Fail-open: any error is logged and swallowed.
    private func evictOldestIfNeeded() {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "wav" }
            guard files.count > Self.maxFiles else { return }

            let sorted = try files.sorted { lhs, rhs in
                let lhsDate = try lhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate ?? .distantPast
                let rhsDate = try rhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate ?? .distantPast
                return lhsDate < rhsDate
            }

            let excess = sorted.count - Self.maxFiles
            for file in sorted.prefix(excess) {
                try? FileManager.default.removeItem(at: file)
            }
        } catch {
            WisprLog.log("audio archive: eviction FAILED: \(error)")
        }
    }

    /// Writes `samples` as a 16 kHz mono 16-bit PCM WAV file at `url`.
    /// Scoped in its own function so the `AVAudioFile` deinits (releasing
    /// its file handle) before the caller chmods the file.
    private static func writeWAV(samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw WisprError.audioFileUnreadable("unable to allocate output buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData {
            channelData[0].update(from: samples, count: samples.count)
        }
        try file.write(from: buffer)
    }
}
