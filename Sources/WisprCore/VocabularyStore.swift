import Foundation

/// Persistent store of user-supplied custom-dictionary terms (proper nouns,
/// jargon, product names) that the cleanup model should preserve verbatim.
///
/// Follows `CorrectionStore`'s patterns: fail-open (every I/O failure is
/// logged via `WisprLog` and swallowed — the dictionary is a convenience
/// feature that must never break dictation), lazily-loaded in-memory cache,
/// atomic whole-file rewrite via a temp file + `replaceItemAt`, and a
/// 0600/backup-excluded file on first write.
///
/// Unlike `CorrectionStore`'s dictionary-keyed cache, this caches a `[String]`
/// in insertion order — the dictionary has no wrong→right pairing, just a
/// flat list of terms to preserve, and insertion order is what the user sees
/// when reviewing their own dictionary.
///
/// Capped at 200 entries: once full, adding a new term evicts the
/// first-added (oldest) entry.
public actor VocabularyStore {
    private static let capacity = 200

    private let fileURL: URL
    private var cache: [String]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Default store used by the app: ~/Library/Application Support/Wispr/vocabulary.json
    public static func defaultStore() -> VocabularyStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Wispr")
        return VocabularyStore(fileURL: base.appendingPathComponent("vocabulary.json"))
    }

    public func all() async -> [String] {
        loadIfNeeded()
        return cache ?? []
    }

    /// Normalizes `term` (interior whitespace runs and newlines collapse to
    /// a single space — a term is one line in the cleanup system prompt, so
    /// a pasted newline must not smuggle an instruction-shaped line into
    /// the prompt's data block); skips if the result is empty or already
    /// present (case-insensitive). Evicts the first-added entry if this
    /// push would exceed `capacity`.
    public func add(_ term: String) async {
        loadIfNeeded()
        var current = cache ?? []

        let trimmed = term.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !trimmed.isEmpty else { return }
        guard !current.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }

        current.append(trimmed)
        if current.count > Self.capacity {
            current.removeFirst()
        }

        cache = current
        persist(current)
    }

    public func remove(_ term: String) async {
        loadIfNeeded()
        guard var current = cache else { return }
        current.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
        cache = current
        persist(current)
    }

    public func removeAll() async {
        cache = []
        persist([])
    }

    // MARK: - Loading

    private func loadIfNeeded() {
        guard cache == nil else { return }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            cache = []
            return
        }
        guard let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            WisprLog.log("vocabulary: failed to decode store, starting empty")
            cache = []
            return
        }
        cache = decoded
    }

    // MARK: - Writing

    /// Rewrites the whole file atomically via a temp file + `replaceItemAt`,
    /// creating it (0600, backup-excluded) on first write. Fail-open: any
    /// error is logged and swallowed.
    private func persist(_ entries: [String]) {
        guard let data = try? JSONEncoder().encode(entries) else {
            WisprLog.log("vocabulary: failed to encode store, dropping write")
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
            WisprLog.log("vocabulary: persist FAILED: \(error)")
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
