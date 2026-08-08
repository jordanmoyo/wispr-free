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
        // Verbatim from this machine's model over a recording with nobody
        // speaking: the third way Whisper marks non-speech.
        XCTAssertEqual(TranscriptCleaner.clean("*sounds of rain* Thank you."), "Thank you.")
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

    /// Sign-offs from the subtitle corpora Whisper was trained on, in the
    /// languages the published hallucination corpora report them in. Nobody
    /// dictates these, so they are refused without consulting the audio.
    func testRecognisesSubtitleCreditsInEveryLanguageReported() {
        XCTAssertTrue(TranscriptCleaner.isNoSpeechArtifact("Thanks for watching!"))
        XCTAssertTrue(TranscriptCleaner.isNoSpeechArtifact("Please subscribe to my channel."))
        XCTAssertTrue(TranscriptCleaner.isNoSpeechArtifact("Sous-titrage Société Radio-Canada"))
        XCTAssertTrue(TranscriptCleaner.isNoSpeechArtifact("Спасибо за просмотр"))
        XCTAssertTrue(TranscriptCleaner.isNoSpeechArtifact("ご視聴ありがとうございました"))
        XCTAssertTrue(TranscriptCleaner.isNoSpeechArtifact("Untertitel im Auftrag des ZDF"))
    }

    /// The same credit turns up reworded, so the unmistakable fragment is
    /// matched too — but only in a transcript short enough to be a credit
    /// line rather than a sentence about subtitling.
    func testRecognisesRewordedCreditsWithoutEatingRealSentences() {
        XCTAssertTrue(TranscriptCleaner.isNoSpeechArtifact("Sous-titrage: ST' 501"))
        XCTAssertTrue(TranscriptCleaner.isNoSpeechArtifact("Субтитры сделал DimaTorzok"))
        // Verbatim from a live dictation into TextEdit with nothing audible
        // to record. The studio name is invented, so only the stem catches it.
        XCTAssertTrue(TranscriptCleaner.isNoSpeechArtifact("Sous-titres par Jérémy Diaz"))
        XCTAssertFalse(TranscriptCleaner.isNoSpeechArtifact(
            "Ask the vendor whether their sous-titrage workflow can export WebVTT for us."))
    }

    /// These are the words Whisper emits over silence that people also
    /// genuinely say, so `isNoSpeechArtifact` must leave them alone — the
    /// audio decides, in `DictationPlausibility`.
    func testFillerWordsAreSeparatedFromOutrightArtifacts() {
        XCTAssertFalse(TranscriptCleaner.isNoSpeechArtifact("Thank you."))
        XCTAssertFalse(TranscriptCleaner.isNoSpeechArtifact("You"))
        XCTAssertTrue(TranscriptCleaner.isWeakAudioFiller("Thank you."))
        XCTAssertTrue(TranscriptCleaner.isWeakAudioFiller(" You. "))
        XCTAssertTrue(TranscriptCleaner.isWeakAudioFiller("Merci"))
        XCTAssertFalse(TranscriptCleaner.isWeakAudioFiller("Thank you for the update"))
        // "every word is filler" is vacuously true of no words at all.
        XCTAssertFalse(TranscriptCleaner.isWeakAudioFiller(""))
    }

    /// Verbatim from this machine's model, handed 53 seconds of a real
    /// recording with nobody speaking. Matching whole phrases missed it —
    /// it is a mangling of the two phrases Whisper emits most over silence,
    /// and no list of phrases would have held it.
    func testRecognisesFillerWordsRunTogether() {
        XCTAssertTrue(TranscriptCleaner.isWeakAudioFiller("The Thank you."))
        XCTAssertTrue(TranscriptCleaner.isWeakAudioFiller("Oh. Okay. Yeah."))
    }

    /// Filler words are ordinary words; a sentence built from them is still
    /// a sentence, and length is what separates the two.
    func testALongSentenceOfCommonWordsIsNotFiller() {
        // Every word here is in the filler vocabulary; only the length rule
        // keeps it.
        XCTAssertFalse(TranscriptCleaner.isWeakAudioFiller("Yes so the end very good"))
    }

    /// Whisper's decoder loops on audio with no speech to anchor it, emitting
    /// one phrase over and over.
    func testRecognisesADecoderLoop() {
        XCTAssertTrue(TranscriptCleaner.isRepetitionLoop(String(repeating: "The end. ", count: 6)))
        XCTAssertTrue(TranscriptCleaner.isRepetitionLoop(
            String(repeating: "Thanks for watching ", count: 7)))
    }

    /// Emphatic real speech repeats too. The thresholds keep it.
    func testShortEmphaticRepetitionIsNotALoop() {
        XCTAssertFalse(TranscriptCleaner.isRepetitionLoop("no no no no no no"))
        XCTAssertFalse(TranscriptCleaner.isRepetitionLoop("okay okay okay okay okay"))
        XCTAssertFalse(TranscriptCleaner.isRepetitionLoop("The end."))
        XCTAssertFalse(TranscriptCleaner.isRepetitionLoop(
            "We shipped it, we tested it, and we shipped it again."))
    }

    func testKeepsNormalText() {
        XCTAssertEqual(TranscriptCleaner.clean("Bonjour, comment ça va?"),
                       "Bonjour, comment ça va?")
    }
}
