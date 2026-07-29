import Foundation

/// A single learned wrong→right word correction.
public struct Correction: Codable, Equatable, Sendable {
    /// Lowercased — this is the store's key (see `CorrectionStore`).
    public let wrong: String
    public var right: String
    public var count: Int
    public var lastUsed: Date

    public init(wrong: String, right: String, count: Int, lastUsed: Date) {
        self.wrong = wrong
        self.right = right
        self.count = count
        self.lastUsed = lastUsed
    }
}

/// Persistent store of learned wrong→right corrections, keyed by
/// `wrong.lowercased()`.
///
/// Follows `HistoryStore`'s patterns: fail-open (every I/O failure is
/// logged via `WisprLog` and swallowed — corrections are a convenience
/// feature that must never break dictation), lazily-loaded in-memory cache,
/// atomic whole-file rewrite via a temp file + `replaceItemAt`, and a
/// 0600/backup-excluded file on first write.
///
/// Capped at 200 entries: once full, recording a new correction evicts the
/// entry with the oldest `lastUsed` first (LRU).
public actor CorrectionStore {
    private static let capacity = 200

    private let fileURL: URL
    private var cache: [String: Correction]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Default store used by the app: ~/Library/Application Support/Wispr/corrections.json
    public static func defaultStore() -> CorrectionStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Wispr")
        return CorrectionStore(fileURL: base.appendingPathComponent("corrections.json"))
    }

    public func all() async -> [Correction] {
        loadIfNeeded()
        return Array((cache ?? [:]).values)
    }

    /// Records (or updates) a correction under `wrong.lowercased()`. A
    /// second call for the same key overwrites `right` and increments
    /// `count`; a brand-new key starts at `count == 1`. Evicts the
    /// least-recently-used entry if this push would exceed `capacity`.
    public func record(wrong: String, right: String) async {
        loadIfNeeded()
        var current = cache ?? [:]
        let key = wrong.lowercased()

        if var existing = current[key] {
            existing.right = right
            existing.count += 1
            existing.lastUsed = Date()
            current[key] = existing
        } else {
            current[key] = Correction(wrong: key, right: right, count: 1, lastUsed: Date())
        }

        if current.count > Self.capacity, let oldestKey = current.values.min(by: { $0.lastUsed < $1.lastUsed })?.wrong {
            current.removeValue(forKey: oldestKey)
        }

        cache = current
        persist(current)
    }

    public func remove(wrong: String) async {
        loadIfNeeded()
        guard var current = cache else { return }
        current.removeValue(forKey: wrong.lowercased())
        cache = current
        persist(current)
    }

    public func removeAll() async {
        cache = [:]
        persist([:])
    }

    /// Single-word pairs only (a multi-word `wrong` or `right` can't be
    /// applied deterministically or usefully hinted to the cleanup model),
    /// sorted by `count` descending.
    public func topPairs(limit: Int) async -> [(wrong: String, right: String)] {
        loadIfNeeded()
        let entries = (cache ?? [:]).values
            .filter { !$0.wrong.contains(where: \.isWhitespace) && !$0.right.contains(where: \.isWhitespace) }
            .sorted { $0.count > $1.count }
        return entries.prefix(max(limit, 0)).map { (wrong: $0.wrong, right: $0.right) }
    }

    // MARK: - Loading

    private func loadIfNeeded() {
        guard cache == nil else { return }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            cache = [:]
            return
        }
        guard let decoded = try? JSONDecoder().decode([Correction].self, from: data) else {
            WisprLog.log("corrections: failed to decode store, starting empty")
            cache = [:]
            return
        }
        // `uniqueKeysWithValues:` traps on a duplicate `wrong` key, which a
        // hand-edited or corrupted file could contain. Keep the entry with
        // the higher count on a collision (tie-break: later lastUsed).
        cache = Dictionary(decoded.map { ($0.wrong, $0) }, uniquingKeysWith: { existing, incoming in
            if existing.count != incoming.count {
                return existing.count > incoming.count ? existing : incoming
            }
            return existing.lastUsed > incoming.lastUsed ? existing : incoming
        })
    }

    // MARK: - Writing

    /// Rewrites the whole file atomically via a temp file + `replaceItemAt`,
    /// creating it (0600, backup-excluded) on first write. Fail-open: any
    /// error is logged and swallowed.
    private func persist(_ entries: [String: Correction]) {
        guard let data = try? JSONEncoder().encode(Array(entries.values)) else {
            WisprLog.log("corrections: failed to encode store, dropping write")
            return
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
            WisprLog.log("corrections: persist FAILED: \(error)")
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
}
