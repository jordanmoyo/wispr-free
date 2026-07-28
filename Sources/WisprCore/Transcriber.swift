import Foundation
import WhisperKit

public actor Transcriber {
    private let modelStore: ModelStore
    private var pipeline: WhisperKit?
    public private(set) var currentModelID: String?

    public init(modelStore: ModelStore) {
        self.modelStore = modelStore
    }

    /// Loads (downloading first if needed) the given model. No-op if already loaded.
    public func load(model: WhisperModel) async throws {
        if currentModelID == model.id, pipeline != nil { return }
        pipeline = nil
        currentModelID = nil
        // WhisperKit's HubApi nests downloads at `downloadBase/models/<repo>/<variant>`,
        // which already matches ModelStore.directory(for:)'s
        // `rootDirectory/models/argmaxinc/whisperkit-coreml/<name>` layout. So downloadBase
        // must be modelStore.rootDirectory itself (not rootDirectory/models), otherwise the
        // "models" segment gets doubled and ModelStore.isInstalled(_:) would never find it.
        let config = WhisperKitConfig(
            model: model.whisperKitName,
            downloadBase: modelStore.rootDirectory,
            load: true,
            download: true
        )
        pipeline = try await WhisperKit(config)
        currentModelID = model.id
    }

    /// Transcribes 16 kHz mono samples. Returns cleaned text ("" for silence).
    public func transcribe(samples: [Float]) async throws -> String {
        guard let pipeline else { throw WisprError.modelNotLoaded }
        // Without detectLanguage, WhisperKit prefills the decoder with the
        // <|en|> language token (its defaultLanguageCode), which makes
        // non-English speech come out translated into English.
        let options = DecodingOptions(task: .transcribe, detectLanguage: true)
        let results = try await pipeline.transcribe(audioArray: samples, decodeOptions: options)
        let raw = results.map(\.text).joined(separator: " ")
        return TranscriptCleaner.clean(raw)
    }
}
