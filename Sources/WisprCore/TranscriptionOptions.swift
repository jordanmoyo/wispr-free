import WhisperKit

/// Maps a user-pinned dictation language to WhisperKit `DecodingOptions`.
public enum TranscriptionOptions {
    /// The languages surfaced in Settings. WhisperKit's multilingual models
    /// support far more (see `Constants.languages`), but the picker only
    /// offers this curated set.
    public static let languages: [(code: String, name: String)] = [
        ("en", "English"),
        ("fr", "French"),
        ("de", "German"),
        ("es", "Spanish"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("ru", "Russian"),
    ]

    /// Builds decode options for a pinned language code, or auto-detection
    /// when `pinned` is nil or not a code WhisperKit recognizes.
    ///
    /// Validated against WhisperKit's own `Constants.languageCodes` (its
    /// public set of codes derived from `Constants.languages`) because an
    /// unrecognized code doesn't fail loudly: WhisperKit silently prefills
    /// the decoder with `<|en|>` (its `defaultLanguageCode`) instead, which
    /// would force English rather than falling back to detection. Note that
    /// pinning is a no-op on English-only models regardless of the code.
    public static func build(pinned: String?) -> DecodingOptions {
        guard let pinned, Constants.languageCodes.contains(pinned) else {
            return DecodingOptions(task: .transcribe, detectLanguage: true)
        }
        return DecodingOptions(task: .transcribe, language: pinned, detectLanguage: false)
    }
}
