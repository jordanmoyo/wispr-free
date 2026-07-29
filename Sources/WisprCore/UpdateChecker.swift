import Foundation

/// Compares dotted version strings (optionally prefixed with "v").
public enum VersionComparator {
    /// True iff `remote` is a newer version than `local`.
    /// Strips a leading "v", splits on ".", compares components numerically
    /// (missing trailing components treated as 0). Any non-numeric component
    /// in either string makes the comparison false.
    public static func isNewer(remote: String, local: String) -> Bool {
        guard let remoteParts = numericComponents(of: remote),
              let localParts = numericComponents(of: local) else {
            return false
        }
        let count = max(remoteParts.count, localParts.count)
        for i in 0..<count {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r != l { return r > l }
        }
        return false
    }

    private static func numericComponents(of version: String) -> [Int]? {
        var s = Substring(version)
        if s.first == "v" { s = s.dropFirst() }
        guard !s.isEmpty else { return nil }
        var result: [Int] = []
        for part in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(part) else { return nil }
            result.append(n)
        }
        return result
    }
}

/// Fetches release metadata. Implemented by `GitHubUpdateTransport` for
/// production use and mocked in tests.
public protocol UpdateTransport: Sendable {
    func fetchLatestReleaseJSON() async throws -> Data
}

/// Result of a single `UpdateChecker.check()` call. Distinguishes "no
/// update" (`.upToDate`) from "the check didn't produce a fresh answer"
/// (`.notModified`, `.failed`) so callers don't clear a still-pending
/// `availableUpdate` just because a later check hit a 304 or a transport
/// error.
public enum UpdateCheckOutcome: Sendable, Equatable {
    /// A newer version is available; the associated value is the version
    /// string with any leading "v" stripped.
    case updateAvailable(String)
    /// The running app is already on the latest version.
    case upToDate
    /// The server reported no change since the last check (HTTP 304) — not
    /// an error, but not a fresh answer either.
    case notModified
    /// The check failed (transport error or unparsable response).
    case failed
}

/// Checks GitHub releases for a newer version than the running app.
/// All failures are logged and swallowed — this never surfaces an error to
/// callers, since a failed update check must never disrupt dictation.
public actor UpdateChecker {
    private let transport: any UpdateTransport
    private let currentVersion: String
    /// The version from the most recent `.updateAvailable` outcome. A later
    /// 304 means "nothing changed since that answer", so it's replayed as
    /// `.updateAvailable` again — otherwise a caller that cleared its state
    /// (e.g. the update toggle turned off and back on) could never recover
    /// the pending update for the rest of the session.
    private var lastKnownUpdate: String?

    public init(transport: any UpdateTransport, currentVersion: String) {
        self.transport = transport
        self.currentVersion = currentVersion
    }

    /// Checks for a newer release. Never throws — every failure mode is
    /// reported through `UpdateCheckOutcome` instead.
    public func check() async -> UpdateCheckOutcome {
        let data: Data
        do {
            data = try await transport.fetchLatestReleaseJSON()
        } catch is NotModifiedError {
            // Expected daily outcome once an ETag is cached — not a failure.
            WisprLog.log("update check: not modified (304)")
            if let lastKnownUpdate {
                return .updateAvailable(lastKnownUpdate)
            }
            return .notModified
        } catch {
            WisprLog.log("update check: transport FAILED error=\(error)")
            return .failed
        }

        struct Release: Decodable { let tag_name: String }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            WisprLog.log("update check: malformed release JSON")
            return .failed
        }

        let remote = release.tag_name
        guard VersionComparator.isNewer(remote: remote, local: currentVersion) else {
            lastKnownUpdate = nil
            return .upToDate
        }
        let version = remote.hasPrefix("v") ? String(remote.dropFirst()) : remote
        lastKnownUpdate = version
        return .updateAvailable(version)
    }
}

/// Benign marker error used to signal "no change since last check" (HTTP 304).
struct NotModifiedError: Error {}

/// URLSession-backed `UpdateTransport` hitting the GitHub releases API.
/// Thin by design — real network behavior is not unit-tested.
public final class GitHubUpdateTransport: UpdateTransport, @unchecked Sendable {
    private static let url = URL(string: "https://api.github.com/repos/jordanmoyo/wispr-free/releases/latest")!

    private let session: URLSession
    private let etagLock = NSLock()
    private var lastETag: String?

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        session = URLSession(configuration: config)
    }

    public func fetchLatestReleaseJSON() async throws -> Data {
        var request = URLRequest(url: Self.url)
        if let etag = withETagLock({ lastETag }) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return data
        }

        if http.statusCode == 304 {
            throw NotModifiedError()
        }

        if let newETag = http.value(forHTTPHeaderField: "ETag") {
            withETagLock { lastETag = newETag }
        }

        return data
    }

    private func withETagLock<T>(_ body: () -> T) -> T {
        etagLock.lock()
        defer { etagLock.unlock() }
        return body()
    }
}
