import Foundation

/// The audio a pipeline run reads from. `AudioFileReader` conforms; the
/// protocol exists so the pipeline is testable without a real file on disk.
public protocol AudioChunkProviding: Sendable {
    var sampleCount: Int { get }
    func samples(in range: Range<Int>) async throws -> [Float]
}

extension AudioFileReader: AudioChunkProviding {}

/// Thread-safe tally of the chunks a run lost, so `MeetingTranscriber`'s
/// @Sendable failure callback can report them without capturing a mutable
/// local (which won't compile under Swift concurrency checking).
final class ChunkFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Turns an uploaded file into a stored transcript, then generates documents
/// from it on demand.
///
/// Degradation is the design, exactly as in `MeetingPipeline`: a failed
/// diarization, a failed chunk, or an empty output yields `.partial` rather
/// than nothing. Only losing every chunk yields `.failed` — and even then the
/// row is SAVED, never deleted. A user must not lose a two-hour
/// transcription to a vanished row.
///
/// Every write goes through `TranscriptionJobStore.update(id:)`, never
/// `job(id:)` + `upsert(_:)`. A two-hour run holds no snapshot across its
/// awaits, so a rename made while it ran survives.
public enum TranscriptionPipeline {
    public static func transcribe(jobID: UUID,
                                  audio: any AudioChunkProviding,
                                  diarize: Bool,
                                  language: String? = nil,
                                  transcriber: any MeetingSegmentTranscribing,
                                  diarizer: (any MeetingDiarizing)?,
                                  store: TranscriptionJobStore,
                                  progress: (@Sendable (TranscriptionProgress) -> Void)?) async {
        guard let job = await store.job(id: jobID) else {
            // Deleted while queued. Do not resurrect it — and do not spend
            // hours transcribing for a row that no longer exists either.
            WisprLog.log("transcription pipeline: job \(jobID) no longer exists")
            return
        }

        let wantsDiarization = diarize && diarizer != nil
            && DiarizationGate.available(durationSeconds: job.durationSeconds)
        var degraded = false
        var notes: [String] = []

        // MARK: Diarize
        //
        // Whole-file, before transcription: speaker ids are assigned per call,
        // so a per-chunk pass would rename everybody at every boundary.
        // `DiarizationGate` is what keeps that whole-file `[Float]` bounded.
        var spans: [DiarizedSpan] = []
        if wantsDiarization, let diarizer {
            progress?(TranscriptionProgress.make(
                stage: .diarizing, stageFraction: 0, diarizationEnabled: true))
            do {
                let whole = try await audio.samples(in: 0..<audio.sampleCount)
                spans = try await diarizer.diarize(samples: whole, progress: { fraction in
                    progress?(TranscriptionProgress.make(
                        stage: .diarizing, stageFraction: fraction,
                        diarizationEnabled: true))
                })
            } catch {
                // Degrade: the transcript is the valuable part and it survives.
                WisprLog.log("transcription pipeline: diarization FAILED: \(error)")
                degraded = true
                notes.append("Speakers could not be identified.")
            }
            progress?(TranscriptionProgress.make(
                stage: .diarizing, stageFraction: 1, diarizationEnabled: true))
        } else if diarize {
            degraded = true
            notes.append(DiarizationGate.unavailableReason(
                durationSeconds: job.durationSeconds) ?? "Speakers were not identified.")
        }

        // MARK: Transcribe
        let enabled = wantsDiarization
        let lostChunks = ChunkFailureCounter()
        let totalChunks = MeetingTranscriber.chunkRanges(
            sampleCount: audio.sampleCount).count
        let segments: [MeetingTranscriptSegment]
        do {
            segments = try await MeetingTranscriber.transcribe(
                sampleCount: audio.sampleCount,
                chunkProvider: { range in try await audio.samples(in: range) },
                language: language,
                using: transcriber,
                progress: { fraction in
                    progress?(TranscriptionProgress.make(
                        stage: .transcribing, stageFraction: fraction,
                        diarizationEnabled: enabled))
                },
                onChunkFailure: { _ in lostChunks.increment() })
        } catch {
            // Only thrown when every attempted chunk failed: there is no
            // transcript at all. The row is UPDATED, never deleted — a user
            // must be able to see that their two-hour upload failed rather
            // than find it gone.
            WisprLog.log("transcription pipeline: transcription FAILED: \(error)")
            await store.update(id: jobID) {
                $0.status = .failed
                $0.failureNote = "This recording could not be transcribed."
            }
            progress?(TranscriptionProgress(stage: .done, fraction: 1))
            return
        }

        let attributed = spans.isEmpty ? segments : segments.map { segment in
            MeetingTranscriptSegment(
                id: segment.id,
                speaker: TranscriptMerger.attribute(segment: segment, spans: spans),
                start: segment.start, end: segment.end, text: segment.text)
        }

        // `MeetingTranscriber` BREAKS on cancellation and returns what it had,
        // so a run cancelled before the first chunk finished is empty — which
        // by return value alone is indistinguishable from silence. Only
        // `Task.isCancelled` separates the two, and telling a user their audio
        // had no speech when they cancelled it is a lie about their recording.
        let cancelled = Task.isCancelled
        // A run that lost chunks is NOT complete, whatever else went right.
        // The transcript has a hole in it and the user is the only one who
        // can decide what to do about that — but only if they are told.
        let lost = lostChunks.count
        if lost > 0 {
            degraded = true
            notes.append("\(lost) of \(totalChunks) parts of this recording "
                + "could not be transcribed.")
        }
        let note = notes.joined(separator: " ")
        let wasDegraded = degraded
        await store.update(id: jobID) { row in
            row.segments = attributed
            row.status = cancelled || wasDegraded || attributed.isEmpty ? .partial : .complete
            if cancelled {
                row.failureNote = "Cancelled — this is the part that finished."
            } else if attributed.isEmpty {
                row.failureNote = "No speech was found in this recording."
            } else if !note.isEmpty {
                row.failureNote = note
            }
        }
        progress?(TranscriptionProgress(stage: .done, fraction: 1))
    }

