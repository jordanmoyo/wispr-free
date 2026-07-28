import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// MLX implementation of CleanupBackend. Downloads models via the Hugging
/// Face hub into `cacheDirectory` (HubCache snapshot layout, matching
/// ModelStore.cleanupCacheDirectory) and generates with temperature 0.
public actor MLXCleanupBackend: CleanupBackend {
    private let cacheDirectory: URL
    private var container: ModelContainer?
    private var loadedRepoID: String?

    public init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
    }

    public func load(model: CleanupModel) async throws {
        if loadedRepoID == model.hfRepoID, container != nil { return }
        container = nil
        loadedRepoID = nil
        let hub = HubClient(cache: HubCache(cacheDirectory: cacheDirectory))
        let lastLoggedPercent = LastLoggedPercent()
        // Load into a local first: mlx-swift-lm's from-disk load path has no
        // cancellation checks, so an abandoned Task.cancel() from a model
        // switch doesn't stop this call. Only commit to `container`/
        // `loadedRepoID` after confirming this task wasn't cancelled while
        // we were awaiting, so a stale load can't overwrite a newer model.
        let loadedContainer = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(hub),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: model.hfRepoID),
            progressHandler: { progress in
                let percent = Int(progress.fractionCompleted * 100)
                if lastLoggedPercent.updateIfChanged(percent) {
                    WisprLog.log("cleanup download: \(percent)% id=\(model.id)")
                }
            }
        )
        try Task.checkCancellation()
        container = loadedContainer
        loadedRepoID = model.hfRepoID
    }

    public func generate(system: String, user: String, maxTokens: Int) async throws -> String {
        guard let container else { throw WisprError.modelNotLoaded }
        // Fresh session per call: stateless cleanup, per-call token budget.
        let session = ChatSession(
            container,
            instructions: system,
            generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0))
        return try await session.respond(to: user)
    }

    public func unload() async {
        container = nil
        loadedRepoID = nil
        Memory.clearCache()
    }
}

/// Thread-safe holder for the last logged download percent, so the
/// @Sendable, non-isolated progress handler can dedupe repeated callbacks
/// at the same integer percent without capturing a mutable local (which
/// won't compile under Swift concurrency checking).
private final class LastLoggedPercent: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1

    /// Returns true (and records `percent`) only the first time this
    /// integer percent is seen.
    func updateIfChanged(_ percent: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard percent != value else { return false }
        value = percent
        return true
    }
}
