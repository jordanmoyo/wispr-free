import Foundation
import WhisperKit

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

    /// Transcribes 16 kHz mono samples. Returns cleaned text ("" for silence).
    /// - Parameter language: an optional pinned language code (e.g. "fr").
    ///   Without detectLanguage, WhisperKit prefills the decoder with the
    ///   <|en|> language token (its defaultLanguageCode), which makes
    ///   non-English speech come out translated into English — so nil (or
    ///   an unrecognized code) falls back to auto-detection.
    public func transcribe(samples: [Float], language: String? = nil) async throws -> String {
        guard let pipeline else { throw WisprError.modelNotLoaded }
        let options = TranscriptionOptions.build(pinned: language)
        let results = try await pipeline.transcribe(audioArray: samples, decodeOptions: options)
        let raw = results.map(\.text).joined(separator: " ")
        return TranscriptCleaner.clean(raw)
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
