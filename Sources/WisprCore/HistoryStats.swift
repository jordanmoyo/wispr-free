import Foundation

/// Aggregate analytics computed from dictation history.
public enum HistoryStats {
    public struct Summary: Equatable {
        public let totalDictations: Int
        public let totalWords: Int
        public let wordsThisWeek: Int
        public let wordsPerMinute: Double
    }

    private static let secondsPerWeek: TimeInterval = 7 * 24 * 60 * 60

    /// Summarizes `entries`. `now` is injectable for deterministic tests.
    public static func summarize(_ entries: [HistoryEntry], now: Date = Date()) -> Summary {
        guard !entries.isEmpty else {
            return Summary(totalDictations: 0, totalWords: 0, wordsThisWeek: 0, wordsPerMinute: 0)
        }

        let totalWords = entries.reduce(0) { $0 + $1.wordCount }
        let totalDuration = entries.reduce(0.0) { $0 + $1.durationSeconds }
        let weekAgo = now.addingTimeInterval(-secondsPerWeek)
        let wordsThisWeek = entries
            .filter { $0.date >= weekAgo && $0.date <= now }
            .reduce(0) { $0 + $1.wordCount }

        let wpm: Double
        if totalDuration > 0 {
            let raw = Double(totalWords) / (totalDuration / 60)
            wpm = (raw * 10).rounded() / 10
        } else {
            wpm = 0
        }

        return Summary(
            totalDictations: entries.count,
            totalWords: totalWords,
            wordsThisWeek: wordsThisWeek,
            wordsPerMinute: wpm)
    }
}
