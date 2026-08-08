import Foundation
import WhisperKit

/// A dictation transcript together with how sure the decoder was of it.
public struct DictationTranscript: Sendable, Equatable {
    public let text: String
    /// The lowest per-segment average token log-probability, or nil when the
    /// decoder produced no segments. Lower means the decoder was guessing —
    /// see `DictationPlausibility.minimumAverageLogProbability`.
    public let confidence: Float?

    public init(text: String, confidence: Float?) {
        self.text = text
        self.confidence = confidence
    }
}

public actor Transcriber {
    private let modelStore: ModelStore
    private var pipeline: WhisperKit?
    public private(set) var currentModelID: String?

    public init(modelStore: ModelStore) {
        self.modelStore = modelStore
    }

    /// Loads (downloading first if needed) the given model. No-op if already loaded.
    public func load(model: WhisperModel) async throws {
        if currentModelID == model.id, pipeline != nil { return }
        pipeline = nil
        currentModelID = nil
        // WhisperKit's HubApi nests downloads at `downloadBase/models/<repo>/<variant>`,
        // which already matches ModelStore.directory(for:)'s
        // `rootDirectory/models/argmaxinc/whisperkit-coreml/<name>` layout. So downloadBase
        // must be modelStore.rootDirectory itself (not rootDirectory/models), otherwise the
        // "models" segment gets doubled and ModelStore.isInstalled(_:) would never find it.
        let config = WhisperKitConfig(
            model: model.whisperKitName,
            downloadBase: modelStore.rootDirectory,
            load: true,
            download: true
        )
        pipeline = try await WhisperKit(config)
        currentModelID = model.id
    }

    /// Transcribes 16 kHz mono samples. Returns cleaned text ("" for silence)
    /// and the decoder's confidence in it.
    /// - Parameter language: an optional pinned language code (e.g. "fr").
    ///   Without detectLanguage, WhisperKit prefills the decoder with the
    ///   <|en|> language token (its defaultLanguageCode), which makes
    ///   non-English speech come out translated into English — so nil (or
    ///   an unrecognized code) falls back to auto-detection.
    ///
    /// Confidence is the *lowest* segment's average log-probability, not the
    /// mean: one bad segment is one invented sentence, and it should count.
    /// WhisperKit also carries `noSpeechProb`, the obvious signal for this,
    /// but it reports 0.0 for every segment on this machine's models —
    /// measured over 72 archived recordings — so it cannot be used.
    public func transcribe(samples: [Float],
                           language: String? = nil) async throws -> DictationTranscript {
        guard let pipeline else { throw WisprError.modelNotLoaded }
        let options = TranscriptionOptions.build(pinned: language)
        let results = try await pipeline.transcribe(audioArray: samples, decodeOptions: options)
        let raw = results.map(\.text).joined(separator: " ")
        return DictationTranscript(
            text: TranscriptCleaner.clean(raw),
            confidence: results.flatMap(\.segments).map(\.avgLogprob).min())
    }

    /// Timestamped transcription for Meetings. Unlike `transcribe(samples:)`,
    /// this keeps WhisperKit's per-segment boundaries instead of collapsing
    /// everything into one string, because the merger needs times to attribute
    /// speakers.
    ///
    /// `TranscriptCleaner.clean` is applied per segment so each one gets the
    /// same artifact stripping the dictation path gets, plus a filter for the
    /// phrases Whisper emits over silence — see
    /// `TranscriptCleaner.isSilenceHallucination` for why that one is
    /// meetings-only.
    public func transcribeSegments(samples: [Float], language: String? = nil,
                                   progress: (@Sendable (Double) -> Void)? = nil) async throws
        -> [MeetingTranscriptSegment] {
        guard let pipeline else { throw WisprError.modelNotLoaded }
        let options = TranscriptionOptions.build(pinned: language)
        let results = try await pipeline.transcribe(audioArray: samples, decodeOptions: options)
        progress?(1.0)
        return results.flatMap(\.segments).compactMap { segment in
            let text = TranscriptCleaner.clean(segment.text)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !TranscriptCleaner.isSilenceHallucination(text) else { return nil }
            return MeetingTranscriptSegment(
                speaker: .others,
                start: TimeInterval(segment.start),
                end: TimeInterval(segment.end),
                text: text)
        }
    }
}

extension Transcriber: MeetingSegmentTranscribing {}
