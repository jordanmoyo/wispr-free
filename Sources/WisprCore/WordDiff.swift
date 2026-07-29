import Foundation

/// Extracts single-word wrong→right correction pairs from the difference
/// between two versions of the same dictation (e.g. the raw transcript and
/// the user's manually edited version, or the raw transcript and the
/// AI-cleaned version).
public enum WordDiff {
    /// Above this fraction of substituted tokens, the edit looks like a
    /// rewrite rather than a spot correction and no pairs are returned.
    private static let rewriteThreshold = 0.4

    /// LCS alignment on tokens (split on whitespace/newlines; leading and
    /// trailing punctuation is stripped for comparison, but the stripped
    /// form — not a lowercased one — is what gets returned). Only 1:1
    /// substitutions are returned: insertions, deletions, and multi-token
    /// splits/merges are dropped, since they can't be expressed as a single
    /// wrong→right word pair. Returns `[]` when the changed-token ratio
    /// exceeds 0.4 (a rewrite, not a correction) or when the inputs are
    /// equal. A pair that differs only by case or only by punctuation
    /// compares equal once stripped and lowercased, so it's treated as a
    /// match (not a substitution) and never appears in the result.
    public static func corrections(from original: String, to edited: String) -> [(wrong: String, right: String)] {
        let originalTokens = tokenize(original)
        let editedTokens = tokenize(edited)
        guard !originalTokens.isEmpty else { return [] }

        let matches = lcsMatches(originalTokens, editedTokens)

        var pairs: [(wrong: String, right: String)] = []
        var substitutionCount = 0

        func processRun(origRange: Range<Int>, editRange: Range<Int>) {
            let left = originalTokens[origRange]
            let right = editedTokens[editRange]
            // Only an equal-length, non-empty run is a run of 1:1
            // substitutions; anything else is an insertion, deletion, split,
            // or merge, none of which produce a usable word pair.
            guard !left.isEmpty, left.count == right.count else { return }
            substitutionCount += left.count
            for (wrongToken, rightToken) in zip(left, right) {
                let strippedWrong = stripPunctuation(wrongToken)
                let strippedRight = stripPunctuation(rightToken)
                guard !strippedWrong.isEmpty, !strippedRight.isEmpty else { continue }
                guard strippedWrong.lowercased() != strippedRight.lowercased() else { continue }
                pairs.append((wrong: strippedWrong, right: strippedRight))
            }
        }

        var prevOrig = 0
        var prevEdit = 0
        for (i, j) in matches {
            processRun(origRange: prevOrig..<i, editRange: prevEdit..<j)
            prevOrig = i + 1
            prevEdit = j + 1
        }
        processRun(origRange: prevOrig..<originalTokens.count, editRange: prevEdit..<editedTokens.count)

        let ratio = Double(substitutionCount) / Double(max(originalTokens.count, 1))
        guard ratio <= rewriteThreshold else { return [] }
        return pairs
    }

    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    private static func stripPunctuation(_ token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters)
    }

    private static func comparisonKey(_ token: String) -> String {
        stripPunctuation(token).lowercased()
    }

    /// Longest-common-subsequence alignment over `comparisonKey`, returning
    /// the matched `(indexInA, indexInB)` pairs in order.
    private static func lcsMatches(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count
        let m = b.count
        guard n > 0, m > 0 else { return [] }
        let keysA = a.map(comparisonKey)
        let keysB = b.map(comparisonKey)

        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if keysA[i] == keysB[j] {
                    dp[i][j] = dp[i + 1][j + 1] + 1
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var result: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if keysA[i] == keysB[j] {
                result.append((i, j))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }
}
