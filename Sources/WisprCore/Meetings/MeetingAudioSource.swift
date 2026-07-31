import Foundation

/// A block of meeting audio: 16 kHz mono Float32 samples, already resampled,
/// stamped with when it was captured relative to the start of recording.
public struct AudioChunk: Sendable {
    public let samples: [Float]
    /// Seconds since the recording started.
    public let hostTime: TimeInterval

    public init(samples: [Float], hostTime: TimeInterval) {
        self.samples = samples
        self.hostTime = hostTime
    }
}

/// One capture track of a meeting. Both the mic and the system-audio source
/// conform, so `MeetingRecorder` treats them identically and either can fail
/// independently.
public protocol MeetingAudioSource: AnyObject, Sendable {
    var onChunk: (@Sendable (AudioChunk) -> Void)? { get set }
    /// Called once when the source dies mid-recording. The recorder decides
    /// whether to continue on the surviving track or abort.
    var onFailure: (@Sendable (Error) -> Void)? { get set }
    func start() async throws
    func stop() async
}

/// A source driven entirely by test code. Lives beside the protocol so
/// `MeetingRecorder`'s tests can exercise the full state machine — including
/// mid-recording failures — with no hardware and no permissions.
public final class StubAudioSource: MeetingAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _onChunk: (@Sendable (AudioChunk) -> Void)?
    private var _onFailure: (@Sendable (Error) -> Void)?
    private var _started = false
    private var _stopped = false

    /// When set, `start()` throws this instead of starting.
    public var startError: Error?

    public var onChunk: (@Sendable (AudioChunk) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onChunk }
        set { lock.lock(); defer { lock.unlock() }; _onChunk = newValue }
    }

    public var onFailure: (@Sendable (Error) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFailure }
        set { lock.lock(); defer { lock.unlock() }; _onFailure = newValue }
    }

    public var started: Bool { lock.lock(); defer { lock.unlock() }; return _started }
    public var stopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }

    public init() {}

    public func start() async throws {
        if let startError { throw startError }
        markStarted()
    }

    public func stop() async {
        markStopped()
    }

    /// Synchronous body of `start()`'s bookkeeping, kept separate so the
    /// lock is taken and released entirely inside an ordinary (non-`async`)
    /// function — see `MeetingAudioWriter.finishSync()`/
    /// `MeetingMicSource.commitIfCurrent` for why holding an `NSLock`
    /// directly inside an `async func` is a Swift 6 language-mode error.
    private func markStarted() {
        lock.lock(); defer { lock.unlock() }
        _started = true
    }

    /// Synchronous body of `stop()`'s bookkeeping; see `markStarted`.
    /// Mirrors `MeetingMicSource`: clears both handlers on stop so a caller
    /// that emits into a stopped stub (or a straggling real callback, in the
    /// production source) can't mask a use-after-stop delivery bug in a
    /// later task's tests.
    private func markStopped() {
        lock.lock(); defer { lock.unlock() }
        _stopped = true
        _onChunk = nil
        _onFailure = nil
    }

    public func emit(_ samples: [Float], at hostTime: TimeInterval) {
        onChunk?(AudioChunk(samples: samples, hostTime: hostTime))
    }

    public func fail(_ error: Error) {
        onFailure?(error)
    }
}
