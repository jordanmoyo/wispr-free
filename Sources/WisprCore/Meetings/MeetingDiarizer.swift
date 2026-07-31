import Foundation

/// A stretch of audio attributed to one speaker by diarization.
public struct DiarizedSpan: Sendable, Equatable {
    public let speakerID: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(speakerID: String, start: TimeInterval, end: TimeInterval) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

/// Abstracts diarization so `TranscriptMerger` can be tested with a stub and
/// the FluidAudio dependency stays confined to one implementation.
public protocol MeetingDiarizing: Sendable {
    /// Prepares the diarizer ahead of `diarize()` — e.g. downloading and
    /// loading models — so a caller (the pipeline) can race it against other
    /// work instead of paying the cost inline at diarization time. Default is
    /// a no-op: only an implementation actually backed by a model needs to
    /// override it, and every stub keeps working unmodified.
    func warmUp() async throws
    func diarize(samples: [Float],
                 progress: (@Sendable (Double) -> Void)?) async throws -> [DiarizedSpan]
}

extension MeetingDiarizing {
    public func warmUp() async throws {}
}

import FluidAudio

public enum DiarizationError: Error, Equatable {
    case modelsUnavailable(String)
    case tooShort

    public var userMessage: String {
        switch self {
        case .tooShort:
            return "This recording is too short to identify separate speakers."
        case .modelsUnavailable:
            return "Wispr couldn't load the speaker-identification models, so "
                + "the transcript groups the other participants together. "
                + "Check your connection and reprocess to try again."
        }
    }
}

/// Diarization that always returns nothing. Used when the models are
/// unavailable: `TranscriptMerger` then attributes every system-track segment
/// to `.others`, which is a degraded transcript rather than a failed one.
public struct NullDiarizer: MeetingDiarizing {
    public init() {}

    public func diarize(samples: [Float],
                        progress: (@Sendable (Double) -> Void)?) async throws -> [DiarizedSpan] {
        []
    }
}

/// Speaker diarization via FluidAudio's pyannote-derived CoreML models.
///
/// Models are fetched from Hugging Face on first use into FluidAudio's own
/// cache, so the first meeting needs a network connection. Every failure
/// surfaces as `DiarizationError.modelsUnavailable` and the caller falls back
/// to `NullDiarizer` — diarization is an enhancement, never a requirement.
public actor FluidAudioDiarizer: MeetingDiarizing {
    /// Below this the models have too little to cluster on.
    public static let minimumSeconds: Double = 3

    private var manager: DiarizerManager?
    /// The single in-flight load, so concurrent callers share one download.
    private var loadTask: Task<Void, Error>?

    public init() {}

    /// Where the diarization models are cached.
    ///
    /// FluidAudio's own default is `~/Library/Application Support/FluidAudio/
    /// Models/`, outside Wispr's folder entirely — which made two of our
    /// claims false at once: PRIVACY.md says deleting
    /// `~/Library/Application Support/Wispr/` removes everything including
    /// models, and `brew uninstall --zap` only zaps `Wispr` plus the
    /// preferences. Either route left several hundred MB of models behind.
    /// Downloading into Wispr's own `models/` makes both true again.
    ///
    /// FluidAudio 0.15.5 treats this URL's PARENT as the cache root and
    /// appends its own repo-named folder, so the files land in
    /// `Wispr/models/<repo>/`. The trailing component is chosen so that
    /// either reading of the parameter — literal directory, or
    /// parent-plus-repo — stays inside `Wispr/models/`.
    static func modelsDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("Wispr")
            .appendingPathComponent("models")
            .appendingPathComponent("diarizer")
    }

    /// Downloads and loads the models. Called ahead of time by the pipeline so
    /// the download does not sit inside the diarization step's progress.
    ///
    /// Coalesced rather than merely guarded: `guard manager == nil` followed
    /// by an `await` releases the actor, so two meetings processing at once
    /// (stop A, record and stop B; or reprocess X while Y runs) both saw nil
    /// and both started a Hugging Face download of the same models.
    public func warmUp() async throws {
        if manager != nil { return }
        // Claimed with no suspension between the read and the write, so
        // exactly one load ever exists.
        let task = loadTask ?? Task { try await self.performLoad() }
        loadTask = task
        do {
            try await task.value
        } catch {
            loadTask = nil
            WisprLog.log("diarizer: model load FAILED: \(error)")
            throw DiarizationError.modelsUnavailable(error.localizedDescription)
        }
        loadTask = nil
    }

    private func performLoad() async throws {
        let models = try await DiarizerModels.downloadIfNeeded(to: Self.modelsDirectory())
        let manager = DiarizerManager()
        manager.initialize(models: models)
        self.manager = manager
    }

    public func unload() {
        manager = nil
    }

    public func diarize(samples: [Float],
                        progress: (@Sendable (Double) -> Void)?) async throws -> [DiarizedSpan] {
        guard Double(samples.count) / AudioResampler.targetSampleRate
                >= Self.minimumSeconds else {
            throw DiarizationError.tooShort
        }
        try await warmUp()
        guard let manager else {
            throw DiarizationError.modelsUnavailable("manager unavailable after warm-up")
        }
        do {
            let result = try manager.performCompleteDiarization(
                samples, sampleRate: Int(AudioResampler.targetSampleRate))
            progress?(1.0)
            return Self.spans(from: result.segments.map {
                (speakerID: $0.speakerId, start: $0.startTimeSeconds, end: $0.endTimeSeconds)
            })
        } catch {
            WisprLog.log("diarizer: diarization FAILED: \(error)")
            throw DiarizationError.modelsUnavailable(error.localizedDescription)
        }
    }

    /// Pure mapping from FluidAudio's Float-seconds segments to
    /// `DiarizedSpan`, split out so it is testable without models.
    /// Zero- and negative-length spans are dropped — they cannot win an
    /// overlap comparison and would only add noise.
    public static func spans(
        from segments: [(speakerID: String, start: Float, end: Float)]
    ) -> [DiarizedSpan] {
        segments
            .filter { $0.end > $0.start }
            .map { DiarizedSpan(speakerID: $0.speakerID,
                                start: TimeInterval($0.start),
                                end: TimeInterval($0.end)) }
            .sorted { $0.start < $1.start }
    }
}
