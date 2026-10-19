import Foundation
import ShowupCore

/// One file per run, so a single run can be read on its own and no file grows
/// without bound. The number is the wall clock at start, which also sorts the
/// directory into the order the runs happened in.
///
/// This is the only place showup writes. One place, decided once: a setting
/// that moves the log around is a setting that will be different on the night
/// somebody needs to read it.
public func logPath(now: Date = Date()) -> String {
    "/var/log/showup\(Int(now.timeIntervalSince1970)).log"
}

/// What showup did, and when, in a file that survives the terminal.
///
/// The directory is `/var/log`, not `/tmp`, and that is not a style choice.
/// `showup` runs as root, and `/tmp` is world writable: a user who creates a
/// file there as a symlink gets a root process to write through it. `/var/log`
/// is root owned and the file is opened `O_NOFOLLOW`, so there is nothing there
/// to aim at.
///
/// Each line is appended with one `write(2)` on a descriptor opened once, rather
/// than a shell per line: a shell spawn per log line is a process per log line,
/// and this is the most frequent thing the program does.
public enum Log {
    public static let path = logPath()

    private static let descriptor: Int32 = {
        let file = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        return file < 0 ? -1 : file
    }()

    /// Whether this run can write its log at all, which without sudo it cannot.
    public static var isWritable: Bool { descriptor >= 0 }

    /// Prints to the given stream and appends a stamped copy to the log file.
    ///
    /// Best effort: a log that cannot be written is not a reason to stop
    /// surfacing apps.
    public static func write(_ message: String, to stream: FileHandle = .standardOutput) {
        let line = "\(clock(secondsSinceMidnight(Date())))  \(message)\n"
        stream.write(Data("showup: \(line)".utf8))
        guard descriptor >= 0 else { return }
        _ = line.withCString { Darwin.write(descriptor, $0, strlen($0)) }
    }
}