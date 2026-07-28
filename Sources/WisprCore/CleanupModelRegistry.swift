import Foundation

public struct CleanupModel: Identifiable, Equatable {
    public let id: String
    public let hfRepoID: String
    public let displayName: String
    public let approxSizeMB: Int
}

public enum CleanupModelRegistry {
    public static let models: [CleanupModel] = [
        CleanupModel(id: "qwen3-4b",
                     hfRepoID: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
                     displayName: "Qwen3 4B (recommended)", approxSizeMB: 2300),
        CleanupModel(id: "qwen2.5-1.5b",
                     hfRepoID: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
                     displayName: "Qwen2.5 1.5B (fastest)", approxSizeMB: 900),
        CleanupModel(id: "llama-3.2-3b",
                     hfRepoID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                     displayName: "Llama 3.2 3B", approxSizeMB: 1850),
        CleanupModel(id: "gemma-3-4b",
                     hfRepoID: "mlx-community/gemma-3-4b-it-4bit-DWQ",
                     displayName: "Gemma 3 4B (best multilingual)", approxSizeMB: 2600),
        CleanupModel(id: "qwen2.5-7b",
                     hfRepoID: "mlx-community/Qwen2.5-7B-Instruct-4bit",
                     displayName: "Qwen2.5 7B (max quality)", approxSizeMB: 4300),
    ]

    public static let defaultModel = models[0]

    public static func model(id: String) -> CleanupModel? {
        models.first { $0.id == id }
    }
}
