import Foundation

public final class ModelStore {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    /// Default root used by the app: ~/Library/Application Support/Wispr
    public static func defaultStore() -> ModelStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Wispr")
        return ModelStore(rootDirectory: base)
    }

    public func directory(for model: WhisperModel) -> URL {
        rootDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(model.whisperKitName)
    }

    public func isInstalled(_ model: WhisperModel) -> Bool {
        let dir = directory(for: model)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        return !contents.isEmpty
    }

    public func installedModels() -> [WhisperModel] {
        ModelRegistry.models.filter(isInstalled)
    }

    /// Root passed to HubCache for LLM cleanup models. HubCache imposes the
    /// Python-compatible layout models--<org>--<name>/snapshots/<revision>/.
    public var cleanupCacheDirectory: URL {
        rootDirectory.appendingPathComponent("models/llm")
    }

    public func directory(for model: CleanupModel) -> URL {
        cleanupCacheDirectory.appendingPathComponent(
            "models--" + model.hfRepoID.replacingOccurrences(of: "/", with: "--"))
    }

    public func isInstalled(_ model: CleanupModel) -> Bool {
        let snapshots = directory(for: model).appendingPathComponent("snapshots")
        guard let revisions = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) else {
            return false
        }
        return revisions.contains { revision in
            let files = (try? FileManager.default.contentsOfDirectory(
                atPath: snapshots.appendingPathComponent(revision).path)) ?? []
            return !files.isEmpty
        }
    }
}
