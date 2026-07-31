import Foundation

public enum MeetingProcessingStage: String, Sendable {
    case transcribingMic, transcribingSystem, identifyingSpeakers
    case summarizing, enhancingNotes, done

    public var label: String {
        switch self {
        case .transcribingMic: return "Transcribing your audio…"
        case .transcribingSystem: return "Transcribing the other participants…"
        case .identifyingSpeakers: return "Identifying speakers…"
        case .summarizing: return "Writing the summary…"
        case .enhancingNotes: return "Tidying up your notes…"
        case .done: return "Done"
        }
    }
}

public struct MeetingProgress: Sendable, Equatable {
    public let stage: MeetingProcessingStage
    public let fraction: Double

    public init(stage: MeetingProcessingStage, fraction: Double) {
        self.stage = stage
        self.fraction = fraction
    }
}

/// Turns a finished recording into a transcript, a summary, action items and
/// decisions, saving after every stage so a crash never loses more than the
/// stage in flight. Every checkpoint folds whatever transcript has been
/// produced so far into `meeting.segments` before it upserts — a cancel or a
/// crash right after the mic stage still persists the mic transcript, not an
/// empty one.
///
/// Degradation is the design: a missing track, a failed diarization, or an
/// empty summary all yield `.partial` rather than nothing. Only losing every
/// transcript yields `.failed` — and even then the meeting row is saved, so
/// the user sees what happened instead of a vanished recording.
///
/// A track that exists but transcribes to nothing (silence on the system
/// track, say) is NOT degradation — it's a legitimate, complete result.
/// Degradation is tracked from track *absence*, a thrown diarization error,
/// or an empty summary; never from a present track's honestly-empty output.
///
/// One run at a time per instance: `cancelled` and `warmUpTask` are single
/// actor-level fields, and nothing about them is meaningful if two `process`
/// calls interleave — a `cancel()` aimed at one run could otherwise be
/// cleared by another run's completion before the intended run ever
/// observed it. `process` therefore rejects an overlapping call outright
/// (returning `nil`, the same signal an unknown meeting ID produces) rather
/// than letting two runs share this state.
public actor MeetingPipeline {
    private static let micWeight = 0.30
    private static let systemWeight = 0.35
    private static let diarizeWeight = 0.20
    private static let summaryWeight = 0.15

    private let store: MeetingStore
    private let audioStore: MeetingAudioStore
    private let transcriber: any MeetingSegmentTranscribing
    private let diarizer: any MeetingDiarizing
    private let generator: any MeetingTextGenerating
    private let loadSamples: @Sendable (URL) throws -> [Float]
    private var cancelled = false
    private var isProcessing = false
    /// Handle on the diarizer's pre-warm, so `cancel()` — and every exit path
    /// of `process`, not just an explicit cancel — can end its lifetime
    /// rather than let a model download outlive the run that started it.
    private var warmUpTask: Task<Void, Never>?

    public init(store: MeetingStore,
                audioStore: MeetingAudioStore,
                transcriber: any MeetingSegmentTranscribing,
                diarizer: any MeetingDiarizing,
                generator: any MeetingTextGenerating,
                loadSamples: @escaping @Sendable (URL) throws -> [Float]
                    = { try AudioFileImporter.loadSamples(url: $0) }) {
        self.store = store
        self.audioStore = audioStore
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.generator = generator
        self.loadSamples = loadSamples
    }

    public func cancel() {
        cancelled = true
        warmUpTask?.cancel()
    }

    public func process(meetingID: UUID,
                        progress: (@Sendable (MeetingProgress) -> Void)?) async -> Meeting? {
        // Reject an overlapping call outright rather than letting two runs
        // share `cancelled`/`warmUpTask`. Actors are reentrant at suspension
        // points, so a second `process()` call can otherwise begin executing
        // while a first is awaiting mid-pipeline. Checked and set
        // synchronously here, before the first `await`, so there is no
        // window where two calls both observe `false` and both proceed.
        guard !isProcessing else {
            WisprLog.log("meeting pipeline: process() already running, "
                + "ignoring overlapping call for \(meetingID)")
            return nil
        }
        isProcessing = true
        // `cancelled` and `warmUpTask` only ever mean "for THIS run". Without
        // resetting them here, one `cancel()` call would permanently brick
        // the instance: the pipeline holds long-lived injected dependencies,
        // so a caller is expected to keep one instance around across
        // meetings, and every later meeting would abort at the first
        // checkpoint and silently persist `.partial` forever after.
        // Scheduling the reset now, rather than as the first statement in
        // this function, matters: a caller may legitimately call `cancel()`
        // moments before `process()` even starts (there is no
        // "already running" requirement for cancellation to apply), and that
        // pending intent must still stop THIS run. `defer` fires once this
        // call is actually finished — cancelled, failed, or complete — on
        // every exit path, which is also what closes the pre-warm task's
        // leak: even a task created after a `cancel()` already landed (in the
        // window between that `await` and this run's next checkpoint) is
        // still cancelled here before this call returns, rather than running
        // to completion unobserved in the background.
        defer {
            isProcessing = false
            cancelled = false
            warmUpTask?.cancel()
            warmUpTask = nil
        }

        guard var meeting = await store.meeting(id: meetingID) else {
            WisprLog.log("meeting pipeline: unknown meeting \(meetingID)")
            return nil
        }

        // Bail out before touching anything else if NEITHER track exists —
        // reachable on `reprocess`/`enhanceNotes`-adjacent reruns for a
        // meeting whose audio has since been evicted by retention, or whose
        // recording produced no files at all (both tracks failed to
        // capture). A review found that letting this fall through to the
        // per-checkpoint upserts below was a data-loss bug: with both tracks
        // absent, `micSegments`/`systemSegments` are `[]`, so the first
        // checkpoint's `meeting.segments = TranscriptMerger.merge(mic: [],
        // system: [], diarization: [])` unconditionally OVERWROTE whatever
        // transcript a PRIOR successful run had produced — an empty result
        // here means "nothing to work from", not "the transcript is now
        // empty". Checked before `meeting.status = .processing` even lands,
        // so this early return touches nothing about `meeting` except
        // `status`; `segments`, `summary`, `actionItems`, and `decisions`
        // all survive untouched.
        let hasMicTrack = await audioStore.existingMicURL(for: meetingID) != nil
        let hasSystemTrack = await audioStore.existingSystemURL(for: meetingID) != nil
        guard hasMicTrack || hasSystemTrack else {
            WisprLog.log("meeting pipeline: no audio tracks for \(meetingID), "
                + "leaving any prior transcript/summary intact")
            // N5 (round 2): only downgrade to `.failed` when there is truly
            // nothing to show — a meeting that already has a prior
            // transcript/summary (this is a reprocess whose audio has since
            // been evicted) is exactly as good as it was before this
            // attempt; nothing about its content changed, so reporting
            // `.failed` here told the user their intact, already-successful
            // meeting had just failed. A review found this reachable
            // through the UI even with Reprocess gated on audio existing
            // (C2's own fix): `MeetingDetailView` resolves
            // `model.audioURLs` once per selection, so retention evicting a
            // meeting's audio while its detail view stays open leaves the
            // button enabled — one click then turned a `.complete` meeting
            // with an intact transcript into `.failed`. A brand-new
            // meeting whose recording genuinely produced nothing (both
            // `segments` and `summary` still empty) still correctly reports
            // `.failed` here.
            if meeting.segments.isEmpty && meeting.summary.isEmpty {
                meeting.status = .failed
            }
            meeting = await checkpoint(meeting)
            progress?(MeetingProgress(stage: .done, fraction: 1.0))
            return meeting
        }

        meeting.status = .processing
        meeting = await checkpoint(meeting)

        // `FluidAudioDiarizer.diarize()` calls `warmUp()` unconditionally on
        // its own call path, and a fresh install has never warmed it before
        // now — so the first-ever diarization can trigger an inline model
        // download right at the "Identifying speakers…" stage, exactly when
        // the user is watching the last steps tick by. There is no earlier
        // hook available to THIS pipeline: processing only ever starts once
        // a recording has already finished, so meeting-end IS the earliest
        // point this actor can act. Kicking the warm-up off here, concurrent
        // with mic+system transcription (0.65 of the total weight, and
        // typically much slower than a model fetch), gives the download a
        // real head start instead of sitting serially in front of
        // diarization. Reached through the `MeetingDiarizing` protocol's
        // `warmUp()` (a no-op default for every stub) rather than a downcast
        // to `FluidAudioDiarizer` — the abstraction that keeps FluidAudio
        // confined to one implementation stays intact, and the task is
        // owned so `cancel()` can end it rather than let a download outlive
        // this pipeline. `try?` keeps it fire-and-forget either way:
        // `diarize()`'s own inline `warmUp()` call still runs regardless of
        // how this races, and the existing fail-open behaviour — a
        // diarization failure degrades to unattributed speakers, never fails
        // the meeting — is unchanged.
        let diarizer = self.diarizer
        warmUpTask?.cancel()
        warmUpTask = Task { try? await diarizer.warmUp() }

        var degraded = false
        var completed = 0.0

        // Mic track — the local user, no diarization needed.
        var micSegments: [MeetingTranscriptSegment] = []
        if let url = await audioStore.existingMicURL(for: meetingID) {
            micSegments = await transcribe(url: url, stage: .transcribingMic,
                                           weight: Self.micWeight, base: completed,
                                           progress: progress)
        } else {
            degraded = true
        }
        completed += Self.micWeight
        meeting.segments = TranscriptMerger.merge(mic: micSegments, system: [], diarization: [])
        meeting = await checkpoint(meeting)
        progress?(MeetingProgress(stage: .transcribingMic, fraction: completed))
        guard !cancelled else { return await savePartial(meeting) }

        // System track — everyone else.
        var systemSegments: [MeetingTranscriptSegment] = []
        var systemSamples: [Float] = []
        if let url = await audioStore.existingSystemURL(for: meetingID) {
            systemSamples = (try? loadSamples(url)) ?? []
            systemSegments = await transcribe(samples: systemSamples,
                                              stage: .transcribingSystem,
                                              weight: Self.systemWeight, base: completed,
                                              progress: progress)
        } else {
            degraded = true
        }
        completed += Self.systemWeight
        // No diarization spans yet, so every system-track segment attributes
        // to `.others` — the same fail-open value a diarization failure
        // produces, never a fabricated attribution — until the diarization
        // checkpoint below recomputes this with real spans.
        meeting.segments = TranscriptMerger.merge(
            mic: micSegments, system: systemSegments, diarization: [])
        meeting = await checkpoint(meeting)
        progress?(MeetingProgress(stage: .transcribingSystem, fraction: completed))
        guard !cancelled else { return await savePartial(meeting) }

        guard !(micSegments.isEmpty && systemSegments.isEmpty) else {
            WisprLog.log("meeting pipeline: no transcript from either track")
            meeting.status = .failed
            meeting.segments = []
            meeting = await checkpoint(meeting)
            progress?(MeetingProgress(stage: .done, fraction: 1.0))
            return meeting
        }

        // Diarization — system track only; the mic track is the user.
        // Reported at stage-start too (not just after it finishes), so a
        // slow model download or the diarization call itself shows the
        // correct "Identifying speakers…" label rather than leaving the
        // previous stage's label stale while the pipeline is silently
        // blocked.
        var spans: [DiarizedSpan] = []
        progress?(MeetingProgress(stage: .identifyingSpeakers, fraction: completed))
        if !systemSamples.isEmpty {
            let diarizeBase = completed
            do {
                spans = try await diarizer.diarize(samples: systemSamples, progress: { fraction in
                    progress?(MeetingProgress(stage: .identifyingSpeakers,
                                              fraction: diarizeBase + Self.diarizeWeight * fraction))
                })
            } catch {
                WisprLog.log("meeting pipeline: diarization FAILED: \(error)")
                degraded = true
            }
        }
        completed += Self.diarizeWeight
        meeting.segments = TranscriptMerger.merge(
            mic: micSegments, system: systemSegments, diarization: spans)
        meeting.speakerEmbeddings = nil
        meeting = await checkpoint(meeting)
        progress?(MeetingProgress(stage: .identifyingSpeakers, fraction: completed))
        guard !cancelled else { return await savePartial(meeting) }

        // Summary, action items, decisions.
        let summary = await MeetingSummarizer.summarize(
            segments: meeting.segments, names: meeting.speakerNames,
            using: generator, progress: nil)
        if summary == .empty { degraded = true }
        meeting.summary = summary.summary
        meeting.actionItems = summary.actionItems
        meeting.decisions = summary.decisions
        completed += Self.summaryWeight
        progress?(MeetingProgress(stage: .summarizing, fraction: completed))

        meeting.status = degraded ? .partial : .complete
        meeting = await checkpoint(meeting)
        progress?(MeetingProgress(stage: .done, fraction: 1.0))
        return meeting
    }

    /// Rewrites the meeting's typed notes using the transcript. Separate from
    /// `process` because the notes arrive after the meeting, whenever the user
    /// finishes typing them.
    public func enhanceNotes(meetingID: UUID) async -> Meeting? {
        guard let meeting = await store.meeting(id: meetingID) else { return nil }
        let enhanced = await MeetingNotesEnhancer.enhance(
            notes: meeting.userNotes, segments: meeting.segments,
            names: meeting.speakerNames, using: generator)
        // Writes back `enhancedNotes` alone. A local generation takes long
        // enough that the user can keep typing into `userNotes`, or a
        // `process` run can land a transcript, while it is in flight; the
        // snapshot read above must not be written back over either.
        return await store.update(id: meetingID) { $0.enhancedNotes = enhanced }
    }

    // MARK: - Private

    /// Persists this run's progress through `MeetingStore.update`, which
    /// re-reads the row inside the store actor and applies only the fields a
    /// pipeline run owns.
    ///
    /// `process` reads the row once and holds that snapshot for the whole
    /// run. Writing it back wholesale at each stage destroyed anything the
    /// user changed meanwhile — notes, title, speaker names — because the
    /// pipeline is always the last writer. The merged row replaces the
    /// snapshot, so later stages see those edits too: the summary is
    /// generated with whatever speaker names are current, not the ones that
    /// existed when the run started.
    ///
    /// A meeting deleted mid-run yields nil from `update`; the snapshot is
    /// returned unchanged rather than re-inserted, so the row stays deleted.
    private func checkpoint(_ meeting: Meeting) async -> Meeting {
        let snapshot = meeting
        let merged = await store.update(id: snapshot.id) { row in
            row.status = snapshot.status
            row.segments = snapshot.segments
            row.summary = snapshot.summary
            row.actionItems = snapshot.actionItems
            row.decisions = snapshot.decisions
            row.speakerEmbeddings = snapshot.speakerEmbeddings
        }
        return merged ?? snapshot
    }

    private func transcribe(url: URL, stage: MeetingProcessingStage,
                            weight: Double, base: Double,
                            progress: (@Sendable (MeetingProgress) -> Void)?) async
        -> [MeetingTranscriptSegment] {
        guard let samples = try? loadSamples(url) else {
            WisprLog.log("meeting pipeline: could not load \(url.lastPathComponent)")
            return []
        }
        return await transcribe(samples: samples, stage: stage, weight: weight,
                                base: base, progress: progress)
    }

    private func transcribe(samples: [Float], stage: MeetingProcessingStage,
                            weight: Double, base: Double,
                            progress: (@Sendable (MeetingProgress) -> Void)?) async
        -> [MeetingTranscriptSegment] {
        guard !samples.isEmpty else { return [] }
        do {
            return try await MeetingTranscriber.transcribe(
                samples: samples, using: transcriber,
                progress: { fraction in
                    progress?(MeetingProgress(stage: stage,
                                              fraction: base + weight * fraction))
                })
        } catch {
            WisprLog.log("meeting pipeline: \(stage.rawValue) FAILED: \(error)")
            return []
        }
    }

    private func savePartial(_ meeting: Meeting) async -> Meeting {
        var partial = meeting
        partial.status = .partial
        return await checkpoint(partial)
    }
}