    /// Generates one document and caches it on the job. Summary and Report
    /// share `mapNotes`, computed once and reused thereafter; Chapters runs
    /// its own single call over a timestamped render, which the condensed
    /// notes cannot supply.
    ///
    /// Every generator fails closed to an EMPTY document, and an empty
    /// document is never written over a stored one. Regenerating is a normal
    /// thing to do — the user tries a bigger model, or asks for a Summary
    /// which shares the map pass with the Report they already have — and a
    /// model that fails halfway through must not take the good document with
    /// it. Nothing here can be recovered by re-running: the audio may be
    /// hours long and the model may fail again.
    public static func generate(kind: TranscriptOutputKind,
                                jobID: UUID,
                                store: TranscriptionJobStore,
                                using generator: any MeetingTextGenerating,
                                progress: (@Sendable (Double) -> Void)?) async {
        guard let job = await store.job(id: jobID), !job.segments.isEmpty else { return }

        switch kind {
        case .cleanTranscript:
            let cleaned = await TranscriptOutputGenerator.cleanTranscript(
                segments: job.segments, names: job.speakerNames,
                using: generator, progress: progress)
            if !cleaned.isEmpty {
                await store.update(id: jobID) { $0.cleanTranscript = cleaned }
            }

        case .summary:
            let notes = await cachedNotes(job: job, store: store,
                                          using: generator, progress: progress)
            let output = await MeetingSummarizer.reduce(
                notes: notes,
                transcript: TranscriptOutputPrompt.render(
                    job.segments, names: job.speakerNames),
                using: generator)
            let produced = !output.summary.isEmpty || !output.actionItems.isEmpty
                || !output.decisions.isEmpty
            if produced {
                await store.update(id: jobID) {
                    $0.summary = output.summary
                    $0.actionItems = output.actionItems
                    $0.decisions = output.decisions
                }
            }
            progress?(1.0)

        case .report:
            let notes = await cachedNotes(job: job, store: store,
                                          using: generator, progress: progress)
            let report = await TranscriptOutputGenerator.report(
                notes: notes,
                transcript: TranscriptOutputPrompt.render(
                    job.segments, names: job.speakerNames),
                using: generator)
            if !report.isEmpty {
                await store.update(id: jobID) { $0.report = report }
            }
            progress?(1.0)

        case .chapters:
            let chapters = await TranscriptOutputGenerator.chapters(
                segments: job.segments, names: job.speakerNames,
                duration: job.durationSeconds, using: generator)
            if !chapters.isEmpty {
                await store.update(id: jobID) { $0.chapters = chapters }
            }
            progress?(1.0)
        }
    }

    /// The shared map pass: reused when already computed, so the expensive
    /// condensation runs once for Summary and Report rather than once each.
    private static func cachedNotes(job: TranscriptionJob,
                                    store: TranscriptionJobStore,
                                    using generator: any MeetingTextGenerating,
                                    progress: (@Sendable (Double) -> Void)?) async -> [String] {
        if !job.mapNotes.isEmpty { return job.mapNotes }
        let notes = await TranscriptOutputGenerator.mapNotes(
            segments: job.segments, names: job.speakerNames,
            using: generator, progress: progress)
        await store.update(id: job.id) { $0.mapNotes = notes }
        return notes
    }
}
