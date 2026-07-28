import Foundation

public enum TranscriptCleaner {
    /// Removes Whisper non-speech artifacts and normalizes whitespace.
    public static func clean(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: #"\([^)]*\)"#, with: " ",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ",
                                         options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
