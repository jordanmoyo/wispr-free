import XCTest
@testable import WisprCore

final class CleanupModelRegistryTests: XCTestCase {
    func testRegistryContainsSpecModels() {
        let ids = CleanupModelRegistry.models.map(\.id)
        XCTAssertEqual(ids, ["qwen3-4b", "qwen2.5-1.5b", "llama-3.2-3b", "gemma-3-4b", "qwen2.5-7b"])
    }

    func testDefaultIsQwen3() {
        XCTAssertEqual(CleanupModelRegistry.defaultModel.id, "qwen3-4b")
    }

    func testExactRepoIDs() {
        func repo(_ id: String) -> String? { CleanupModelRegistry.model(id: id)?.hfRepoID }
        XCTAssertEqual(repo("qwen3-4b"), "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        XCTAssertEqual(repo("qwen2.5-1.5b"), "mlx-community/Qwen2.5-1.5B-Instruct-4bit")
        XCTAssertEqual(repo("llama-3.2-3b"), "mlx-community/Llama-3.2-3B-Instruct-4bit")
        XCTAssertEqual(repo("gemma-3-4b"), "mlx-community/gemma-3-4b-it-4bit-DWQ")
        XCTAssertEqual(repo("qwen2.5-7b"), "mlx-community/Qwen2.5-7B-Instruct-4bit")
        XCTAssertNil(CleanupModelRegistry.model(id: "nope"))
    }

    func testInstalledDetectionUsesHubCacheLayout() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispr-test-\(UUID().uuidString)")
        let store = ModelStore(rootDirectory: tmp)
        let model = CleanupModelRegistry.defaultModel
        XCTAssertFalse(store.isInstalled(model))

        // HubCache layout: <cacheDir>/models--org--name/snapshots/<revision>/<files>
        let snapshot = store.directory(for: model)
            .appendingPathComponent("snapshots/abc123")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        // An empty snapshot dir must not count as installed
        XCTAssertFalse(store.isInstalled(model))
        try Data("x".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        XCTAssertTrue(store.isInstalled(model))
    }

    func testDirectoryLayout() {
        let store = ModelStore(rootDirectory: URL(fileURLWithPath: "/root"))
        XCTAssertEqual(store.cleanupCacheDirectory.path, "/root/models/llm")
        XCTAssertEqual(
            store.directory(for: CleanupModelRegistry.defaultModel).path,
            "/root/models/llm/models--mlx-community--Qwen3-4B-Instruct-2507-4bit")
    }
}
