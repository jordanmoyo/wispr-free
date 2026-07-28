import Foundation

public struct WhisperModel: Identifiable, Equatable {
    public let id: String
    public let whisperKitName: String
    public let displayName: String
    public let approxSizeMB: Int
}

public enum ModelRegistry {
    public static let models: [WhisperModel] = [
        WhisperModel(id: "large-v3-turbo",
                     whisperKitName: "openai_whisper-large-v3-v20240930",
                     displayName: "Large v3 Turbo (recommended)", approxSizeMB: 1600),
        WhisperModel(id: "large-v3",
                     whisperKitName: "openai_whisper-large-v3",
                     displayName: "Large v3 (max accuracy)", approxSizeMB: 3100),
        WhisperModel(id: "distil-large-v3",
                     whisperKitName: "distil-whisper_distil-large-v3",
                     displayName: "Distil Large v3 (fast)", approxSizeMB: 1500),
        WhisperModel(id: "medium",
                     whisperKitName: "openai_whisper-medium",
                     displayName: "Medium", approxSizeMB: 1500),
        WhisperModel(id: "small",
                     whisperKitName: "openai_whisper-small",
                     displayName: "Small", approxSizeMB: 480),
        WhisperModel(id: "base",
                     whisperKitName: "openai_whisper-base",
                     displayName: "Base (fastest, lowest accuracy)", approxSizeMB: 145),
    ]

    public static let defaultModel = models[0]

    public static func model(id: String) -> WhisperModel? {
        models.first { $0.id == id }
    }
}
