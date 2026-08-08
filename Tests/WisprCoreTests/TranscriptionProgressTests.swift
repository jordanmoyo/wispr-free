import XCTest
@testable import WisprCore

final class TranscriptionProgressTests: XCTestCase {
    // MARK: - DiarizationGate

    func testDiarizationAvailableUpToAndIncludingTheCeiling() {
        XCTAssertTrue(DiarizationGate.available(durationSeconds: 600))
        XCTAssertTrue(DiarizationGate.available(durationSeconds: DiarizationGate.maxSeconds))
    }

    func testDiarizationUnavailablePastTheCeiling() {
        XCTAssertFalse(DiarizationGate.available(
            durationSeconds: DiarizationGate.maxSeconds + 1))
    }

    func testDiarizationUnavailableForEmptyAudio() {
        XCTAssertFalse(DiarizationGate.available(durationSeconds: 0))
    }

    func testAvailableDurationHasNoReason() {
        XCTAssertNil(DiarizationGate.unavailableReason(durationSeconds: 600))
    }

    func testReasonStatesTheCeilingAndTheActualLength() {
        let reason = DiarizationGate.unavailableReason(durationSeconds: 7_200)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("60 minutes"))
        XCTAssertTrue(reason!.contains("120"))
    }

    // MARK: - Progress weighting

    func testWithoutDiarizationTranscriptionSpansTheWholeBar() {
        XCTAssertEqual(TranscriptionProgress.overall(
            stage: .transcribing, stageFraction: 0, diarizationEnabled: false), 0, accuracy: 0.001)
        XCTAssertEqual(TranscriptionProgress.overall(
            stage: .transcribing, stageFraction: 1, diarizationEnabled: false), 1, accuracy: 0.001)
    }

    func testWithDiarizationTranscriptionStartsAfterTheDiarizationShare() {
        XCTAssertEqual(TranscriptionProgress.overall(
            stage: .transcribing, stageFraction: 0, diarizationEnabled: true),
            TranscriptionProgress.diarizationShare, accuracy: 0.001)
        XCTAssertEqual(TranscriptionProgress.overall(
            stage: .transcribing, stageFraction: 1, diarizationEnabled: true), 1, accuracy: 0.001)
    }

    func testDiarizationOccupiesOnlyItsShare() {
        XCTAssertEqual(TranscriptionProgress.overall(
            stage: .diarizing, stageFraction: 1, diarizationEnabled: true),
            TranscriptionProgress.diarizationShare, accuracy: 0.001)
    }

    func testDiarizingStageContributesNothingWhenDisabled() {
        XCTAssertEqual(TranscriptionProgress.overall(
            stage: .diarizing, stageFraction: 1, diarizationEnabled: false), 0, accuracy: 0.001)
    }

    func testProgressNeverGoesBackwardsAcrossStages() {
        let atDiarizeEnd = TranscriptionProgress.overall(
            stage: .diarizing, stageFraction: 1, diarizationEnabled: true)
        let atTranscribeStart = TranscriptionProgress.overall(
            stage: .transcribing, stageFraction: 0, diarizationEnabled: true)
        XCTAssertGreaterThanOrEqual(atTranscribeStart, atDiarizeEnd)
    }

    func testOutOfRangeStageFractionsAreClamped() {
        XCTAssertEqual(TranscriptionProgress.overall(
            stage: .transcribing, stageFraction: 5, diarizationEnabled: false), 1, accuracy: 0.001)
        XCTAssertEqual(TranscriptionProgress.overall(
            stage: .transcribing, stageFraction: -3, diarizationEnabled: false), 0, accuracy: 0.001)
    }

    func testDoneIsAlwaysComplete() {
        XCTAssertEqual(TranscriptionProgress.overall(
            stage: .done, stageFraction: 0, diarizationEnabled: true), 1, accuracy: 0.001)
    }
}
