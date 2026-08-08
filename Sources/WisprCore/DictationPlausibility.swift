import Foundation

/// Why a transcript was refused instead of being typed into the user's
/// document.
public enum DictationRefusal: Equatable, Sendable {
    /// The model returned nothing that carries content — no text at all, or
    /// punctuation only. A live silent hold delivered a bare "-".
    case empty
    /// The model returned a subtitle-corpus sign-off (see
    /// `TranscriptCleaner.isNoSpeechArtifact`).
    case noSpeechArtifact
    /// The model's decoder looped on one phrase.
    case repetitionLoop
    /// The model returned a bare filler word and the audio held too little
    /// speech to believe it.
    case weakAudioFiller

    /// One line for the pill, phrased as the next thing to try. Kept short
    /// because the pill renders errors on a single line.
    public var userMessage: String {
        switch self {
        case .empty: return "Nothing heard — try again"
        case .noSpeechArtifact, .repetitionLoop: return "Didn't catch that — try again"
        case .weakAudioFiller: return "Didn't catch that — a bit louder?"
        }
    }
}

/// Decides whether a transcript is plausibly something the user said.
///
/// The audio gate (`AudioQualityGate`) runs first and is deliberately
/// lenient, so recordings that hold barely any speech still reach the model.
/// This is the second line of defence: it looks at what came back, and for
/// the ambiguous cases weighs it against how much speech the audio actually
/// contained.
public enum DictationPlausibility {
    /// A bare filler word arriving with an average token log-probability
    /// this poor is not believed, however loud the recording was.
    ///
    /// Needed because loudness is not proof of speech: replaying room noise
    /// through the speakers put the audio well above the speech floor, so the
    /// audio-backed filler rule below never ran, and "Thank you." — the
    /// single most reported Whisper silence artifact — was typed out at
    /// -0.372.
    ///
    /// Deliberately narrow. All 72 recordings this machine had archived were
    /// re-transcribed through the production decode path, and a general
    /// "refuse anything below X" rule turned out to be unusable: with a
    /// language pinned in Settings, dictation in another language comes back
    /// translated and scores as badly as any hallucination. Real French
    /// dictations landed at -0.836 and -0.669, interleaved with the silence
    /// artifacts at -0.365 to -0.592, so any threshold that caught the
    /// artifacts also threw away speech. What survives that corpus is this
    /// much weaker claim: nothing anybody actually dictated, in either
    /// language, was filler words alone *and* scored below this.
    public static let confidentFillerLogProbability: Float = -0.30

    public static func refusal(for text: String, quality: AudioQuality,
                               confidence: Float? = nil) -> DictationRefusal? {
        if !text.contains(where: { $0.isLetter || $0.isNumber }) { return .empty }
        if TranscriptCleaner.isNoSpeechArtifact(text) { return .noSpeechArtifact }
        if TranscriptCleaner.isRepetitionLoop(text) { return .repetitionLoop }
        // "Thank you" is both the phrase Whisper emits most often over
        // silence and an ordinary thing to dictate, so it is thrown away
        // only when something else says it was not spoken: either the
        // recording held too little speech to have contained it, or the
        // decoder was unsure of it.
        let unsure = confidence.map { $0 < confidentFillerLogProbability } ?? false
        if quality == .marginalSpeech || unsure, TranscriptCleaner.isWeakAudioFiller(text) {
            return .weakAudioFiller
        }
        return nil
    }
}
