import Foundation

/// Timestamped transcription, abstracted so the chunking and stitching logic
/// is testable without loading a Whisper model.
public protocol MeetingSegmentTranscribing: Sendable {
    func transcribeSegments(samples: [Float], language: String?,
                            progress: (@Sendable (Double) -> Void)?) async throws
        -> [MeetingTranscriptSegment]
}

/// Transcribes one meeting track: splits long audio into overlapping chunks,
/// transcribes each, shifts the timestamps back into meeting time, and
/// removes the duplicated words at each seam.
///
/// Meetings always transcribe with free language detection (`language: nil`),
/// ignoring the dictation language pin, because a meeting may be
/// multilingual.
public enum MeetingTranscriber {
    /// 10 minutes per chunk bounds peak memory at ~38 MB of Float per chunk
    /// and gives progress roughly every couple of minutes of wall clock.
    public static let defaultChunkSeconds: Double = 600
    /// 2 seconds of overlap so a word straddling a boundary is transcribed
    /// whole in at least one chunk.
    public static let defaultOverlapSeconds: Double = 2

    public static func chunkRanges(sampleCount: Int,
                                   chunkSeconds: Double = defaultChunkSeconds,
                                   overlapSeconds: Double = defaultOverlapSeconds)
        -> [Range<Int>] {
        guard sampleCount > 0 else { return [] }
        let rate = AudioResampler.targetSampleRate
        let chunk = Int(chunkSeconds * rate)
        // `start = end - overlap` must strictly advance every iteration, or an
        // overlap at or beyond the chunk length loops forever. Unreachable
        // from today's only call site (always the defaults), but this is a
        // public function with defaulted parameters, so clamp defensively
        // rather than trust every future caller to pass a sane pair.
        let safeOverlapSeconds = overlapSeconds >= chunkSeconds
            ? chunkSeconds / 2 : max(0, overlapSeconds)
        let overlap = Int(safeOverlapSeconds * rate)
        guard sampleCount > chunk else { return [0..<sampleCount] }

        var ranges: [Range<Int>] = []
        var start = 0
        while start < sampleCount {
            let end = min(start + chunk, sampleCount)
            // A trailing chunk that would fall entirely within (or barely
            // past) the previous chunk's overlap contributes little to no
            // new audio — e.g. an input that's an exact multiple of `chunk`
            // produces a final chunk only `2 * overlap` long. Folding it
            // into the previous chunk avoids an extra, near-empty
            // transcription call for no real coverage gain.
            if end == sampleCount, let previous = ranges.last, sampleCount - start <= 2 * overlap {
                ranges[ranges.count - 1] = previous.lowerBound..<sampleCount
                break
            }
            ranges.append(start..<end)
            if end == sampleCount { break }
            start = end - overlap
        }
        return ranges
    }

    public static func offsetSegments(_ segments: [MeetingTranscriptSegment],
                                      by offset: TimeInterval) -> [MeetingTranscriptSegment] {
        guard offset != 0 else { return segments }
        return segments.map {
            MeetingTranscriptSegment(id: $0.id, speaker: $0.speaker,
                                     start: $0.start + offset, end: $0.end + offset,
                                     text: $0.text)
        }
    }

    /// Removes the seam duplicates chunk overlap creates. Only exact
    /// normalised repeats inside an overlap window are dropped — never a
    /// merely-overlapping segment with different words, which would silently
    /// delete speech.
    public static func dedupeOverlap(_ segments: [MeetingTranscriptSegment],
                                     overlapTolerance: TimeInterval = 0.25)
        -> [MeetingTranscriptSegment] {
        var result: [MeetingTranscriptSegment] = []
        for segment in segments {
            // Overlapping the previous segment, or close enough behind it that
            // the chunk seam could explain the gap. `overlapTolerance` widens
            // the window rather than narrowing it: a seam repeat often starts a
            // fraction of a second AFTER the previous segment ended.
            if let previous = result.last,
               segment.start <= previous.end + overlapTolerance,
               normalise(segment.text) == normalise(previous.text) {
                continue
            }
            result.append(segment)
        }
        return result
    }

    public static func transcribe(samples: [Float],
                                  using transcriber: any MeetingSegmentTranscribing,
                                  progress: (@Sendable (Double) -> Void)?) async throws
        -> [MeetingTranscriptSegment] {
        let ranges = chunkRanges(sampleCount: samples.count)
        guard !ranges.isEmpty else { return [] }

        var collected: [MeetingTranscriptSegment] = []
        var failures = 0
        var lastError: Error?
        for (index, range) in ranges.enumerated() {
            let offset = Double(range.lowerBound) / AudioResampler.targetSampleRate
            do {
                let chunk = Array(samples[range])
                let segments = try await transcriber.transcribeSegments(
                    samples: chunk, language: nil, progress: nil)
                let shifted = offsetSegments(segments, by: offset)
                if index == 0 {
                    // Nothing precedes the first chunk, so there is no seam
                    // to dedupe against — and nothing within one chunk's own
                    // output should ever be dropped as a "seam repeat": every
                    // segment here reflects real speech, however close together.
                    collected.append(contentsOf: shifted)
                } else {
                    appendAcrossSeam(shifted, chunkGlobalStart: offset, into: &collected)
                }
            } catch {
                // One bad chunk loses ten minutes, not the whole meeting.
                failures += 1
                lastError = error
                WisprLog.log("meeting transcribe: chunk \(index) FAILED: \(error)")
            }
            progress?(Double(index + 1) / Double(ranges.count))
        }
        guard failures < ranges.count else { throw lastError ?? WisprError.modelNotLoaded }
        return collected
    }

    /// Stitches one non-first chunk's already-offset segments onto `collected`.
    ///
    /// Only the FIRST segment of the new chunk is ever a dedupe candidate,
    /// and only when its (meeting-global) start still falls inside this
    /// chunk's overlap window — i.e. a chunk seam could plausibly have
    /// produced it. Every other segment, in this chunk or any other, is
    /// appended unconditionally. This is deliberately narrower than running
    /// `dedupeOverlap` over the whole timeline: a back-to-back repeated
    /// utterance spoken well inside a single chunk (never crossing a seam)
    /// must never be collapsed, because that would delete real speech.
    private static func appendAcrossSeam(_ chunkSegments: [MeetingTranscriptSegment],
                                         chunkGlobalStart: TimeInterval,
                                         overlapSeconds: Double = defaultOverlapSeconds,
                                         into collected: inout [MeetingTranscriptSegment]) {
        var segments = chunkSegments
        if let previous = collected.last, let first = segments.first,
           first.start < chunkGlobalStart + overlapSeconds,
           dedupeOverlap([previous, first]).count == 1 {
            segments.removeFirst()
        }
        collected.append(contentsOf: segments)
    }

    private static func normalise(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
