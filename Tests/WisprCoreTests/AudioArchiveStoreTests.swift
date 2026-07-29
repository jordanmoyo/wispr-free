import XCTest
@testable import WisprCore

final class AudioArchiveStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispr-audio-archive-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSaveThenURLThenRoundTrip() async throws {
        let store = AudioArchiveStore(directoryURL: tempDir)
        let id = UUID()
        let samples = (0..<16_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000)) * 0.5 }
        await store.save(samples: samples, id: id)
        let url = await store.url(for: id)
        XCTAssertNotNil(url)
        let decoded = try AudioFileImporter.loadSamples(url: url!)
        XCTAssertEqual(Double(decoded.count), Double(samples.count), accuracy: 160)  // ±10 ms
    }

    func testURLForUnknownIDIsNil() async {
        let store = AudioArchiveStore(directoryURL: tempDir)
        let url = await store.url(for: UUID())
        XCTAssertNil(url)
    }

    func testDeleteRemovesFile() async {
        let store = AudioArchiveStore(directoryURL: tempDir)
        let id = UUID()
        await store.save(samples: [0.1, 0.2], id: id)
        var url = await store.url(for: id)
        XCTAssertNotNil(url)

        await store.delete(id: id)
        url = await store.url(for: id)
        XCTAssertNil(url)
    }

    func testDeleteAllEmptiesDirectory() async {
        let store = AudioArchiveStore(directoryURL: tempDir)
        let ids = [UUID(), UUID(), UUID()]
        for id in ids {
            await store.save(samples: [0.1, 0.2], id: id)
        }
        for id in ids {
            let url = await store.url(for: id)
            XCTAssertNotNil(url)
        }

        await store.deleteAll()

        for id in ids {
            let url = await store.url(for: id)
            XCTAssertNil(url)
        }
    }

    func testPruneKeepsOnlyGivenIDs() async {
        let store = AudioArchiveStore(directoryURL: tempDir)
        let keep = UUID(); let drop = UUID()
        await store.save(samples: [0.1, 0.2], id: keep)
        await store.save(samples: [0.1, 0.2], id: drop)
        await store.prune(keeping: [keep])
        let keptURL = await store.url(for: keep)
        let droppedURL = await store.url(for: drop)
        XCTAssertNotNil(keptURL)
        XCTAssertNil(droppedURL)
    }

    func testCapEvictsOldestFile() async throws {
        let store = AudioArchiveStore(directoryURL: tempDir)
        var ids: [UUID] = []
        for i in 0..<(AudioArchiveStore.maxFiles + 1) {
            let id = UUID()
            ids.append(id)
            await store.save(samples: [0.1, 0.2], id: id)
            guard let url = await store.url(for: id) else {
                XCTFail("expected url for saved id")
                continue
            }
            let date = Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + i))
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }

        let firstURL = await store.url(for: ids[0])
        let lastURL = await store.url(for: ids[ids.count - 1])
        XCTAssertNil(firstURL)
        XCTAssertNotNil(lastURL)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.hasSuffix(".wav") }
        XCTAssertEqual(remaining.count, AudioArchiveStore.maxFiles)
    }

    func testSaveIntoUnwritableDirFailsOpen() async {
        let store = AudioArchiveStore(directoryURL: URL(fileURLWithPath: "/System/wispr-test-unwritable"))
        await store.save(samples: [0.1], id: UUID())  // must not crash
    }

    func testFilePermissionsAre0600() async throws {
        let store = AudioArchiveStore(directoryURL: tempDir)
        let id = UUID()
        await store.save(samples: [0.1, 0.2], id: id)
        let url = await store.url(for: id)
        XCTAssertNotNil(url)

        let attrs = try FileManager.default.attributesOfItem(atPath: url!.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }
}
