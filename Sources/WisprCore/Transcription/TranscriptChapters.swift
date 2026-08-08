import Foundation

/// Parses and validates the chapter list a model produces for a long
/// recording.
///
/// The validation is the point. A model asked for timestamps will
/// occasionally invent one past the end of the audio, or emit a list that
/// walks backwards. A chapter that jumps to 09:59:00 of a ten-minute file is
/// not a formatting problem, it is a fabrication — so it is dropped rather
/// than shown. Everything unparseable yields no chapter at all: an empty
/// list is honest, a guessed one is not.
public enum TranscriptChapters {
    /// "01:02:05" — always hours, so a list sorts and aligns as text.
    public static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d:%02d",
                      total / 3600, (total % 3600) / 60, total % 60)
    }

    /// Accepts "HH:MM:SS" and "MM:SS". Anything else is nil.
    ///
    /// Every component below the first is bounded to 0...59. Without that
    /// bound "05:70" reinterprets as 6 m 10 s, which is not what the model
    /// meant to say and is not a timestamp the transcript contains — and
    /// because 70 s lands BEFORE a later real stamp, the monotonic check in
    /// `parse` then drops the following legitimate chapter instead. A stamp
    /// that cannot be read is better dropped than silently re-read.
    public static func parseTimestamp(_ text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0
        for (index, part) in parts.enumerated() {
            guard let value = Int(part), value >= 0 else { return nil }
            guard index == 0 || value < 60 else { return nil }
            seconds = seconds * 60 + value
        }
        return TimeInterval(seconds)
    }

    /// Chapters from raw model output, keeping only those that parse, run
    /// strictly forwards, and fall inside `duration`.
    public static func parse(_ raw: String, duration: TimeInterval) -> [TranscriptChapter] {
        let text = MeetingSummarizer.stripThinking(raw)
        var chapters: [TranscriptChapter] = []
        var lastStart: TimeInterval = -1

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let open = trimmed.firstIndex(of: "["),
                  let close = trimmed[open...].firstIndex(of: "]") else { continue }

            let stamp = String(trimmed[trimmed.index(after: open)..<close])
            guard let start = parseTimestamp(stamp) else { continue }
            // Past the end of the audio: invented, not merely misformatted.
            guard start <= duration else { continue }
            // Strictly forwards, which also drops duplicate timestamps.
            guard start > lastStart else { continue }

            let title = String(trimmed[trimmed.index(after: close)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:*•"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            chapters.append(TranscriptChapter(start: start, title: title))
            lastStart = start
        }
        return chapters
    }
}
