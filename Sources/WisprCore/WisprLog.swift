import Foundation

/// Minimal file logger for diagnosing the dictation pipeline.
/// Writes to ~/Library/Application Support/Wispr/wispr.log
public enum WisprLog {
    private static let queue = DispatchQueue(label: "wispr.log")
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("Wispr")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("wispr.log")
    }()

    public static func log(_ message: String) {
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(stamp) \(message)\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
            secure()
        }
    }

    /// Applies the same 0600 and backup exclusion every other file Wispr
    /// writes gets. The log holds no transcript text — only metadata, model
    /// ids, and failure reasons — but it does record what you did and when,
    /// and it was the one file in this folder left at the default umask and
    /// Time-Machine-eligible.
    ///
    /// Applied after every write rather than once at creation: the file is
    /// created lazily by whichever call gets there first, on either branch
    /// above, and `setAttributes` on an already-0600 file is cheap. Failures
    /// are ignored — a logger must never be the thing that breaks.
    private static func secure() {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }
}
