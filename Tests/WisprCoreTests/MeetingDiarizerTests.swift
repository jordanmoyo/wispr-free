import XCTest
@testable import WisprCore

final class MeetingDiarizerTests: XCTestCase {
    func testNullDiarizerReturnsNoSpans() async throws {
        let spans = try await NullDiarizer().diarize(
            samples: [Float](repeating: 0, count: 16_000 * 10), progress: nil)
        XCTAssertTrue(spans.isEmpty)
    }

    func testShortAudioThrowsTooShort() async {
        let diarizer = FluidAudioDiarizer()
        do {
            _ = try await diarizer.diarize(
                samples: [Float](repeating: 0, count: 16_000), progress: nil)  // 1 s
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? DiarizationError, .tooShort)
        }
    }

    func testEmptyAudioThrowsTooShort() async {
        let diarizer = FluidAudioDiarizer()
        do {
            _ = try await diarizer.diarize(samples: [], progress: nil)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? DiarizationError, .tooShort)
        }
    }

    func testSpanMappingConvertsFloatSecondsAndOrdersByStart() {
        let mapped = FluidAudioDiarizer.spans(from: [
            (speakerID: "2", start: Float(4.5), end: Float(6.25)),
            (speakerID: "1", start: Float(0.0), end: Float(4.5)),
        ])
        XCTAssertEqual(mapped, [
            DiarizedSpan(speakerID: "1", start: 0, end: 4.5),
            DiarizedSpan(speakerID: "2", start: 4.5, end: 6.25),
        ])
    }

    func testSpanMappingDropsZeroAndNegativeLengthSpans() {
        let mapped = FluidAudioDiarizer.spans(from: [
            (speakerID: "1", start: Float(1.0), end: Float(1.0)),
            (speakerID: "2", start: Float(3.0), end: Float(2.0)),
            (speakerID: "3", start: Float(4.0), end: Float(5.0)),
        ])
        XCTAssertEqual(mapped.map(\.speakerID), ["3"])
    }

    func testSpanMappingOfNothingIsEmpty() {
        XCTAssertTrue(FluidAudioDiarizer.spans(from: []).isEmpty)
    }

    /// PRIVACY.md promises that deleting `~/Library/Application Support/
    /// Wispr/` removes everything including models, and the Homebrew cask
    /// zaps only `Wispr` plus the preferences. FluidAudio's default cache
    /// (`…/Application Support/FluidAudio/Models/`) is outside both, so
    /// several hundred MB survived either route. Wherever FluidAudio
    /// ultimately puts the files relative to this URL, they must stay under
    /// Wispr's own folder.
    func testDiarizationModelsAreCachedInsideWisprsOwnFolder() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let models = FluidAudioDiarizer.modelsDirectory()
        XCTAssertTrue(models.path.hasPrefix(
            support.appendingPathComponent("Wispr").path + "/"),
            "diarization models must live under Application Support/Wispr — "
                + "got \(models.path)")
        // FluidAudio 0.15.5 uses this URL's parent as the cache root, so the
        // parent must be inside Wispr too, not merely the leaf.
        XCTAssertTrue(models.deletingLastPathComponent().path.hasPrefix(
            support.appendingPathComponent("Wispr").path + "/"),
            "the parent directory is the one FluidAudio actually writes into")
    }

    func testErrorMessagesAreUserFacing() {
        XCTAssertFalse(DiarizationError.tooShort.userMessage.isEmpty)
        XCTAssertFalse(DiarizationError.modelsUnavailable("x").userMessage.isEmpty)
        XCTAssertTrue(
            DiarizationError.modelsUnavailable("x").userMessage.contains("speaker"))
    }
}
