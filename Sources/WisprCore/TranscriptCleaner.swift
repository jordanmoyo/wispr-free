import Foundation

public enum TranscriptCleaner {
    /// Removes Whisper non-speech artifacts and normalizes whitespace.
    ///
    /// Special tokens go first. The dictation path never saw them —
    /// WhisperKit's `TranscriptionResult.text` is already detokenized — but
    /// `TranscriptionSegment.text`, which Meetings uses because it needs per
    /// segment timings, is the raw decoder output. A live meeting transcript
    /// therefore read
    /// `<|startoftranscript|><|en|><|transcribe|><|0.00|> Good morning.<|1.32|>`
    /// verbatim in the detail pane, in the copied Markdown, and in the text
    /// handed to the summarizer.
    public static func clean(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: " ",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: #"\([^)]*\)"#, with: " ",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ",
                                         options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Phrases Whisper emits for a stretch of near-silence rather than for
    /// anything anyone said — an artifact of its training on subtitle
    /// corpora.
    ///
    /// Deliberately short. Every entry here is speech that gets thrown away
    /// if someone really does say it alone, so it holds only phrases that
    /// are not plausible standalone meeting utterances. "Thank you." is a
    /// real thing to say in a meeting and is NOT on this list, even though
    /// Whisper also hallucinates it.
    private static let silenceHallucinations: Set<String> = [
        "you",
        "thanks for watching",
        "thank you for watching",
        "please subscribe to my channel",
        "subtitles by the amara.org community",
    ]

    /// True when a segment is entirely one of the artifacts above.
    ///
    /// Meetings-only, and applied per segment. A meeting records continuously,
    /// so most of its audio is silence between speakers, and a live two-person
    /// test came back with four of its seven segments reading `you`. Dictation
    /// records only while the key is held, where a lone "you" is far more
    /// likely to be something the user actually said and meant to insert.
    public static func isSilenceHallucination(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:…"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return silenceHallucinations.contains(normalized)
    }
}
