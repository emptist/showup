import Foundation

/// Which build of this program is running, read from a stamp the Makefile
/// writes next to the binary.
///
/// The logs were the only evidence a bug left, and they said nothing about
/// which binary produced them. Three different binaries wrote logs on one
/// day, and defects that were already fixed kept being rediscovered in runs
/// made by code that carried the fix. One line at startup ends that:
/// `build 0404c92 2026-10-22 13:53 +0800`.
///
/// `swift build` without the Makefile makes no stamp, and the run then says so
/// plainly rather than inventing one - a line that lies would be worse than no
/// line, and silence is what hides the stale binary again.
@discardableResult
public func readBuildStamp(
    argument: String = CommandLine.arguments[0],
    path: String? = ProcessInfo.processInfo.environment["PATH"],
    workingDirectory: String = FileManager.default.currentDirectoryPath
) -> String? {
    guard let executable = executablePath(argument, path: path, workingDirectory: workingDirectory),
        let raw = try? String(contentsOfFile: executable + ".stamp", encoding: .utf8)
    else {
        return nil
    }
    let line = raw.split(separator: "\n").first.map(String.init)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return line.isEmpty ? nil : line
}

/// Where the running binary is, given `argv[0]`, which may be a plain name the
/// shell resolved through `PATH`, a relative path, or an absolute one.
internal func executablePath(
    _ argument: String, path: String?, workingDirectory: String
) -> String? {
    if argument.hasPrefix("/") {
        return resolvingSymlinks(argument)
    }
    if argument.contains("/") {
        return resolvingSymlinks(workingDirectory + "/" + argument)
    }
    for directory in (path ?? "").split(separator: ":") {
        let candidate = "\(directory)/\(argument)"
        if FileManager.default.fileExists(atPath: candidate) {
            return resolvingSymlinks(candidate)
        }
    }
    return nil
}

/// Resolves the symlink chain of a file path, for a binary reached through a
/// link such as `/usr/local/bin/showup` would be.
private func resolvingSymlinks(_ candidate: String) -> String {
    URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
}
