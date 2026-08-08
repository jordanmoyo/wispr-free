import Foundation

public enum TranscriptionStage: String, Codable, Sendable {
    case diarizing, transcribing, generating, done

    public var label: String {
        switch self {
        case .diarizing: return "Identifying speakers"
        case .transcribing: return "Transcribing"
        case .generating: return "Generating"
        case .done: return "Done"
        }
    }
}

/// One progress reading for the Transcribe pane's single percentage bar.
///
/// Decoding is interleaved with transcription — `AudioFileReader` produces
/// each chunk as `MeetingTranscriber` reaches it — so decode is deliberately
/// NOT a stage. A bar that sat at "Decoding" for two minutes and then
/// restarted at zero would misrepresent the work.
public struct TranscriptionProgress: Sendable, Equatable {
    /// Diarization runs once over the whole file before transcription starts,
    /// and is much faster than transcription, so it takes a small fixed slice
    /// of the bar rather than a proportional one.
    public static let diarizationShare = 0.15

    public let stage: TranscriptionStage
    /// Overall completion, 0...1 — not the stage's own fraction.
    public let fraction: Double

    public init(stage: TranscriptionStage, fraction: Double) {
        self.stage = stage
        self.fraction = fraction
    }

    public static func make(stage: TranscriptionStage, stageFraction: Double,
                            diarizationEnabled: Bool) -> TranscriptionProgress {
        TranscriptionProgress(
            stage: stage,
            fraction: overall(stage: stage, stageFraction: stageFraction,
                              diarizationEnabled: diarizationEnabled))
    }

    /// Maps a stage-local 0...1 onto the overall bar. Pure, so the weighting
    /// is testable without a model or a file.
    public static func overall(stage: TranscriptionStage, stageFraction: Double,
                               diarizationEnabled: Bool) -> Double {
        let clamped = min(1, max(0, stageFraction))
        switch stage {
        case .diarizing:
            return diarizationEnabled ? clamped * diarizationShare : 0
        case .transcribing:
            guard diarizationEnabled else { return clamped }
            return diarizationShare + clamped * (1 - diarizationShare)
        case .generating:
            // Generation is triggered separately by a button, so it owns its
            // own bar rather than continuing the transcription one.
            return clamped
        case .done:
            return 1
        }
    }
}
