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
    Ground.logPath(now: now, directory: Ground.logDirectory)
}

/// How long an old run's log is kept before the next run deletes it.
///
/// One file per run plus no limit is a directory that grows without bound: the
/// bug collector here stopped at eleven files in three days. A week covers
/// every wake anyone traced in practice, and the files self sort by epoch, so
/// the oldest are the ones that go.
public let logRetentionSeconds: TimeInterval = 7 * 24 * 60 * 60

/// Whether an entry of the log directory is an old log of this program's.
///
/// Only names the pattern `showup<number>.log` produces could ever have been
/// written by showup. The type has to be a regular file as seen by `lstat` -
/// `attributesOfItem(atPath:)` does not follow symlinks - so nothing that
/// points elsewhere is deleted whatever its name. A minute early is not old.
public func prunableLog(_ name: String, isRegularFile: Bool, modified: Date, now: Date) -> Bool {
    guard isRegularFile, name.hasPrefix("showup"), name.hasSuffix(".log") else { return false }
    let number = name.dropFirst("showup".count).dropLast(".log".count)
    guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return false }
    return modified < now.addingTimeInterval(-logRetentionSeconds)
}

/// What showup did, and when, in a file that survives the terminal.
///
/// The directory is the run's ground, and the ground is the identity of the
/// runner: root's is `/var/log`, and a run that is not root writes under its own
/// `~/Library/Logs/showup`. The two are the same shape - `showup<number>.log` -
/// so the naming, the retention and the prune are ground blind already.
///
/// Each line is appended with one `write(2)` on a descriptor opened once, rather
/// than a shell per line: a shell spawn per log line is a process per log line,
/// and this is the most frequent thing the program does.
public enum Log {
    /// The log file this run writes to, on the ground it runs on.
    public static let path = logPath()

    private static let descriptor: Int32 = {
        // Readable, not writable: the log is for the person who looks later, and
        // it is not a file an unprivileged user may alter - it is the runner's to
        // write and the directory is the runner's to name files in.
        let file = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o644)
        return file < 0 ? -1 : file
    }()

    /// Whether this run can write its log at all. On root's ground that without
    /// sudo is not so; on a user run's own ground the question is the run's own.
    public static var isWritable: Bool { descriptor >= 0 }

    /// Deletes logs of runs that ended more than a week ago, and says so.
    ///
    /// Best effort, before anything else is written: a directory that cannot be
    /// read prunes nothing and stays quiet about it.
    @discardableResult
    public static func pruneOldRuns(now: Date = Date()) -> Int {
        let directory = Ground.logDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return 0
        }
        var pruned = 0
        for name in names {
            let path = directory + "/" + name
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                let modified = attributes[.modificationDate] as? Date,
                prunableLog(name, isRegularFile: true, modified: modified, now: now)
            else {
                continue
            }
            do {
                try FileManager.default.removeItem(atPath: path)
                pruned += 1
            } catch {
                Log.write("WARNING could not prune old log \(path): \(error.localizedDescription)", to: .standardError)
            }
        }
        if pruned > 0 {
            Log.write("pruned \(pruned) of this program's older logs from \(directory)")
        }
        return pruned
    }

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
