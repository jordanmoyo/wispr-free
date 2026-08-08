import Foundation

/// How much speech-level audio a recording actually contains.
///
/// Whisper does not report "I heard nothing". Handed silence or room tone it
/// emits a fluent sentence from its subtitle-heavy training data — "Thanks
/// for watching", "Sous-titrage Société Radio-Canada" — which dictation
/// would then type into the user's document as if they had said it. The only
/// reliable defence is to look at the audio before transcribing it.
public enum AudioQuality: Equatable, Sendable {
    /// Comfortably above the speech floor: transcribe and trust the result.
    case speech
    /// Just enough audio above the floor to be worth transcribing, but not
    /// enough to trust a one-word result — see
    /// `TranscriptCleaner.isWeakAudioFiller`.
    case marginalSpeech
    /// The device delivered audio, but nothing at speech level: a distant or
    /// muted mic, or a room with nobody talking in it.
    case tooQuiet
    /// Zero-filled buffers — the input device is not actually capturing.
    case digitalSilence

    /// What to tell the user, phrased as the next thing to try. `nil` when
    /// there is nothing to report.
    ///
    /// Kept short because the pill renders errors on a single line (see
    /// `OverlayPill.width(for:)`).
    public var userMessage: String? {
        switch self {
        case .speech, .marginalSpeech: return nil
        case .tooQuiet: return "Didn't hear you — louder, or move closer"
        case .digitalSilence: return "Mic delivered silence — check input device in Settings"
        }
    }
}

/// Decides whether a recording contains speech, by measuring how much of it
/// is above a speech amplitude floor.
///
/// Peak amplitude alone cannot answer this: among real recordings from this
/// app, ones containing nothing but room tone still peaked at 0.03–0.08 on a
/// single desk bump, overlapping the peaks of genuinely quiet speech. What
/// separates them cleanly is *how many* short frames sit at speech level.
public enum AudioQualityGate {
    /// 20 ms at 16 kHz — short enough that a single word spans several
    /// frames, long enough that one sample of noise cannot lift a frame.
    static let frameLength = 320

    /// A frame at or above this RMS carries speech rather than room tone
    /// (-46 dBFS).
    ///
    /// Calibrated against real recordings this app captured. Speech from a
    /// laptop mic put 44–60% of frames above it; five seconds of a live but
    /// quiet room put 0%, its loudest frame reaching only 0.0016. The same
    /// speech attenuated by 30 dB — far fainter than anyone dictates — still
    /// cleared it on 21% of frames, so the floor errs toward transcribing
    /// faint speech rather than rejecting it.
    static let speechFloorRMS: Float = 0.005

    /// 160 ms of speech-level audio: below this a recording is treated as
    /// containing no speech at all. Deliberately lenient — the text-level
    /// checks in `TranscriptCleaner` are the second line of defence, and
    /// discarding something the user really said is worse than transcribing
    /// something they didn't and catching it there.
    static let minimumVoicedFrames = 8

    /// 500 ms of speech-level audio. Below this a bare "you" or "thank you"
    /// in the transcript is more likely to be Whisper's silence artifact than
    /// a word the user spoke.
    static let confidentVoicedFrames = 25

    /// Number of 20 ms frames at or above the speech floor.
    public static func voicedFrameCount(_ samples: [Float]) -> Int {
        var count = 0
        var start = 0
        let floorSquared = Double(speechFloorRMS) * Double(speechFloorRMS)
        while start + frameLength <= samples.count {
            var sumSquares = 0.0
            for i in start..<(start + frameLength) {
                sumSquares += Double(samples[i]) * Double(samples[i])
            }
            if sumSquares / Double(frameLength) >= floorSquared { count += 1 }
            start += frameLength
        }
        return count
    }

    public static func classify(_ samples: [Float]) -> AudioQuality {
        guard Recorder.peakAmplitude(of: samples) >= Recorder.silencePeakThreshold else {
            return .digitalSilence
        }
        let voiced = voicedFrameCount(samples)
        if voiced < minimumVoicedFrames { return .tooQuiet }
        if voiced < confidentVoicedFrames { return .marginalSpeech }
        return .speech
    }
}
