import Foundation

/// Deterministic, regex-based application of learned wrong→right word
/// corrections. Unlike the cleanup model's hints (which the model is free
/// to ignore or misapply), this is a guaranteed whole-word, case-preserving
/// find-and-replace.
public enum CorrectionApplier {
    /// Words excluded from automatic replacement because context — not
    /// spelling — decides which member of the pair is correct (e.g.
    /// "there" vs "their"). Replacing one of these on a recorded pair would
    /// risk corrupting otherwise-correct dictation instead of fixing it.
    /// Lowercase; matching against it is case-insensitive.
    public static let homophoneStopList: Set<String> = [
        "there", "their", "they're", "to", "too", "two", "its", "it's",
        "your", "you're", "then", "than", "affect", "effect", "were",
        "where", "we're", "hear", "here",
    ]

    /// Applies `pairs` to `text` in order, whole-word (`\b`-bounded) and
    /// case-preserving: a lowercase `wrong` matches "word", "Word", and
    /// "WORD" occurrences alike, replacing each with `right` reshaped to
    /// the same case pattern. Only single-word pairs are applied; a pair
    /// whose `wrong` is on `homophoneStopList` is skipped even if it was
    /// recorded. Returns the rewritten text and a human-readable list of
    /// the pairs that actually fired, each formatted "wrong → right".
    public static func apply(_ pairs: [(wrong: String, right: String)], to text: String) -> (text: String, applied: [String]) {
        var result = text
        var applied: [String] = []

        for pair in pairs {
            guard !pair.wrong.contains(where: \.isWhitespace),
                  !pair.right.contains(where: \.isWhitespace) else { continue }
            guard !homophoneStopList.contains(pair.wrong.lowercased()) else { continue }

            let escaped = NSRegularExpression.escapedPattern(for: pair.wrong)
            guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [.caseInsensitive]) else {
                continue
            }

            let nsText = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsText.length))
            guard !matches.isEmpty else { continue }

            var output = ""
            var lastIndex = 0
            for match in matches {
                output += nsText.substring(with: NSRange(location: lastIndex, length: match.range.location - lastIndex))
                let matchedText = nsText.substring(with: match.range)
                output += reshape(pair.right, like: matchedText)
                lastIndex = match.range.location + match.range.length
            }
            output += nsText.substring(from: lastIndex)

            result = output
            applied.append("\(pair.wrong) → \(pair.right)")
        }

        return (result, applied)
    }

    /// Reshapes `word` to match the letter-case pattern of `like`:
    /// ALL-CAPS → ALL-CAPS, Capitalized → Capitalized, anything else →
    /// lowercase.
    private static func reshape(_ word: String, like: String) -> String {
        let lower = word.lowercased()
        if like == like.uppercased(), like != like.lowercased() {
            return lower.uppercased()
        } else if let first = like.first, first.isUppercase {
            return lower.prefix(1).uppercased() + lower.dropFirst()
        } else {
            return lower
        }
    }
}
