import Foundation

/// Pure formatting for the Meetings UI and the copy-to-clipboard export.
/// Separated from the views so it is testable.
public enum MeetingFormatting {
    /// "0:07", "10:05", "1:02:33". Non-finite input (a segment timestamp
    /// that never got a real value) clamps to zero rather than trapping —
    /// `Int(.infinity)` is a fatal error, and Task 13 already shipped that
    /// crash once from an unguarded conversion here.
    public static func timestamp(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Whether `draft` has diverged from `savedUserNotes` — the last value
    /// actually persisted via `MeetingsViewModel.saveNotes`. The notes
    /// `TextEditor` has no autosave, so when this is true, `draft` is the
    /// only place unsaved typing exists; a caller about to replace it
    /// wholesale (e.g. "Use this" on the tidied notes) must confirm first
    /// rather than silently discard it.
    public static func hasUnsavedNotes(draft: String, savedUserNotes: String) -> Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
            != savedUserNotes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Distinct diarization speaker ids in first-appearance order, so the
    /// rename fields appear in the order the user hears the voices.
    public static func speakerIDs(in meeting: Meeting) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for segment in meeting.segments {
            guard case .remote(let id) = segment.speaker, !seen.contains(id) else { continue }
            seen.insert(id)
            ordered.append(id)
        }
        return ordered
    }

    /// The whole meeting as one Markdown document, for Copy as Markdown.
    /// Empty sections are omitted; Summary always appears (falling back to
    /// a placeholder line) so the document never reads as truncated.
    public static func markdown(_ meeting: Meeting) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        var parts: [String] = []
        parts.append("# \(meeting.title)")
        parts.append("\(formatter.string(from: meeting.startedAt)) · "
                     + timestamp(meeting.durationSeconds))

        parts.append("## Summary\n"
                     + (meeting.summary.isEmpty ? "No summary available." : meeting.summary))

        if !meeting.actionItems.isEmpty {
            parts.append("## Action items\n"
                         + meeting.actionItems.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !meeting.decisions.isEmpty {
            parts.append("## Decisions\n"
                         + meeting.decisions.map { "- \($0)" }.joined(separator: "\n"))
        }

        let notes = meeting.enhancedNotes.isEmpty ? meeting.userNotes : meeting.enhancedNotes
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("## Notes\n\(notes)")
        }

        if !meeting.segments.isEmpty {
            let lines = meeting.segments.map { segment in
                "[\(timestamp(segment.start))] "
                    + "\(meeting.displayName(for: segment.speaker)): \(segment.text)"
            }
            parts.append("## Transcript\n" + lines.joined(separator: "\n"))
        }

        return parts.joined(separator: "\n\n")
    }
}
