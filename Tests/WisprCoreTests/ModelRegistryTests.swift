import XCTest
@testable import WisprCore

final class ModelRegistryTests: XCTestCase {
    func testRegistryContainsSpecModels() {
        let ids = ModelRegistry.models.map(\.id)
        XCTAssertEqual(ids, ["large-v3-turbo", "large-v3", "distil-large-v3", "medium", "small", "base"])
    }

    func testDefaultIsTurbo() {
        XCTAssertEqual(ModelRegistry.defaultModel.id, "large-v3-turbo")
    }

    func testLookupByID() {
        XCTAssertEqual(ModelRegistry.model(id: "small")?.displayName, "Small")
        XCTAssertNil(ModelRegistry.model(id: "nope"))
    }

    func testInstalledDetection() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispr-test-\(UUID().uuidString)")
        let store = ModelStore(rootDirectory: tmp)
        let model = ModelRegistry.defaultModel
        XCTAssertFalse(store.isInstalled(model))

        let modelDir = tmp.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(model.whisperKitName)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        // WhisperKit puts .mlmodelc bundles inside; an empty dir must not count as installed
        XCTAssertFalse(store.isInstalled(model))
        try Data("x".utf8).write(to: modelDir.appendingPathComponent("config.json"))
        XCTAssertTrue(store.isInstalled(model))
        XCTAssertEqual(store.installedModels(), [model])
    }
}
