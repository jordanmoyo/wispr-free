import AVFoundation
import AppKit
import Foundation
import ScreenCaptureKit

public enum SystemAudioError: Error, Equatable {
    case permissionDenied
    case noDisplay
    case streamFailed(String)

    public var userMessage: String {
        switch self {
        case .permissionDenied:
            return "Wispr needs Screen Recording permission to hear the other "
                + "participants. Open System Settings › Privacy & Security › "
                + "Screen Recording and enable Wispr Free, then try again."
        case .noDisplay:
            return "No display available to capture system audio from."
        case .streamFailed(let detail):
            return "System audio capture failed: \(detail)"
        }
    }
}

/// Captures everything the Mac is playing — the other participants in a call —
/// using ScreenCaptureKit, with no virtual audio driver and no kernel
/// extension. Wispr's own audio is excluded so a played-back recording never
/// feeds itself.
///
/// Requires the Screen Recording TCC grant, which cannot be requested
/// programmatically. `permissionGranted()` probes it; on denial the caller
/// must show `SystemAudioError.permissionDenied.userMessage` and offer
/// `openScreenRecordingSettings()`.
public final class SystemAudioSource: NSObject, MeetingAudioSource, SCStreamOutput,
                                     SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var stream: SCStream?
    private var elapsedSamples = 0
    private let excludingCurrentProcess: Bool

    /// True from the moment a `start()` call claims the source until
    /// `stop()` clears it. Guards against a second concurrent/reentrant
    /// `start()` and gives an in-flight sample-buffer callback a fast way to
    /// bail once stopped. Mirrors `MeetingMicSource`'s epoch/claim scheme.
    private var isActive = false
    /// Bumped every time `start()` claims the source. Lets a `start()` that
    /// began before a concurrent `stop()` detect, at commit time, that it
    /// was superseded — see `commitIfCurrent`.
    private var epoch = 0

    private var _onChunk: (@Sendable (AudioChunk) -> Void)?
    private var _onFailure: (@Sendable (Error) -> Void)?

    public var onChunk: (@Sendable (AudioChunk) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onChunk }
        set { lock.lock(); defer { lock.unlock() }; _onChunk = newValue }
    }

    public var onFailure: (@Sendable (Error) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFailure }
        set { lock.lock(); defer { lock.unlock() }; _onFailure = newValue }
    }

    public init(excludingCurrentProcess: Bool = true) {
        self.excludingCurrentProcess = excludingCurrentProcess
        super.init()
    }

    /// The only reliable probe for the Screen Recording grant: fetching
    /// shareable content throws when it is missing.
    public static func permissionGranted() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    public static func openScreenRecordingSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    public func start() async throws {
        guard let myEpoch = claimStart() else {
            WisprLog.log("system audio: start() called while already started — ignoring")
            return
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            WisprLog.log("system audio: shareable content FAILED: \(error)")
            abortStart(epoch: myEpoch)
            throw SystemAudioError.permissionDenied
        }
        guard let display = content.displays.first else {
            abortStart(epoch: myEpoch)
            throw SystemAudioError.noDisplay
        }

        // Audio-only in practice: the filter needs a display on macOS 14, but
        // the config asks for a 2×2 video frame at 1 fps so the video path
        // costs essentially nothing.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = excludingCurrentProcess
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio,
                                       sampleHandlerQueue: DispatchQueue(
                                           label: "wispr.meeting.systemaudio"))
            try await stream.startCapture()
        } catch {
            WisprLog.log("system audio: startCapture FAILED: \(error)")
            abortStart(epoch: myEpoch)
            throw SystemAudioError.streamFailed(error.localizedDescription)
        }

        if !commitIfCurrent(epoch: myEpoch, stream: stream) {
            // A concurrent `stop()` landed between our claim and this commit.
            // Nobody holds a handle on this stream anymore — tear down the
            // one we just brought up rather than leaking it running forever.
            WisprLog.log("system audio: start() superseded by a concurrent stop(), tearing down")
            do {
                try await stream.stopCapture()
            } catch {
                WisprLog.log("system audio: post-supersede stopCapture FAILED: \(error)")
            }
        }
    }

    public func stop() async {
        let stream = clearState()
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            WisprLog.log("system audio: stopCapture FAILED: \(error)")
        }
    }

    /// Claims the source for a new start attempt. Returns nil (no-op, do
    /// not proceed) if already active — guards against a reentrant/second
    /// concurrent `start()` leaking the previous stream. Otherwise marks the
    /// source active and returns a fresh epoch that the caller must present
    /// unchanged to `commitIfCurrent`/`abortStart`.
    ///
    /// Internal rather than `private` so tests can exercise the start/stop
    /// race and reentrancy guard directly and deterministically, without
    /// touching real audio hardware — not part of the public API, still
    /// invisible outside this module. Mirrors `MeetingMicSource.claimStart`.
    func claimStart() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !isActive else { return nil }
        isActive = true
        epoch += 1
        return epoch
    }

    /// Undoes `claimStart` after this attempt failed before reaching stream
    /// setup completion, but only if nothing superseded it in the meantime
    /// (a concurrent `stop()`, or — impossible without a prior `stop()` — a
    /// newer `start()`). If superseded, that other call already owns (or has
    /// already cleared) `isActive`, so this is a no-op.
    func abortStart(epoch: Int) {
        lock.lock(); defer { lock.unlock() }
        guard epoch == self.epoch else { return }
        isActive = false
    }

    /// Synchronous body of the post-start bookkeeping, kept separate so the
    /// lock is taken and released entirely inside an ordinary (non-`async`)
    /// function — an `NSLock` taken directly inside an `async func` is a
    /// Swift 6 language-mode error.
    ///
    /// Returns false if a concurrent `stop()` (or, impossible on its own, a
    /// newer `start()`) ran since `epoch` was claimed — the caller must then
    /// tear down the stream it just built instead of storing it, since
    /// nothing else holds a handle to stop it later.
    func commitIfCurrent(epoch: Int, stream: SCStream) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard epoch == self.epoch, isActive else { return false }
        self.stream = stream
        self.elapsedSamples = 0
        return true
    }

    /// Synchronous body of `stop()`'s state teardown; see the concurrency
    /// note above `commitIfCurrent`. Clears the chunk/failure handlers in the
    /// same locked section so a sample-buffer callback already in flight
    /// when `stop()` is called reads a nil handler (and, independently, sees
    /// `isActive == false`) rather than delivering into a track the caller
    /// believes is finalised. Internal (see `claimStart`) so tests can drive
    /// it directly to simulate a `stop()` racing an in-flight `start()`.
    func clearState() -> SCStream? {
        lock.lock(); defer { lock.unlock() }
        isActive = false
        let stream = self.stream
        self.stream = nil
        self._onChunk = nil
        self._onFailure = nil
        return stream
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        let samples = AudioResampler.resampleToWhisperFormat(buffer)
        guard !samples.isEmpty else { return }
        lock.lock()
        // Bail without delivering unless this callback belongs to the live
        // stream. `isActive` alone is not enough: a buffer from a superseded
        // stream can land after a NEWER start() has set isActive back to true,
        // and would then advance that session's elapsedSamples with stale
        // audio. Identity against the committed stream pins delivery to its
        // own session — a superseded stream is never stored, so its buffers
        // are rejected here.
        guard isActive, stream === self.stream, let handler = _onChunk else {
            lock.unlock()
            return
        }
        let offset = Double(elapsedSamples) / AudioResampler.targetSampleRate
        elapsedSamples += samples.count
        lock.unlock()
        handler(AudioChunk(samples: samples, hostTime: offset))
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        WisprLog.log("system audio: stream stopped with error: \(error)")
        lock.lock()
        // Only the live stream's failure concerns the caller. A superseded or
        // already-stopped stream reporting an error must not tear down a
        // session that is running fine.
        guard stream === self.stream else {
            lock.unlock()
            return
        }
        isActive = false
        self.stream = nil
        let handler = _onFailure
        lock.unlock()
        handler?(SystemAudioError.streamFailed(error.localizedDescription))
    }

    // MARK: - Private

    /// Converts a ScreenCaptureKit audio sample buffer into an
    /// `AVAudioPCMBuffer` so `AudioResampler` can do the 48 kHz stereo →
    /// 16 kHz mono conversion the rest of the pipeline expects.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription,
              let streamDescription = description.audioStreamBasicDescription else {
            return nil
        }
        var asbd = streamDescription
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList)
        guard status == noErr else {
            WisprLog.log("system audio: PCM copy FAILED status=\(status)")
            return nil
        }
        return buffer
    }
}
