import XCTest
@testable import WisprCore

final class DictationPlausibilityTests: XCTestCase {
    func testAnEmptyTranscriptIsRefused() {
        XCTAssertEqual(DictationPlausibility.refusal(for: "", quality: .speech), .empty)
        XCTAssertEqual(DictationPlausibility.refusal(for: "   \n", quality: .speech), .empty)
    }

    /// Subtitle sign-offs are refused whatever the audio looked like: they
    /// are never something a user dictated.
    func testSubtitleCreditsAreRefusedEvenAfterGoodAudio() {
        XCTAssertEqual(DictationPlausibility.refusal(for: "Thanks for watching!", quality: .speech),
                       .noSpeechArtifact)
        XCTAssertEqual(
            DictationPlausibility.refusal(for: "Sous-titrage Société Radio-Canada",
                                          quality: .speech),
            .noSpeechArtifact)
    }

    func testADecoderLoopIsRefused() {
        let looped = String(repeating: "The end. ", count: 8)
        XCTAssertEqual(DictationPlausibility.refusal(for: looped, quality: .speech),
                       .repetitionLoop)
    }

    /// The whole point of the audio gate: "Thank you" is both the phrase
    /// Whisper emits most often over silence and an ordinary thing to
    /// dictate. Which one it is depends on the recording.
    func testAFillerWordIsRefusedOnlyWhenTheAudioDoesNotBackItUp() {
        XCTAssertEqual(DictationPlausibility.refusal(for: "Thank you.", quality: .marginalSpeech),
                       .weakAudioFiller)
        XCTAssertNil(DictationPlausibility.refusal(for: "Thank you.", quality: .speech))
    }

    /// Loud is not the same as spoken. Replaying room noise through the
    /// speakers scored the audio as full speech, so the audio-backed rule
    /// above stood down and this exact transcript was typed out at -0.372.
    /// An unsure decoder is the other thing that discredits a filler word.
    func testAFillerWordIsRefusedWhenLoudAudioCameBackUnsure() {
        XCTAssertEqual(
            DictationPlausibility.refusal(for: "Thank you.", quality: .speech,
                                          confidence: -0.372),
            .weakAudioFiller)
        // A confident one is left alone: people do dictate "thank you".
        XCTAssertNil(DictationPlausibility.refusal(for: "Thank you.", quality: .speech,
                                                   confidence: -0.20))
    }

    func testOrdinaryDictationIsDelivered() {
        XCTAssertNil(DictationPlausibility.refusal(
            for: "Ship the release notes before the standup.", quality: .speech))
        XCTAssertNil(DictationPlausibility.refusal(
            for: "Ship the release notes before the standup.", quality: .marginalSpeech))
    }

    /// A transcript carrying no letters or digits is not something the user
    /// dictated. Verbatim from a live silent hold, which delivered a bare
    /// "-" into the frontmost window.
    func testPunctuationOnlyTranscriptIsRefused() {
        XCTAssertEqual(DictationPlausibility.refusal(for: "-", quality: .speech), .empty)
        XCTAssertEqual(DictationPlausibility.refusal(for: " ... ", quality: .speech), .empty)
        XCTAssertNil(DictationPlausibility.refusal(for: "9", quality: .speech))
    }

    /// A poor score is not on its own evidence of a hallucination, and must
    /// not refuse a sentence. With a language pinned in Settings, dictation
    /// in another language comes back translated and scores as badly as
    /// anything Whisper invents: both of these are verbatim from the
    /// archive — real French speech, decoded under the pinned "en", at
    /// -0.836 and -0.669.
    func testATranslatedDictationIsDeliveredHoweverBadlyItScored() {
        XCTAssertNil(DictationPlausibility.refusal(
            for: "and who is the one who provides the documents of the spouse",
            quality: .speech, confidence: -0.836))
        XCTAssertNil(DictationPlausibility.refusal(
            for: "Recuperate the information recently",
            quality: .speech, confidence: -0.669))
    }

    /// Every refusal has to say something — a dictation that produces no text
    /// and no explanation is the failure this feature exists to prevent.
    func testEveryRefusalCarriesAMessage() {
        for refusal in [DictationRefusal.empty, .noSpeechArtifact, .repetitionLoop,
                        .weakAudioFiller] {
            XCTAssertFalse(refusal.userMessage.isEmpty, "\(refusal)")
        }
    }
}
