import Foundation

/// Deterministic voice-directed formatting: turns spoken phrases like
/// "new paragraph" into literal line breaks. Runs after cleanup and
/// corrections, immediately before delivery, so it works even with
/// cleanup disabled.
public enum FormattingCommands {
    /// (spoken phrase, literal replacement) — order matters: longer/more
    /// specific phrases first so a shorter phrase never eats part of a
    /// longer one that shares a prefix.
    private static let phraseTable: [(phrase: String, replacement: String)] = [
        ("new paragraph", "\n\n"),
        ("nouveau paragraphe", "\n\n"),
        ("new line", "\n"),
        ("nouvelle ligne", "\n"),
        ("à la ligne", "\n"),
    ]

    /// One compiled regex per phrase, built once. Each matches the phrase
    /// plus up to one adjacent punctuation mark and surrounding spaces on
    /// either side, so "hello, new paragraph, world" swallows both commas.
    /// The `(?<![\p{L}])` / `(?![\p{L}])` lookarounds bind directly to the
    /// phrase text (not the outer whitespace-swallow), so a preceding or
    /// following letter — as in "renew paragraph" or "Newfoundland" —
    /// blocks the match. `\b` isn't used because it's ASCII-only by
    /// default in `NSRegularExpression` and wouldn't reliably bind around
    /// an accented letter like the "à" in "à la ligne".
    private static let compiledPhrases: [(regex: NSRegularExpression, replacement: String)] = {
        phraseTable.map { entry in
            let escaped = NSRegularExpression.escapedPattern(for: entry.phrase)
            let pattern = "[ ]*[,.;:]?[ ]*(?<![\\p{L}])\(escaped)(?![\\p{L}])[ ]*[,.;:]?[ ]*"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                fatalError("invalid FormattingCommands pattern for phrase: \(entry.phrase)")
            }
            return (regex, entry.replacement)
        }
    }()

    /// Replaces every recognized spoken formatting command with its literal
    /// break, then uppercases the first letter following each `\n\n` (a
    /// paragraph starts a new sentence; `\n` leaves case unchanged).
    public static func apply(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = text
        for (regex, replacement) in compiledPhrases {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
        }
        return uppercaseAfterParagraphBreaks(result)
    }

    /// Uppercases the first letter immediately following each `\n\n`.
    private static func uppercaseAfterParagraphBreaks(_ text: String) -> String {
        guard text.contains("\n\n") else { return text }

        var chars = Array(text)
        var index = 0
        while index < chars.count {
            if chars[index] == "\n", index + 1 < chars.count, chars[index + 1] == "\n" {
                var next = index + 2
                // Skip any further whitespace so "a\n\n  b" still uppercases "b".
                while next < chars.count, chars[next].isWhitespace {
                    next += 1
                }
                if next < chars.count {
                    let uppercased = chars[next].uppercased()
                    // A single character can uppercase to multiple graphemes
                    // (e.g. German "ß" → "SS"); `Character(String)` would
                    // trap on that, so only replace in place when it stays
                    // a single character, and leave rarer expansions as-is.
                    if uppercased.count == 1, let single = uppercased.first {
                        chars[next] = single
                    }
                }
                index = next
            } else {
                index += 1
            }
        }
        return String(chars)
    }
}

/// A voice-directed transform applied to the whole transcript, resolved by
/// an LLM call rather than a literal text replacement (see
/// `CleanupEngine.transform`, added in a later task).
public enum Directive: String, Sendable {
    case bulletList
    case email
}

/// Detects a trailing spoken directive ("...make this a bullet list") on
/// the raw transcript and strips it, leaving the content the directive
/// should apply to.
public enum DirectiveDetector {
    /// Spoken trigger phrases per directive, checked in order. Longer/more
    /// specific phrases first so a shorter phrase never wins over a longer
    /// one that shares a suffix.
    private static let directivePhrases: [(directive: Directive, phrases: [String])] = [
        (.bulletList, [
            "make this a bullet list",
            "make it a bullet list",
            "bullet list please",
            "fais une liste à puces",
            "en liste à puces",
        ]),
        (.email, [
            "draft this as an email",
            "draft an email from this",
            "make this an email",
            "transforme en e-mail",
            "rédige un e-mail",
        ]),
    ]

    /// One compiled regex per phrase: the phrase anchored to the end of
    /// the (trimmed) text, tolerating a leading comma/period and space
    /// before it and a trailing punctuation mark after it.
    private static let compiledPhrases: [(directive: Directive, regex: NSRegularExpression)] = {
        directivePhrases.flatMap { entry in
            entry.phrases.map { phrase -> (Directive, NSRegularExpression) in
                let escaped = NSRegularExpression.escapedPattern(for: phrase)
                let pattern = "[,.]?[ ]*(?<![\\p{L}])(?:\(escaped))[ ]*[,.!]?$"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                    fatalError("invalid DirectiveDetector pattern for phrase: \(phrase)")
                }
                return (entry.directive, regex)
            }
        }
    }()

    /// `nil` when no trailing directive phrase is found, or when stripping
    /// it leaves no content. Otherwise the matched directive and the
    /// trimmed remaining content.
    public static func detect(_ text: String) -> (directive: Directive, content: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for (directive, regex) in compiledPhrases {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
                  let matchRange = Range(match.range, in: trimmed) else { continue }

            let remaining = String(trimmed[trimmed.startIndex..<matchRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remaining.isEmpty else { return nil }
            return (directive, remaining)
        }
        return nil
    }
}
