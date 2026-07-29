import XCTest
@testable import WisprCore

final class VersionComparatorTests: XCTestCase {
    func testTable() {
        let cases: [(String, String, Bool)] = [
            ("v0.2.0", "0.1.4", true),
            ("0.2.0", "0.2.0", false),
            ("0.1.3", "0.1.4", false),
            ("v0.2", "0.1.9", true),
            ("0.2", "0.2.0", false),
            ("abc", "0.1.0", false),
            ("1.0.0", "0.9.9", true),
        ]
        for (remote, local, expected) in cases {
            XCTAssertEqual(
                VersionComparator.isNewer(remote: remote, local: local),
                expected,
                "isNewer(remote: \(remote), local: \(local)) should be \(expected)")
        }
    }
}

private struct MockTransport: UpdateTransport {
    let result: Result<Data, Error>

    func fetchLatestReleaseJSON() async throws -> Data {
        switch result {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }
}

private struct MockError: Error {}

final class UpdateCheckerTests: XCTestCase {
    func testNewerVersionReturnsUpdateAvailableWithStrippedString() async {
        let json = Data(#"{"tag_name":"v9.9.9"}"#.utf8)
        let checker = UpdateChecker(transport: MockTransport(result: .success(json)), currentVersion: "0.1.0")
        let result = await checker.check()
        XCTAssertEqual(result, .updateAvailable("9.9.9"))
    }

    func testEqualVersionReturnsUpToDate() async {
        let json = Data(#"{"tag_name":"v1.0.0"}"#.utf8)
        let checker = UpdateChecker(transport: MockTransport(result: .success(json)), currentVersion: "1.0.0")
        let result = await checker.check()
        XCTAssertEqual(result, .upToDate)
    }

    func testOlderVersionReturnsUpToDate() async {
        let json = Data(#"{"tag_name":"v0.9.0"}"#.utf8)
        let checker = UpdateChecker(transport: MockTransport(result: .success(json)), currentVersion: "1.0.0")
        let result = await checker.check()
        XCTAssertEqual(result, .upToDate)
    }

    func testMalformedJSONReturnsFailed() async {
        let json = Data("not json".utf8)
        let checker = UpdateChecker(transport: MockTransport(result: .success(json)), currentVersion: "1.0.0")
        let result = await checker.check()
        XCTAssertEqual(result, .failed)
    }

    func testThrowingTransportReturnsFailed() async {
        let checker = UpdateChecker(transport: MockTransport(result: .failure(MockError())), currentVersion: "1.0.0")
        let result = await checker.check()
        XCTAssertEqual(result, .failed)
    }

    func testNotModifiedIsDistinctFromUpToDate() async {
        let checker = UpdateChecker(transport: MockTransport(result: .failure(NotModifiedError())), currentVersion: "1.0.0")
        let result = await checker.check()
        XCTAssertEqual(result, .notModified)
        XCTAssertNotEqual(result, .upToDate)
    }

    func testNotModifiedReplaysLastKnownUpdate() async {
        // First check finds an update; the second hits the ETag cache (304).
        // The 304 means "nothing changed since that answer", so the known
        // update must be replayed — not reported as a bare .notModified,
        // which callers treat as "no fresh answer" and ignore.
        let json = Data(#"{"tag_name":"v9.9.9"}"#.utf8)
        let transport = SequencedTransport(results: [
            .success(json),
            .failure(NotModifiedError()),
        ])
        let checker = UpdateChecker(transport: transport, currentVersion: "0.1.0")
        let first = await checker.check()
        XCTAssertEqual(first, .updateAvailable("9.9.9"))
        let second = await checker.check()
        XCTAssertEqual(second, .updateAvailable("9.9.9"))
    }
}

/// Returns each queued result once, in order (final result repeats).
private final class SequencedTransport: UpdateTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Data, Error>]

    init(results: [Result<Data, Error>]) {
        self.results = results
    }

    func fetchLatestReleaseJSON() async throws -> Data {
        lock.lock()
        let next = results.count > 1 ? results.removeFirst() : results[0]
        lock.unlock()
        switch next {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }
}
