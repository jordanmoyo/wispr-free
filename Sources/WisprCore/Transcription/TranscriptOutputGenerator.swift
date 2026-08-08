import Foundation

/// Generates the documents a user asks for from a finished transcript.
///
/// Summary and Report both reduce from ONE shared map pass (`mapNotes`),
/// cached on the job, so the expensive condensation runs once for the two of
/// them rather than twice. Chapters does not use it and does not need it:
/// chapter titles need timestamps the condensed notes no longer carry, so it
/// makes a single call over a thinned timestamped render instead.
///
/// Every path fails closed. A generation that throws, or that produces
/// something implausible, yields an empty document or the untouched
/// transcript — never a fabricated one.
public enum TranscriptOutputGenerator {
    /// Condenses the transcript into factual bullets, one call per chunk.
    /// A failed chunk is skipped: losing some detail beats losing everything.
    public static func mapNotes(segments: [MeetingTranscriptSegment],
                                names: [String: String],
                                using generator: any MeetingTextGenerating,
                                progress: (@Sendable (Double) -> Void)?) async -> [String] {
        let transcript = TranscriptOutputPrompt.render(segments, names: names)
        let chunks = MeetingSummarizer.chunk(transcript)
        guard !chunks.isEmpty else {
            progress?(1.0)
            return []
        }

        var notes: [String] = []
        for (index, slice) in chunks.enumerated() {
            do {
                let bullets = try await generator.generate(
                    system: MeetingPrompt.mapSystem,
                    user: "Transcript excerpt:\n\n\(slice)",
                    maxTokens: MeetingPrompt.maxTokens(forTranscriptCharacters: slice.count))
                let cleaned = MeetingSummarizer.stripThinking(bullets)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { notes.append(cleaned) }
            } catch {
                WisprLog.log("transcript map: chunk \(index) FAILED: \(error)")
            }
            progress?(Double(index + 1) / Double(chunks.count))
        }
        return notes
    }

    /// Rewrites the transcript itself as readable prose. Every failure path
    /// returns the ORIGINAL rendered transcript, so the user always ends up
    /// with real words.
    public static func cleanTranscript(segments: [MeetingTranscriptSegment],
                                       names: [String: String],
                                       using generator: any MeetingTextGenerating,
                                       progress: (@Sendable (Double) -> Void)?) async -> String {
        let original = TranscriptOutputPrompt.render(segments, names: names)
        let chunks = MeetingSummarizer.chunk(original)
        guard !chunks.isEmpty else {
            progress?(1.0)
            return ""
        }

        var rewritten: [String] = []
        for (index, slice) in chunks.enumerated() {
            do {
                let raw = try await generator.generate(
                    system: TranscriptOutputPrompt.cleanSystem,
                    user: "Transcript excerpt:\n\n\(slice)",
                    maxTokens: MeetingPrompt.maxTokens(forTranscriptCharacters: slice.count))
                let cleaned = MeetingSummarizer.stripThinking(raw)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Per chunk, not just overall: one runaway chunk in the middle
                // of a two-hour transcript would otherwise hide inside a total
                // that still looks reasonable.
                guard TranscriptOutputPrompt.plausibleCleanTranscript(
                    original: slice, cleaned: cleaned) else {
                    WisprLog.log("clean transcript: chunk \(index) implausible, keeping original")
                    rewritten.append(slice)
                    progress?(Double(index + 1) / Double(chunks.count))
                    continue
                }
                rewritten.append(cleaned)
            } catch {
                WisprLog.log("clean transcript: chunk \(index) FAILED: \(error)")
                rewritten.append(slice)
            }
            progress?(Double(index + 1) / Double(chunks.count))
        }
        return rewritten.joined(separator: "\n\n")
    }

    /// The comprehensive report, reduced from the shared map notes.
    /// No notes means nothing to report on — empty, never invented.
    ///
    /// `transcript` is the rendered transcript the notes were condensed from.
    /// It is the haystack for the same fabricated-owner strip the Summary
    /// applies: `reportSystem` tells the model to name an owner "only when
    /// the notes state one" and small local models do it anyway. A report
    /// that assigns a real task to a person who was never in the recording is
    /// the exact failure this project has already seen live, and a report is
    /// the document most likely to be pasted into an email unread.
    public static func report(notes: [String],
                              transcript: String,
                              using generator: any MeetingTextGenerating) async -> String {
        guard !notes.isEmpty else { return "" }
        let combined = notes.joined(separator: "\n")
        do {
            let raw = try await generator.generate(
                system: TranscriptOutputPrompt.reportSystem,
                user: "Condensed notes:\n\n\(combined)",
                maxTokens: MeetingPrompt.maxTokens(forTranscriptCharacters: combined.count))
            let text = MeetingSummarizer.stripThinking(raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return strippingFabricatedOwners(in: text, transcript: transcript)
        } catch {
            WisprLog.log("transcript report: FAILED: \(error)")
            return ""
        }
    }

    /// Runs `MeetingSummarizer.stripFabricatedOwners` over the bullets of the
    /// report's "Action items" section, leaving every other line untouched.
    ///
    /// Scoped to that section on purpose: the spec asks for owners to be
    /// stripped from action items, and a bare "- " bullet elsewhere in the
    /// report ("- Pricing - it keeps coming up") is prose, not an
    /// attribution. Section state is tracked by heading, so an unrecognised
    /// heading ends the action-items section rather than extending it.
    static func strippingFabricatedOwners(in report: String,
                                          transcript: String) -> String {
        var inActionItems = false
        let lines = report.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        return lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                inActionItems = trimmed.lowercased().contains("action")
                return line
            }
            guard inActionItems else { return line }
            guard let marker = ["- ", "* "].first(where: trimmed.hasPrefix) else {
                return line
            }
            let body = String(trimmed.dropFirst(marker.count))
            let stripped = MeetingSummarizer.stripFabricatedOwners(
                [body], transcript: transcript)
            return marker + (stripped.first ?? body)
        }.joined(separator: "\n")
    }

    /// Timestamped chapters. Runs over the TIMESTAMPED render rather than the
    /// plain one, because the model must quote a timestamp it can see rather
    /// than calculate one — and `TranscriptChapters.parse` then drops anything
    /// it invented anyway.
    public static func chapters(segments: [MeetingTranscriptSegment],
                                names: [String: String],
                                duration: TimeInterval,
                                using generator: any MeetingTextGenerating) async
        -> [TranscriptChapter] {
        let transcript = TranscriptOutputPrompt.renderTimestamped(segments, names: names)
        guard !transcript.isEmpty else { return [] }
        // Thinned to one prompt's worth rather than chunked: chapter titles
        // need coverage of the WHOLE recording, and a chunked chapter pass
        // would restart numbering. `boundedTimestamped` keeps evenly spaced
        // lines across the entire timeline instead of just the opening.
        let reference = TranscriptOutputPrompt.boundedTimestamped(segments, names: names)
        do {
            let raw = try await generator.generate(
                system: TranscriptOutputPrompt.chapterSystem,
                user: "Timestamped transcript:\n\n\(reference)",
                maxTokens: 1_024)
            return TranscriptChapters.parse(raw, duration: duration)
        } catch {
            WisprLog.log("transcript chapters: FAILED: \(error)")
            return []
        }
    }
}
