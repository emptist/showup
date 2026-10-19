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

    /// The idle timers, read once and cached.
    ///
    /// `pmset -g custom` is still the only way to read these. IOPSCopyPower
    /// SettingsInfo and IOPMCopyCustomPowerProfiles are not in the SDK, so
    /// there is no documented replacement and shelling out is the honest
    /// answer rather than a shortcut.
    static let configuredPowerSettings: PowerSettings? = {
        guard case .success(let ps) = Mac.run("/usr/bin/pmset", ["-g", "ps"]),
              case .success(let custom) = Mac.run("/usr/bin/pmset", ["-g", "custom"])
        else {
            return nil
        }
        return readPowerSettings(ps: ps, custom: custom)
    }()

    /// The kind of wake we are in, read from the power log.
    ///
    /// Only the wake lines, narrowed by the shell because `pmset -g log` runs to
    /// several megabytes and everything showup needs is in the last one.
    static func currentWakeKind(requestedAt: Int?) -> WakeKind {
        let query = "log | /usr/bin/grep -E ' (Wake|DarkWake) ' | /usr/bin/tail -1"
        guard case .success(let line) = Mac.run("/bin/sh", ["-c", "/usr/bin/pmset -g \(query)"]) else {
            return .unknown
        }
        return newestWake(line, now: secondsSinceMidnight(Date()), requestedAt: requestedAt)
    }

    static func playSound(_ sound: String) -> Result<Void, ShowError> {
        Mac.run("/usr/bin/afplay", [sound]).map { _ in () }
    }

    // MARK: - Waking the Mac

}
