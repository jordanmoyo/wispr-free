import Foundation

/// The duration ceiling for speaker identification on an uploaded file.
///
/// `MeetingDiarizing.diarize(samples:)` requires the WHOLE recording as one
/// `[Float]`, and per-chunk diarization is not an option: speaker ids are
/// assigned per call, so "Speaker 1" at minute 10 would not be "Speaker 1" at
/// minute 70. Mislabelled speakers are worse than absent ones.
///
/// Sixty minutes is 230 MB of resident `Float` plus FluidAudio's own working
/// set. That figure holds only because `AudioFileReader.samples(in:)` reserves
/// its buffer once and trims it in place — returning a fresh `Array` over a
/// slice instead would allocate a second copy while the first is still alive
/// and put the real peak at twice this number.
/// The ceiling lives here as one constant so it is a single line to
/// revise after measurement rather than a number scattered through the
/// pipeline. Cross-chunk speaker re-clustering is the real fix and is
/// deliberately deferred.
public enum DiarizationGate {
    public static let maxSeconds: Double = 3_600

    public static func available(durationSeconds: Double) -> Bool {
        durationSeconds > 0 && durationSeconds <= maxSeconds
    }

    /// Why identification is unavailable, phrased for the user, or nil when
    /// it IS available.
    public static func unavailableReason(durationSeconds: Double) -> String? {
        guard !available(durationSeconds: durationSeconds) else { return nil }
        guard durationSeconds > 0 else {
            return "This file has no audio to identify speakers in."
        }
        let minutes = Int((durationSeconds / 60).rounded())
        let ceiling = Int(maxSeconds / 60)
        return "Speaker identification works on recordings up to \(ceiling) "
            + "minutes. This one is \(minutes) minutes, so it will be "
            + "transcribed without speaker labels."
    }
}
