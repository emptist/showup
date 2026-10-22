import Darwin
import Foundation

/// One instance at a time, decided by the kernel rather than by accident.
///
/// Two runs were live at once on 19-20 October: an older one nobody had
/// noticed next to the newer experiments, both arming RTC wakes and both
/// surfacing the app, which is how a wake stayed armed for days. The lock is
/// held for the life of the process on a file descriptor that the kernel
/// closes on exit and on death, so a crash releases it and it leaves nothing
/// behind for the next run to be confused by.
public enum InstanceLock {
    /// The file the lock is held on, on the ground the run takes it on: root's
    /// ground holds it under `/var/log`, and a run that is not root holds it
    /// under its own support directory.
    public static var path: String { Ground.lockPath(directory: Ground.lockDirectory) }

    /// Takes the lock, or explains the run that holds it.
    ///
    /// Returns `false` when another instance already holds the lock, or when
    /// this run could not take a lock on a ground it owns and has nothing to
    /// fall back to; a lock that could not even be created on root's ground is a
    /// warning and a run without a lock, because those runs cannot arm wakes
    /// anyway.
    @discardableResult
    public static func hold() -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW, 0o644)
        guard fd >= 0 else {
            if Ground.isRoot {
                FileHandle.standardError.write(
                    Data("showup: cannot place the instance lock (running without sudo); this run is not locked\n".utf8)
                )
                return true
            }
            FileHandle.standardError.write(
                Data("showup: cannot place the instance lock at \(path); this run cannot proceed without one\n".utf8)
            )
            return false
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let status = errno
            close(fd)
            guard status == EWOULDBLOCK else {
                FileHandle.standardError.write(
                    Data("showup: could not take the instance lock at \(path) (error \(status))\n".utf8)
                )
                return true
            }
            let running = pid(at: path).map { " (pid \($0))" } ?? ""
            FileHandle.standardError.write(
                Data("showup: another showup is running\(running); this run stops\n".utf8)
            )
            return false
        }
        heldDescriptor = fd
        recordPID(fd)
        return true
    }

    /// The descriptor the lock is held on, kept for the life of the process:
    /// a DispatchSource that is released is cancelled, and so is a flock whose
    /// descriptor a released closure would close.
    private nonisolated(unsafe) static var heldDescriptor: Int32 = -1

    /// Writes the pid, so a second run's message names the first one. The file
    /// is emptied first: a pid shorter than the one written before it would
    /// otherwise leave the tail of that one behind, and the reader would report
    /// a pid that never held the lock.
    private static func recordPID(_ fd: Int32) {
        _ = lseek(fd, 0, SEEK_SET)
        _ = ftruncate(fd, 0)
        _ = "showup \(getpid())".withCString {
            write(fd, $0, strlen($0))
        }
    }

    private static func pid(at path: String) -> Int? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return raw.split(separator: " ").last.flatMap { Int($0) }
    }
}
