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
        // Whisper marks non-speech three ways, not two: run over a real
        // recording with nobody speaking, this machine's model returned
        // "*sounds of rain* Thank you.".
        text = text.replacingOccurrences(of: #"\*[^*]*\*"#, with: " ",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ",
                                         options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sign-off lines from the subtitle corpora Whisper was trained on, which
    /// it emits when handed audio containing no speech. Nobody dictates these
    /// into a text field and nobody says them in a meeting, so they are
    /// rejected on sight in both paths, whatever the audio looked like.
    ///
    /// Drawn from the published no-speech hallucination corpora and issue
    /// reports (openai/whisper discussions #928, #1606, #1873; the
    /// `sachaarbonel/whisper-hallucinations` noise-only dataset). Stored
    /// normalized: lower-cased, outer punctuation stripped.
    private static let noSpeechArtifacts: Set<String> = [
        // English — the sign-offs of the YouTube subtitles in the corpus.
        "thanks for watching",
        "thank you for watching",
        "thanks for watching this video",
        "thank you for watching this video",
        "thanks for watching and see you next time",
        "thanks for watching please subscribe",
        "thank you for watching please subscribe",
        "please subscribe to my channel",
        "subscribe to my channel",
        "please subscribe",
        "like and subscribe",
        "don't forget to like and subscribe",
        "see you in the next video",
        "see you next time",
        "subtitles by the amara.org community",
        "transcription by castingwords",
        // French — Radio-Canada and ST'501 are subtitling houses whose credit
        // lines close a great many French broadcasts in the training data.
        "sous-titrage société radio-canada",
        "sous-titrage st' 501",
        "sous-titres réalisés par la communauté d'amara.org",
        "sous-titres réalisés para la communauté d'amara.org",
        "merci d'avoir regardé cette vidéo",
        "merci d'avoir regardé cette vidéo et à bientôt",
        "abonnez-vous à ma chaîne",
        // Spanish / Portuguese / Italian.
        "gracias por ver el video",
        "gracias por ver el vídeo",
        "suscríbete al canal",
        "subtítulos realizados por la comunidad de amara.org",
        "obrigado por assistir",
        "obrigado por assistir ao vídeo",
        "legendas pela comunidade amara.org",
        "grazie per aver guardato il video",
        "sottotitoli e revisione a cura di qtss",
        // German / Dutch / Polish / Turkish / Indonesian.
        "untertitel im auftrag des zdf",
        "untertitelung aufgrund der amara.org-community",
        "vielen dank für's zuschauen",
        "vielen dank fürs zuschauen",
        "bedankt voor het kijken",
        "napisy stworzone przez społeczność amara.org",
        "dziękuję za obejrzenie",
        "izlediğiniz için teşekkür ederim",
        "terima kasih telah menonton",
        "cảm ơn các bạn đã xem video",
        // Russian.
        "спасибо за просмотр",
        "подписывайтесь на мой канал",
        "продолжение следует",
        "субтитры сделал dimatorzok",
        "субтитры создавал dimatorzok",
        // CJK / Korean / Greek / Arabic.
        "ご視聴ありがとうございました",
        "見てくれてありがとう",
        "字幕志愿者 杨茜茜",
        "由 amara.org 社群提供的字幕",
        "谢谢观看 下集再见",
        "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目",
        "시청해주셔서 감사합니다",
        "ευχαριστώ που παρακολουθήσατε",
        "شكرا على المشاهدة",
    ]

    /// Fragments that identify a subtitle credit however it is worded. The
    /// same credit turns up with the studio name reordered, a colon added, or
    /// a different community suffix, and enumerating every variant is
    /// hopeless.
    ///
    /// Only consulted for short transcripts (see `artifactMarkerMaxLength`),
    /// so a dictated sentence that happens to discuss subtitling survives.
    /// Matched as stems, not whole credits: run live, this machine's model
    /// produced "Sous-titres par Jérémy Diaz", a form none of the published
    /// corpora list and no enumeration of studio names would have held. What
    /// every variant shares is the word for "subtitle" followed by an
    /// attribution.
    private static let artifactMarkers: [String] = [
        "amara.org",
        "sous-titre",
        "sous-titrage",
        "subtitles by",
        "subtitled by",
        "subtitling by",
        "untertitel",
        "subtítulos por",
        "subtítulos realizados",
        "legendas por",
        "legendas pela",
        "sottotitoli",
        "napisy",
        "transcription by castingwords",
        "субтитры",
        "字幕",
    ]

    /// A credit line is short. Beyond this length a marker match is far more
    /// likely to be someone genuinely dictating about subtitles.
    private static let artifactMarkerMaxLength = 60

    /// Words Whisper strings together over silence. Unlike the artifacts
    /// above, every one of these is something a person really might say, so
    /// a match is only meaningful when the audio backs it up — see
    /// `AudioQuality.marginalSpeech`.
    ///
    /// Matched as a vocabulary rather than as whole phrases: run over 53
    /// seconds of a real recording with nobody speaking, this machine's model
    /// returned "The Thank you." — a mangling of its two favourite silence
    /// outputs that no list of phrases would have contained.
    private static let weakAudioFillerWords: Set<String> = [
        "you", "the", "thank", "thanks", "a", "so", "and", "oh", "okay", "ok",
        "bye", "goodbye", "hello", "hi", "yeah", "yes", "no", "um", "uh",
        "hmm", "mm", "mhm", "good", "very", "much", "end", "sorry", "god",
        "my", "please", "well", "right", "lot",
        "merci", "beaucoup", "oui", "non", "au", "revoir", "voilà", "bonjour",
        "salut", "gracias", "sí", "adiós", "hola", "obrigado", "obrigada",
        "tchau", "fim", "sim", "grazie", "ciao", "sì", "danke", "tschüss",
        "hallo", "ja", "nein", "bedankt", "спасибо", "пока", "да", "нет",
        "ありがとうございました", "ありがとう", "はい", "谢谢", "好", "是",
        "감사합니다", "네", "תודה", "רבה", "شكرا",
    ]

    /// Beyond this many words a transcript carries content, whatever the
    /// words are, and is left alone.
    private static let maximumFillerWords = 5

    /// Lower-cased, outer-punctuation-stripped, whitespace-collapsed form the
    /// lists above are stored in.
    private static func normalized(_ text: String) -> String {
        clean(text)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:…-–— \"'"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Normalized words with punctuation stripped from each one, not just
    /// from the ends of the transcript: a decoder loop reads "The end. The
    /// end. … The end", where only the last repetition lacks its full stop.
    private static func wordsIgnoringPunctuation(_ text: String) -> [String] {
        let punctuation = CharacterSet(charactersIn: ".!?,;:…-–—\"'")
        return normalized(text)
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: punctuation) }
            .filter { !$0.isEmpty }
    }

    /// True when the text is nothing but a subtitle-corpus artifact — text
    /// Whisper produced from audio nobody spoke into.
    ///
    /// Safe to act on unconditionally: no audio check needed, because none of
    /// these is something a user dictates or says in a meeting.
    public static func isNoSpeechArtifact(_ text: String) -> Bool {
        let normalized = normalized(text)
        if noSpeechArtifacts.contains(normalized) { return true }
        guard normalized.count <= artifactMarkerMaxLength else { return false }
        return artifactMarkers.contains { normalized.contains($0) }
    }

    /// True when the text is nothing but a handful of the words Whisper
    /// emits over silence.
    ///
    /// A match alone proves nothing — the caller must also have established
    /// that the audio held little speech, or this discards a word the user
    /// really said.
    public static func isWeakAudioFiller(_ text: String) -> Bool {
        let words = wordsIgnoringPunctuation(text)
        guard !words.isEmpty, words.count <= maximumFillerWords else { return false }
        return words.allSatisfy { weakAudioFillerWords.contains($0) }
    }

    /// True when the text is one short phrase repeated over and over, the
    /// shape Whisper's decoder falls into when it loops on audio with no
    /// speech to anchor it ("The End. The End. The End. …").
    ///
    /// Thresholds are set high — six repetitions of a unit of at least four
    /// characters — so that emphatic real speech ("no no no") is left alone.
    public static func isRepetitionLoop(_ text: String) -> Bool {
        let words = wordsIgnoringPunctuation(text)
        guard words.count >= 6 else { return false }
        for unitLength in 1...(words.count / 6) {
            guard words.count % unitLength == 0 else { continue }
            let unit = Array(words[0..<unitLength])
            guard unit.joined().count >= 4 else { continue }
            let everyChunkMatches = stride(from: 0, to: words.count, by: unitLength)
                .allSatisfy { Array(words[$0..<($0 + unitLength)]) == unit }
            if everyChunkMatches { return true }
        }
        return false
    }

    /// True when a meeting segment is entirely an artifact.
    ///
    /// Meetings-only, and applied per segment: it adds a bare "you" to the
    /// artifacts above. A meeting records continuously, so most of its audio
    /// is silence between speakers, and a live two-person test came back with
    /// four of its seven segments reading `you`. Dictation records only while
    /// the key is held, so it gates that same word on the audio instead (see
    /// `isWeakAudioFiller`).
    public static func isSilenceHallucination(_ text: String) -> Bool {
        if normalized(text) == "you" { return true }
        return isNoSpeechArtifact(text)
    }
}
