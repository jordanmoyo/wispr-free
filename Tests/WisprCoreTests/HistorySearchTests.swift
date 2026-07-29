import XCTest
@testable import WisprCore

final class HistorySearchTests: XCTestCase {
    private func makeEntry(rawText: String, cleanedText: String) -> HistoryEntry {
        HistoryEntry(
            id: UUID(),
            date: Date(),
            appName: "TestApp",
            appBundleID: "com.test.app",
            rawText: rawText,
            cleanedText: cleanedText,
            durationSeconds: 1,
            wordCount: cleanedText.split(separator: " ").count,
            delivered: true,
            appliedCorrections: nil)
    }

    func testEmptyQueryReturnsAllEntries() {
        let entries = [
            makeEntry(rawText: "hello world", cleanedText: "Hello world."),
            makeEntry(rawText: "goodbye", cleanedText: "Goodbye."),
        ]
        XCTAssertEqual(HistorySearch.filter(entries, query: "").count, 2)
        XCTAssertEqual(HistorySearch.filter(entries, query: "   ").count, 2)
    }

    func testCaseInsensitiveMatch() {
        let entries = [makeEntry(rawText: "hello world", cleanedText: "Hello World.")]
        let result = HistorySearch.filter(entries, query: "HELLO")
        XCTAssertEqual(result.count, 1)
    }

    func testDiacriticInsensitiveMatch() {
        let entries = [makeEntry(rawText: "cafe society", cleanedText: "café society")]
        let result = HistorySearch.filter(entries, query: "cafe")
        XCTAssertEqual(result.count, 1)
    }

    func testNoMatchReturnsEmpty() {
        let entries = [makeEntry(rawText: "hello world", cleanedText: "Hello world.")]
        let result = HistorySearch.filter(entries, query: "xyzzy")
        XCTAssertTrue(result.isEmpty)
    }

    func testMatchesRawTextWhenCleanedDiffers() {
        let entries = [makeEntry(rawText: "unique raw phrase", cleanedText: "Completely different cleaned text.")]
        let result = HistorySearch.filter(entries, query: "unique raw")
        XCTAssertEqual(result.count, 1)
    }
}
