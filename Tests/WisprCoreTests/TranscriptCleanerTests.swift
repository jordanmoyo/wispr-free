import XCTest
@testable import WisprCore

final class TranscriptCleanerTests: XCTestCase {
    func testTrimsAndCollapsesWhitespace() {
        XCTAssertEqual(TranscriptCleaner.clean("  hello   world \n"), "hello world")
    }

    func testStripsBracketArtifacts() {
        XCTAssertEqual(TranscriptCleaner.clean("[BLANK_AUDIO]"), "")
        XCTAssertEqual(TranscriptCleaner.clean("hello [MUSIC] world"), "hello world")
        XCTAssertEqual(TranscriptCleaner.clean("(door slams) hi"), "hi")
    }

    /// `TranscriptionSegment.text` — the only WhisperKit output carrying the
    /// per-segment timings Meetings needs — is raw decoder output, not the
    /// detokenized string the dictation path reads. Verbatim from a live
    /// meeting before this was stripped.
    func testStripsWhisperSpecialTokens() {
        XCTAssertEqual(
            TranscriptCleaner.clean(
                "<|startoftranscript|><|en|><|transcribe|><|0.00|> Good morning "
                    + "everyone.<|1.32|><|endoftext|>"),
            "Good morning everyone.")
        // A lone timestamp token between words must not weld them together.
        XCTAssertEqual(TranscriptCleaner.clean("hello<|2.00|>world"), "hello world")
    }

    /// A live two-person meeting came back with four of its seven segments
    /// reading `you` — Whisper's output for the silence between speakers.
    func testRecognisesTheArtifactsWhisperEmitsOverSilence() {
        XCTAssertTrue(TranscriptCleaner.isSilenceHallucination("you"))
        XCTAssertTrue(TranscriptCleaner.isSilenceHallucination(" You. "))
        XCTAssertTrue(TranscriptCleaner.isSilenceHallucination("Thanks for watching!"))
        XCTAssertTrue(
            TranscriptCleaner.isSilenceHallucination("Subtitles by the Amara.org community"))
    }

    /// The filter throws speech away, so it must only match a segment that is
    /// nothing but the artifact — and must leave alone the phrases Whisper
    /// hallucinates that people also genuinely say.
    func testDoesNotDiscardRealSpeech() {
        XCTAssertFalse(TranscriptCleaner.isSilenceHallucination("Thank you."),
                       "a real thing to say in a meeting")
        XCTAssertFalse(TranscriptCleaner.isSilenceHallucination("you should ship it"))
        XCTAssertFalse(TranscriptCleaner.isSilenceHallucination("Are you watching?"))
        XCTAssertFalse(TranscriptCleaner.isSilenceHallucination(""))
    }

    func testKeepsNormalText() {
        XCTAssertEqual(TranscriptCleaner.clean("Bonjour, comment ça va?"),
                       "Bonjour, comment ça va?")
    }
}
