import Darwin
import Foundation

/// The ground a run writes on, which is the identity of the runner.
///
/// One decision, one place: root runs keep today's ground, byte for byte, and
/// a run that is not root writes on ground it owns outright. The log and the
/// lock both read the ground instead of hardcoding a path of their own, so the
/// split between the two lives here and nowhere else.
public enum Ground {
    /// Whether this process runs as root, which is the only identity that ever
    /// had the old ground to itself.
    public static var isRoot: Bool { geteuid() == 0 }

    /// The directory a user run's log is written under.
    public static var userLogDirectory: String { NSHomeDirectory() + "/Library/Logs/showup" }

    /// The directory a user run's instance lock is held in.
    public static var userLockDirectory: String { NSHomeDirectory() + "/Library/Application Support/showup" }

    /// The directory this run's log is written under.
    public static var logDirectory: String { isRoot ? "/var/log" : userLogDirectory }

    /// The directory this run's instance lock is held in.
    public static var lockDirectory: String { isRoot ? "/var/log" : userLockDirectory }

    /// The log file a run that started at `now` writes to, on the given ground.
    public static func logPath(now: Date, directory: String) -> String {
        directory + "/showup\(Int(now.timeIntervalSince1970)).log"
    }

    /// The instance lock file this run holds, on the given ground.
    public static func lockPath(directory: String) -> String { directory + "/showup.lock" }

    /// Creates the directories this run's artifacts live in, on the ground it
    /// runs on, with the process's own permissions. The root ground's directory
    /// already exists and is not touched.
    public static func ensureDirectories() {
        let fileManager = FileManager.default
        for directory in [logDirectory, lockDirectory] where !fileManager.fileExists(atPath: directory) {
            try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
    }
}
