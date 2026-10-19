import Foundation
import ShowupCore

/// Every command this program runs, and every parser for what those
/// commands print. Namespaced so `Effects`' hooks and the functions that
/// implement them are never confused for one another.
enum Mac {

    // MARK: - Running commands

    /// Runs a command and collects everything it wrote, in one pass.
    ///
    /// The output is drained *before* waiting on the child. Waiting first is the
    /// classic deadlock: a child that writes more than the pipe buffer fills blocks
    /// forever, and the parent is blocked in `waitUntilExit` waiting for it.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> Result<String, ShowError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return .failure(.unavailable(what: executable, reason: "\(error)"))
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(
                .failed(
                    command: "\(URL(fileURLWithPath: executable).lastPathComponent) \(arguments.joined(separator: " "))",
                    status: process.terminationStatus,
                    detail: detail
                )
            )
        }
        return .success(output)
    }

    // MARK: - The idle counter

    /// How long the keyboard and mouse have been untouched, in whole seconds.
    ///
    /// `nil` when it cannot be read, which is a different thing from zero: zero
    /// means the user is at the machine, and the alarm treats the two very
    /// differently.
    static func idleSeconds() -> Int? {
        guard case .success(let report) = Mac.run("/usr/sbin/ioreg", ["-r", "-c", "IOHIDSystem", "-d1"]) else {
            return nil
        }
        return try? parseIdleSeconds(report)
    }

    /// Verbatim from a real `ioreg -r -c IOHIDSystem -d1`.
    ///
    /// `ioreg` reports the counter in nanoseconds, so every path through this
    /// divides — including the one where the field is the last line of the report
    /// and has no newline after it.
    public static func parseIdleSeconds(_ report: String) throws(ShowError) -> Int {
        guard let marker = report.range(of: "\"HIDIdleTime\" = ") else {
            throw ShowError.unavailable(what: "HIDIdleTime", reason: "ioreg did not report it")
        }
        let after = report[marker.upperBound...]
        let field = after.prefix { $0 != "\n" }
        guard let nanoseconds = Int(field.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ShowError.unavailable(what: "HIDIdleTime", reason: "\"\(field)\" is not a number")
        }
        return nanoseconds / 1_000_000_000
    }

    // MARK: - The console session

    /// One query for the console user's uid, which is what `launchctl asuser` needs
    /// in order to put a window in the right session.
    static func scutilQuery() -> Result<String, ShowError> {
        Mac.run("/bin/sh", ["-c", "echo 'show State:/Users/ConsoleUser' | /usr/sbin/scutil"])
    }

    static func consoleUID() -> Result<Int, ShowError> {
        switch scutilQuery() {
        case .failure(let reason):
            return .failure(reason)
        case .success(let output):
            do {
                return .success(try parseUID(output))
            } catch {
                return .failure(error)
            }
        }
    }

    /// The uid of the person at the console.
    ///
    /// showup is started after login and stopped before logout, so there is
    /// always a session here; a zero would mean something has ended it.
    ///
    /// This matches a whole line that starts with `UID : `, not a substring. The
    /// substring form also matched the tail of `CGSSessionUniqueSessionUUID : ...`,
    /// so it failed on every real input and the app was never surfaced at all —
    /// while every test passed, because every test supplied a fake.
    public static func parseUID(_ output: String) throws(ShowError) -> Int {
        let key = "UID :"
        guard let line = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { $0.hasPrefix(key) })
        else {
            throw ShowError.unavailable(what: "console user", reason: "no UID line in scutil output")
        }

        guard let uid = Int(line.dropFirst(key.count).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ShowError.unavailable(what: "console user", reason: "the UID line is not a number")
        }
        guard uid != 0 else {
            throw ShowError.unavailable(what: "console user", reason: "the console is at the login window")
        }
        return uid
    }

    // MARK: - Surfacing

    /// Whether macOS already knows about an app, so the log can say "surfaced"
    /// rather than claiming to have launched it.
    static func isRunning(_ app: String) -> Bool {
        guard case .success(let record) = Mac.run("/usr/bin/lsappinfo", ["info", app]) else { return false }
        return !record.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `open -a` in the console user's session, which is the one that has a
    /// desktop to bring a window to.
    static func showApp(_ app: String) -> ShowOutcome {
        let wasRunning = isRunning(app)
        switch consoleUID() {
        case .failure(let reason):
            return .failed(reason.description)
        case .success(let uid):
            switch Mac.run("/bin/launchctl", ["asuser", String(uid), "/usr/bin/open", "-a", app]) {
            case .failure(let reason):
                return .failed(reason.description)
            case .success:
                return wasRunning ? .surfaced : .launched
            }
        }
    }

    // MARK: - Sound and volume

    /// The idle timers, read once and cached: they do not change while the
    /// program runs, and `pmset -g custom` is two command runs.
    static let configuredPowerSettings: PowerSettings? = {
        guard case .success(let ps) = Mac.run("/usr/bin/pmset", ["-g", "ps"]),
              case .success(let custom) = Mac.run("/usr/bin/pmset", ["-g", "custom"])
        else {
            return nil
        }
        return readPowerSettings(ps: ps, custom: custom)
    }()

    static func speakerVolume() -> Result<Int, ShowError> {
        Mac.run("/usr/bin/osascript", ["-e", "output volume of (get volume settings)"]).flatMap { answer in
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let volume = Int(trimmed) else {
                return .failure(.unexpectedOutput(what: "volume", sample: trimmed))
            }
            return .success(volume)
        }
    }

    static func playSound(_ sound: String) -> Result<Void, ShowError> {
        Mac.run("/usr/bin/afplay", [sound]).map { _ in () }
    }

    // MARK: - Waking the Mac

    /// Asks the kernel to bring the Mac back in that many seconds.
    static func scheduleWake(in seconds: Int) -> Result<Void, ShowError> {
        Mac.run("/usr/bin/pmset", ["schedule", "wake", pmsetDatetime(now: Date(), secondsFromNow: seconds)])
            .map { _ in () }
    }
}
