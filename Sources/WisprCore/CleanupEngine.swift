import Foundation

public enum CleanupPrompt {
    public static let system = """
        You clean up dictation transcripts. Fix punctuation and capitalization. \
        Remove filler words. Merge fragmented or repeated phrases into fluent \
        sentences. Convert spoken URLs, emails, and numbers to their written \
        form. NEVER translate: every word stays in the language it was spoken \
        in — if the text mixes languages (e.g. French and English), the cleaned \
        text mixes them in exactly the same places. Keep the exact meaning. \
        Never add, answer, or explain anything. Output only the cleaned text.
        """

    /// Character-based approximation: ~3 chars per token, doubled, plus slack.
    public static func maxTokens(for text: String) -> Int {
        2 * max(16, text.count / 3) + 64
    }
}

/// Guards a continuation so exactly one of {operation, timeout} wins the
/// race in `CleanupEngine.withTimeout`. File-scope because Swift disallows
/// types nested inside a generic function.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}

public protocol CleanupBackend: Sendable {
    /// Loads (downloading first if needed) the given model. Idempotent.
    func load(model: CleanupModel) async throws
    /// Generates cleaned text. Requires a prior successful load.
    func generate(system: String, user: String, maxTokens: Int) async throws -> String
    /// Releases model memory.
    func unload() async
}

/// Orchestrates transcript cleanup: lazy model loading, a hard timeout, and
/// fail-open on every error path. `clean` never throws and never blocks the
/// dictation pipeline beyond `timeout` seconds — while a download, load, or
/// generate call is still running past the timeout, the raw transcript is
/// returned immediately and the abandoned work is left running in the
/// background. A load that finishes after its own timeout is still kept and
/// reused by the next call (the model isn't discarded just because one
/// `clean` call gave up waiting on it); only a load that *fails* is cleared,
/// and only if a newer load hasn't already superseded it (see `loadEpoch`).
public actor CleanupEngine {
    private struct Timeout: Error {}

    private let backend: any CleanupBackend
    private let timeout: TimeInterval
    private var loadTask: Task<Void, Error>?
    private var loadingModelID: String?
    /// Bumped every time a new load is actually started. Lets an abandoned
    /// load's failure handler recognize it's stale and avoid clobbering the
    /// bookkeeping of a load that has since superseded it (see Finding 2).
    private var loadEpoch = 0

    public init(backend: any CleanupBackend, timeout: TimeInterval = 5.0) {
        self.backend = backend
        self.timeout = timeout
    }

    public func clean(_ text: String, modelID: String) async -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        guard let model = CleanupModelRegistry.model(id: modelID) else {
            WisprLog.log("cleanup: unknown model id \(modelID), fail-open")
            return text
        }
        if let current = loadingModelID, current != model.id {
            await unload()
        }
        ensureLoadStarted(model)
        guard let loadTask else { return text }

        do {
            let output = try await withTimeout(timeout) { [backend] in
                try await loadTask.value
                return try await backend.generate(system: CleanupPrompt.system,
                                                  user: text,
                                                  maxTokens: CleanupPrompt.maxTokens(for: text))
            }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                WisprLog.log("cleanup: empty output, fail-open")
                return text
            }
            return trimmed
        } catch is Timeout {
            WisprLog.log("cleanup: exceeded \(timeout)s, fail-open")
            return text
        } catch {
            WisprLog.log("cleanup: fail-open (\(error))")
            return text
        }
    }

    public func unload() async {
        loadTask?.cancel()
        loadTask = nil
        loadingModelID = nil
        await backend.unload()
    }

    private func ensureLoadStarted(_ model: CleanupModel) {
        guard loadTask == nil else { return }
        loadingModelID = model.id
        loadEpoch += 1
        let epoch = loadEpoch
        WisprLog.log("cleanup: load begin id=\(model.id)")
        loadTask = Task {
            do {
                try await self.backend.load(model: model)
                WisprLog.log("cleanup: load ready id=\(model.id)")
            } catch {
                WisprLog.log("cleanup: load FAILED id=\(model.id) error=\(error)")
                self.clearFailedLoad(epoch: epoch)
                throw error
            }
        }
    }

    /// No-op if a newer load has already started since this one — otherwise
    /// an abandoned (e.g. superseded-by-model-switch, or timed-out-on but
    /// still running) load's eventual failure would wipe out the bookkeeping
    /// of the load that replaced it, forcing a spurious reload next call.
    private func clearFailedLoad(epoch: Int) {
        guard epoch == loadEpoch else { return }
        loadTask = nil
        loadingModelID = nil
    }

    /// Races `operation` against a wall clock and returns as soon as either
    /// side finishes first — the loser is simply abandoned.
    ///
    /// This is deliberately NOT `withThrowingTaskGroup`: structured
    /// concurrency requires every child task to actually finish running
    /// before the group scope can return, even after `cancelAll()`. If
    /// `operation` awaits something that ignores its own task's cancellation
    /// — like `loadTask.value`, a reference to a separate unstructured task —
    /// the group would block until that finishes regardless of the timeout,
    /// which defeats the whole point of a hard timeout (see Finding 1: a
    /// first-run multi-GB download in flight would block `clean` for the
    /// full download, not `timeout` seconds). A checked continuation has no
    /// such requirement: whichever side calls `resume` first wins and
    /// `withCheckedThrowingContinuation` returns immediately; the other side
    /// keeps running in the background but its result is discarded.
    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            let resumeGuard = ResumeOnce()
            var timerTask: Task<Void, Never>?

            let opTask = Task {
                do {
                    let value = try await operation()
                    if resumeGuard.claim() {
                        timerTask?.cancel()  // operation won; stop waiting on the clock
                        continuation.resume(returning: value)
                    }
                } catch {
                    if resumeGuard.claim() {
                        timerTask?.cancel()
                        continuation.resume(throwing: error)
                    }
                }
            }

            timerTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if resumeGuard.claim() {
                    // Advisory only: `operation` may be blocked on an
                    // unstructured task (like `loadTask.value`) that ignores
                    // this cancellation entirely and keeps running.
                    opTask.cancel()
                    continuation.resume(throwing: Timeout())
                }
            }
        }
    }
}
