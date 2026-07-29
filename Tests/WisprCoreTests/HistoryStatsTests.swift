import XCTest
@testable import WisprCore

final class HistoryStatsTests: XCTestCase {
    private func makeEntry(
        date: Date,
        wordCount: Int,
        durationSeconds: Double
    ) -> HistoryEntry {
        HistoryEntry(
            id: UUID(),
            date: date,
            appName: "TestApp",
            appBundleID: "com.test.app",
            rawText: "raw",
            cleanedText: "cleaned",
            durationSeconds: durationSeconds,
            wordCount: wordCount,
            delivered: true,
            appliedCorrections: nil)
    }

    func testEmptyEntriesReturnsZeros() {
        let summary = HistoryStats.summarize([], now: Date())
        XCTAssertEqual(summary.totalDictations, 0)
        XCTAssertEqual(summary.totalWords, 0)
        XCTAssertEqual(summary.wordsThisWeek, 0)
        XCTAssertEqual(summary.wordsPerMinute, 0)
    }

    func testTotalsSum() {
        let now = Date()
        let entries = [
            makeEntry(date: now, wordCount: 10, durationSeconds: 60),
            makeEntry(date: now, wordCount: 20, durationSeconds: 60),
        ]
        let summary = HistoryStats.summarize(entries, now: now)
        XCTAssertEqual(summary.totalDictations, 2)
        XCTAssertEqual(summary.totalWords, 30)
    }

    func testWordsThisWeekOnlyCountsEntriesWithinSevenDays() {
        let now = Date()
        let withinWeek = now.addingTimeInterval(-6 * 24 * 60 * 60)
        let overAWeekAgo = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let entries = [
            makeEntry(date: now, wordCount: 10, durationSeconds: 60),
            makeEntry(date: withinWeek, wordCount: 5, durationSeconds: 60),
            makeEntry(date: overAWeekAgo, wordCount: 100, durationSeconds: 60),
        ]
        let summary = HistoryStats.summarize(entries, now: now)
        XCTAssertEqual(summary.totalWords, 115)
        XCTAssertEqual(summary.wordsThisWeek, 15)
    }

    func testWordsPerMinuteRoundedToOneDecimal() {
        let now = Date()
        // 150 words over 60 seconds (1 minute) => 150 wpm.
        let entries = [
            makeEntry(date: now, wordCount: 150, durationSeconds: 60),
        ]
        let summary = HistoryStats.summarize(entries, now: now)
        XCTAssertEqual(summary.wordsPerMinute, 150.0)
    }

    func testWordsPerMinuteRoundingFraction() {
        let now = Date()
        // 100 words over 90 seconds (1.5 min) => 66.666... => rounds to 66.7
        let entries = [
            makeEntry(date: now, wordCount: 100, durationSeconds: 90),
        ]
        let summary = HistoryStats.summarize(entries, now: now)
        XCTAssertEqual(summary.wordsPerMinute, 66.7)
    }

    func testZeroDurationAvoidsDivideByZero() {
        let now = Date()
        let entries = [
            makeEntry(date: now, wordCount: 10, durationSeconds: 0),
        ]
        let summary = HistoryStats.summarize(entries, now: now)
        XCTAssertEqual(summary.wordsPerMinute, 0)
    }
}
