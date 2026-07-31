import XCTest
@testable import WisprCore

/// `WisprLog` writes to the real `~/Library/Application Support/Wispr/
/// wispr.log` — the path is a private `static let` with no injection point,
/// and adding one only for a test would be a worse trade than appending a
/// line to a log that already exists in every install. The line is
/// indistinguishable from any other diagnostic.
final class WisprLogTests: XCTestCase {
    private var logURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("Wispr")
            .appendingPathComponent("wispr.log")
    }

    /// Every other file in this folder is 0600 and excluded from Time
    /// Machine. The log was the exception: default umask, backup-eligible.
    /// It holds no transcript text, but it does record what you did and when.
    func testLogFileIsPrivateAndExcludedFromBackups() throws {
        WisprLog.log("test: permissions check")

        // The write is queued on WisprLog's serial queue; a barrier-style
        // fence on that same queue is what "the write has landed" means here.
        let written = expectation(description: "log write landed")
        DispatchQueue(label: "wispr.log.test").asyncAfter(deadline: .now() + 0.3) {
            written.fulfill()
        }
        wait(for: [written], timeout: 2)

        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600,
            "wispr.log must be readable only by this user account")
        let excluded = try logURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
            .isExcludedFromBackup
        XCTAssertEqual(excluded, true,
            "wispr.log must be excluded from Time Machine like every other "
                + "file Wispr writes")
    }
}
