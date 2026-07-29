import Foundation

/// A single dictation captured for the history view.
public struct HistoryEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let date: Date
    public let appName: String
    public let appBundleID: String
    public let rawText: String
    public var cleanedText: String
    public let durationSeconds: Double
    public let wordCount: Int
    public let delivered: Bool
    public var appliedCorrections: [String]?

    public init(
        id: UUID,
        date: Date,
        appName: String,
        appBundleID: String,
        rawText: String,
        cleanedText: String,
        durationSeconds: Double,
        wordCount: Int,
        delivered: Bool,
        appliedCorrections: [String]?
    ) {
        self.id = id
        self.date = date
        self.appName = appName
        self.appBundleID = appBundleID
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.durationSeconds = durationSeconds
        self.wordCount = wordCount
        self.delivered = delivered
        self.appliedCorrections = appliedCorrections
    }
}

extension HistoryEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, date, appName, appBundleID, rawText, cleanedText
        case durationSeconds, wordCount, delivered, appliedCorrections
    }

    /// `date` is encoded as whole milliseconds since 1970 (an `Int64`)
    /// rather than relying on `JSONEncoder`'s `Double`-based date
    /// strategies: a `Date`'s `timeIntervalSince1970` combined with JSON's
    /// text-based number representation is not guaranteed to round-trip
    /// bit-exactly for a value with this many significant digits, which
    /// made `HistoryEntry` equality intermittently fail across an
    /// encode/decode cycle. An integer round-trips exactly, and millisecond
    /// precision is far more than a dictation timestamp needs.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let millis = try container.decode(Int64.self, forKey: .date)
        date = Date(timeIntervalSince1970: Double(millis) / 1000)
        appName = try container.decode(String.self, forKey: .appName)
        appBundleID = try container.decode(String.self, forKey: .appBundleID)
        rawText = try container.decode(String.self, forKey: .rawText)
        cleanedText = try container.decode(String.self, forKey: .cleanedText)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        wordCount = try container.decode(Int.self, forKey: .wordCount)
        delivered = try container.decode(Bool.self, forKey: .delivered)
        appliedCorrections = try container.decodeIfPresent([String].self, forKey: .appliedCorrections)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()), forKey: .date)
        try container.encode(appName, forKey: .appName)
        try container.encode(appBundleID, forKey: .appBundleID)
        try container.encode(rawText, forKey: .rawText)
        try container.encode(cleanedText, forKey: .cleanedText)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(wordCount, forKey: .wordCount)
        try container.encode(delivered, forKey: .delivered)
        try container.encodeIfPresent(appliedCorrections, forKey: .appliedCorrections)
    }
}

public extension Notification.Name {
    static let wisprHistoryDidChange = Notification.Name("wisprHistoryDidChange")
}

/// JSONL-backed store of dictation history: one `HistoryEntry` per line.
///
/// Fail-open by design: every I/O failure is logged via `WisprLog` and
/// swallowed rather than thrown, since history is a convenience feature that
/// must never break dictation. Entries are loaded lazily on first access and
/// cached in memory for the lifetime of the actor; every mutation rewrites
/// the on-disk file (append is the only exception, which appends a single
/// line) and posts `.wisprHistoryDidChange` on the main queue.
public actor HistoryStore {
    /// Above this in-memory count, `append` compacts down to the newest 1000.
    private static let compactionThreshold = 1200
    private static let compactionTarget = 1000

    private let fileURL: URL
    private var cache: [HistoryEntry]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Default store used by the app: ~/Library/Application Support/Wispr/history.jsonl
    public static func defaultStore() -> HistoryStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Wispr")
        return HistoryStore(fileURL: base.appendingPathComponent("history.jsonl"))
    }

    /// All entries, newest first.
    public func entries() async -> [HistoryEntry] {
        loadIfNeeded()
        return cache ?? []
    }

    public func append(_ entry: HistoryEntry) async {
        loadIfNeeded()
        var current = cache ?? []
        current.insert(entry, at: 0)

        if current.count > Self.compactionThreshold {
            current = Array(current.prefix(Self.compactionTarget))
            cache = current
            rewriteFile(with: current)
        } else {
            cache = current
            appendLine(for: entry)
        }
        notifyChanged()
    }

    public func update(_ entry: HistoryEntry) async {
        loadIfNeeded()
        guard var current = cache, let index = current.firstIndex(where: { $0.id == entry.id }) else {
            return
        }
        current[index] = entry
        cache = current
        rewriteFile(with: current)
        notifyChanged()
    }

    public func delete(id: UUID) async {
        loadIfNeeded()
        guard var current = cache else { return }
        current.removeAll { $0.id == id }
        cache = current
        rewriteFile(with: current)
        notifyChanged()
    }

    public func clear() async {
        cache = []
        rewriteFile(with: [])
        notifyChanged()
    }

    // MARK: - Loading

    private func loadIfNeeded() {
        guard cache == nil else { return }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            cache = []
            return
        }
        let decoder = JSONDecoder()
        var loaded: [HistoryEntry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty else { continue }
            guard let entry = try? decoder.decode(HistoryEntry.self, from: Data(line)) else {
                WisprLog.log("history: skipping unparseable line")
                continue
            }
            loaded.append(entry)
        }
        // Newest first, regardless of on-disk order.
        cache = loaded.sorted { $0.date > $1.date }
    }

    // MARK: - Writing

    /// Appends a single encoded line to the file, creating it (0600,
    /// backup-excluded) on first write. Fail-open: any error is logged and
    /// swallowed.
    private func appendLine(for entry: HistoryEntry) {
        let encoder = JSONEncoder()
        guard var data = try? encoder.encode(entry) else {
            WisprLog.log("history: failed to encode entry, dropping")
            return
        }
        data.append(UInt8(ascii: "\n"))

        do {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try createFile()
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } catch {
            WisprLog.log("history: append FAILED: \(error)")
        }
    }

    /// Rewrites the whole file atomically via a temp file + `replaceItemAt`.
    /// Used by update/delete/clear/compaction. Fail-open on any error.
    private func rewriteFile(with entries: [HistoryEntry]) {
        let encoder = JSONEncoder()
        var data = Data()
        for entry in entries {
            guard let encoded = try? encoder.encode(entry) else {
                WisprLog.log("history: failed to encode entry during rewrite, dropping")
                continue
            }
            data.append(encoded)
            data.append(UInt8(ascii: "\n"))
        }

        do {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try createFile()
            }
            let tempURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString).tmp")
            try data.write(to: tempURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } catch {
            WisprLog.log("history: rewrite FAILED: \(error)")
        }
    }

    /// Creates the (possibly-missing) parent directory and an empty file
    /// with 0600 permissions, excluded from Time Machine backups.
    private func createFile() throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: fileURL.path, contents: nil,
            attributes: [.posixPermissions: 0o600])
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func notifyChanged() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .wisprHistoryDidChange, object: nil)
        }
    }
}
