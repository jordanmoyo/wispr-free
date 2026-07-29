import XCTest
@testable import WisprCore

final class CorrectionApplierTests: XCTestCase {
    func testLowercasePatternPreserved() {
        let result = CorrectionApplier.apply(
            [(wrong: "recete", right: "receipt")], to: "please send the recete now")
        XCTAssertEqual(result.text, "please send the receipt now")
        XCTAssertEqual(result.applied, ["recete → receipt"])
    }

    func testCapitalizedPatternPreserved() {
        let result = CorrectionApplier.apply(
            [(wrong: "recete", right: "receipt")], to: "Recete is attached")
        XCTAssertEqual(result.text, "Receipt is attached")
    }

    func testAllCapsPatternPreserved() {
        let result = CorrectionApplier.apply(
            [(wrong: "recete", right: "receipt")], to: "RECETE is attached")
        XCTAssertEqual(result.text, "RECEIPT is attached")
    }

    func testWholeWordOnlyNeverTouchesSubstring() {
        let result = CorrectionApplier.apply(
            [(wrong: "cat", right: "dog")], to: "category catalog cat")
        XCTAssertEqual(result.text, "category catalog dog")
        XCTAssertEqual(result.applied, ["cat → dog"])
    }

    func testStopListedWordNeverReplacedEvenWhenRecorded() {
        let result = CorrectionApplier.apply(
            [(wrong: "their", right: "there")], to: "their book is on the table")
        XCTAssertEqual(result.text, "their book is on the table")
        XCTAssertTrue(result.applied.isEmpty)
    }

    func testStopListMatchIsCaseInsensitive() {
        let result = CorrectionApplier.apply(
            [(wrong: "Their", right: "there")], to: "Their book")
        XCTAssertEqual(result.text, "Their book")
        XCTAssertTrue(result.applied.isEmpty)
    }

    func testMultiWordPairIgnored() {
        let result = CorrectionApplier.apply(
            [(wrong: "multi word", right: "fixed")], to: "a multi word phrase")
        XCTAssertEqual(result.text, "a multi word phrase")
        XCTAssertTrue(result.applied.isEmpty)
    }

    func testAppliedFormatIsWrongArrowRight() {
        let result = CorrectionApplier.apply(
            [(wrong: "recete", right: "receipt")], to: "the recete")
        XCTAssertEqual(result.applied, ["recete → receipt"])
    }

    func testNoMatchProducesNoAppliedEntry() {
        let result = CorrectionApplier.apply(
            [(wrong: "recete", right: "receipt")], to: "nothing to fix here")
        XCTAssertEqual(result.text, "nothing to fix here")
        XCTAssertTrue(result.applied.isEmpty)
    }

    func testMultipleOccurrencesAllReplaced() {
        let result = CorrectionApplier.apply(
            [(wrong: "recete", right: "receipt")], to: "recete one and recete two")
        XCTAssertEqual(result.text, "receipt one and receipt two")
        XCTAssertEqual(result.applied, ["recete → receipt"])
    }

    func testMultiplePairsAppliedInOrder() {
        let result = CorrectionApplier.apply(
            [(wrong: "recete", right: "receipt"), (wrong: "teh", right: "the")],
            to: "recete for teh order")
        XCTAssertEqual(result.text, "receipt for the order")
        XCTAssertEqual(result.applied, ["recete → receipt", "teh → the"])
    }
}
