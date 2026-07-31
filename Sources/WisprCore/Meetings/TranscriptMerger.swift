import Foundation

/// Combines the two independently-transcribed tracks of a meeting into one
/// ordered, speaker-attributed transcript.
///
/// Pure logic, no I/O, no models — which is why it carries the heaviest test
/// coverage in the Meetings subsystem.
public enum TranscriptMerger {
    /// Attributes one system-track segment to a diarized speaker by greatest
    /// temporal overlap. No overlap at all yields `.others`, so a diarization
    /// failure degrades the transcript rather than breaking it.
    public static func attribute(segment: MeetingTranscriptSegment,
                                 spans: [DiarizedSpan]) -> MeetingSpeaker {
        var best: (span: DiarizedSpan, overlap: TimeInterval)?
        for span in spans {
            let overlap = max(0, min(segment.end, span.end) - max(segment.start, span.start))
            guard overlap > 0 else { continue }
            if let current = best {
                // On a tie, prefer the span with the earlier start regardless
                // of input order — callers may pass spans unsorted.
                if overlap > current.overlap
                    || (overlap == current.overlap && span.start < current.span.start) {
                    best = (span, overlap)
                }
            } else {
                best = (span, overlap)
            }
        }
        guard let best else { return .others }
        return .remote(best.span.speakerID)
    }

    public static func merge(mic: [MeetingTranscriptSegment],
                             system: [MeetingTranscriptSegment],
                             diarization: [DiarizedSpan],
                             coalesceGap: TimeInterval = 1.5) -> [MeetingTranscriptSegment] {
        let spans = diarization.sorted { $0.start < $1.start }

        let micSegments = mic
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map {
                MeetingTranscriptSegment(id: $0.id, speaker: .you,
                                         start: $0.start, end: $0.end, text: $0.text)
            }

        let systemSegments = system
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map {
                MeetingTranscriptSegment(id: $0.id,
                                         speaker: attribute(segment: $0, spans: spans),
                                         start: $0.start, end: $0.end, text: $0.text)
            }

        // Equal starts order mic-first: tag the origin, sort, drop the tag.
        let tagged = micSegments.map { (segment: $0, isMic: true) }
            + systemSegments.map { (segment: $0, isMic: false) }
        let ordered = tagged.sorted {
            if $0.segment.start != $1.segment.start {
                return $0.segment.start < $1.segment.start
            }
            return $0.isMic && !$1.isMic
        }.map(\.segment)

        return coalesce(ordered, gap: coalesceGap)
    }

    /// Joins runs of same-speaker segments separated by less than `gap`, which
    /// turns a stutter of Whisper fragments into readable paragraphs.
    private static func coalesce(_ segments: [MeetingTranscriptSegment],
                                 gap: TimeInterval) -> [MeetingTranscriptSegment] {
        var result: [MeetingTranscriptSegment] = []
        for segment in segments {
            guard let previous = result.last,
                  previous.speaker == segment.speaker,
                  segment.start - previous.end < gap else {
                result.append(segment)
                continue
            }
            // Trim both sides before joining: Whisper hands back segments with a
            // leading space, so a naive join double-spaces every seam.
            let joined = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
                + " " + segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            result[result.count - 1] = MeetingTranscriptSegment(
                id: previous.id,
                speaker: previous.speaker,
                start: previous.start,
                end: segment.end,
                text: joined)
        }
        return result
    }
}
