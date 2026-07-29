import XCTest
@testable import WisprCore

final class WordDiffTests: XCTestCase {
    private func flatten(_ pairs: [(wrong: String, right: String)]) -> [String] {
        pairs.map { "\($0.wrong)|\($0.right)" }
    }

    func testSingleSubstitution() {
        let result = WordDiff.corrections(from: "send the recete", to: "send the receipt")
        XCTAssertEqual(flatten(result), ["recete|receipt"])
    }

    func testTwoSubstitutionsBothCaptured() {
        let original = "I need to send the recete for the pls review"
        let edited = "I need to send the receipt for the please review"
        let result = WordDiff.corrections(from: original, to: edited)
        XCTAssertEqual(flatten(result), ["recete|receipt", "pls|please"])
    }

    func testPureInsertionYieldsNoCorrections() {
        let result = WordDiff.corrections(from: "send it", to: "send it now")
        XCTAssertTrue(result.isEmpty)
    }

    func testPureDeletionYieldsNoCorrections() {
        let result = WordDiff.corrections(from: "send it now", to: "send it")
        XCTAssertTrue(result.isEmpty)
    }

    /// Two original tokens collapsing into one edited token is a split, not
    /// a 1:1 substitution — it can't be expressed as a single word pair.
    func testSplitIsNotProducibleAsOneToOne() {
        let result = WordDiff.corrections(from: "whisper er", to: "Wispr")
        XCTAssertTrue(result.isEmpty)
    }

    func testChangedRatioAboveFortyPercentYieldsNoCorrections() {
        // 2 of 3 tokens substituted (66%) reads as a rewrite, not a fix.
        let result = WordDiff.corrections(from: "the cat sat", to: "the dog ran")
        XCTAssertTrue(result.isEmpty)
    }

    func testCaseOnlyDifferenceIsNotACorrection() {
        let result = WordDiff.corrections(from: "hello", to: "Hello")
        XCTAssertTrue(result.isEmpty)
    }

    func testPunctuationOnlyDifferenceIsNotACorrection() {
        let result = WordDiff.corrections(from: "end.", to: "end")
        XCTAssertTrue(result.isEmpty)
    }

    func testIdenticalInputsYieldNoCorrections() {
        let result = WordDiff.corrections(from: "hello world", to: "hello world")
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptyOriginalYieldsNoCorrections() {
        let result = WordDiff.corrections(from: "", to: "hello")
        XCTAssertTrue(result.isEmpty)
    }
}
