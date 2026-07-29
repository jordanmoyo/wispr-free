import Foundation

/// Free-text search over `HistoryEntry` history, matching either the raw
/// transcript or the delivered (cleaned) text.
public enum HistorySearch {
    /// Filters `entries` by `query`, matching `rawText` or `cleanedText`.
    /// Matching is case- and diacritic-insensitive (both haystack and
    /// needle are folded via `.caseInsensitive, .diacriticInsensitive`
    /// before a plain `contains` check). An empty or whitespace-only query
    /// returns all entries unfiltered.
    public static func filter(_ entries: [HistoryEntry], query: String) -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        let needle = fold(trimmed)
        return entries.filter { entry in
            fold(entry.rawText).contains(needle) || fold(entry.cleanedText).contains(needle)
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
