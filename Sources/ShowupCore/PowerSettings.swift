import Foundation

/// Where the Mac is drawing its power, which is the half of `pmset -g custom`
/// that applies right now.
public enum PowerSource: Equatable, Sendable {
    case battery
    case ac
}

/// How long the Mac is configured to stay awake with nobody touching it.
///
/// This is measured rather than assumed. The README used to claim "typically
/// 25-30 minutes" for a laptop; that is true often enough to be believed and
/// wrong often enough to matter, and a Mac set to `displaysleep 1` is a normal
/// thing to have.
public struct PowerSettings: Equatable, Sendable {
    public var source: PowerSource
    /// Minutes of no input before the display sleeps. Zero means never.
    public var displaySleepMinutes: Int
    /// Minutes of no input before the system sleeps. Zero means never.
    public var systemSleepMinutes: Int
    /// Whether Power Nap is allowed to hold the machine briefly awake.
    public var powerNap: Bool

    public init(source: PowerSource, displaySleepMinutes: Int, systemSleepMinutes: Int, powerNap: Bool) {
        self.source = source
        self.displaySleepMinutes = displaySleepMinutes
        self.systemSleepMinutes = systemSleepMinutes
        self.powerNap = powerNap
    }

    /// How long the Mac stays awake after a wake with nobody answering, in
    /// seconds.
    ///
    /// The display goes first, so the smaller of the two is the window in
    /// which anything showup does can actually be seen or heard. `nil` when
    /// either timer is disabled, because then the machine never sleeps on its
    /// own at all.
    public var idleWindowSeconds: Int? {
        let timers = [displaySleepMinutes, systemSleepMinutes]
            .filter { $0 > 0 }
            .map { $0 * 60 }
        return timers.min()
    }

    /// Whether the machine will ever put itself to sleep.
    public var neverSleeps: Bool {
        idleWindowSeconds == nil
    }
}

// MARK: - Reading pmset

/// Reads the settings for whichever power source is in use.
public func readPowerSettings(ps psOutput: String, custom: String) -> PowerSettings? {
    guard let source = parsePowerSource(psOutput) else { return nil }
    return parsePowerSettings(custom, source: source)
}

/// `Now drawing from 'AC Power'` is the line that decides which half of
/// `pmset -g custom` means anything.
public func parsePowerSource(_ output: String) -> PowerSource? {
    for line in output.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("AC Power") { return .ac }
        if trimmed.contains("Battery Power") { return .battery }
    }
    return nil
}

/// Verbatim from `pmset -g custom`, which prints one block per power source.
///
/// `displaysleep` is in minutes and `0` means never; anything unparseable is
/// left at zero, which reads as "never sleeps" and so fails towards leaving
/// the machine awake.
public func parsePowerSettings(_ output: String, source: PowerSource) -> PowerSettings? {
    let wanted = source == .ac ? "AC Power" : "Battery Power"
    var block: [String] = []
    var inBlock = false

    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("Power:") {
            // The first matching header wins; "Sleep On Power Button" and
            // friends are values, not headers.
            if inBlock { break }
            inBlock = trimmed.hasPrefix(wanted)
            continue
        }
        if inBlock { block.append(trimmed) }
    }

    guard inBlock, !block.isEmpty else { return nil }
    return PowerSettings(
        source: source,
        displaySleepMinutes: minutes(in: block, key: "displaysleep"),
        systemSleepMinutes: minutes(in: block, key: "sleep"),
        powerNap: value(in: block, key: "powernap") == "1"
    )
}

private func minutes(in block: [String], key: String) -> Int {
    Int(value(in: block, key: key) ?? "0") ?? 0
}

/// The word after `key`, matched on a whole word so `powernap` never picks up
/// `powernaptimer` and `sleep` never picks up `standbydelayhigh`.
private func value(in block: [String], key: String) -> String? {
    for line in block {
        let fields = line.split(separator: " ").map(String.init)
        guard fields.count >= 2, fields[0] == key else { continue }
        return fields[1]
    }
    return nil
}

// MARK: - What it means for a wake

/// What the machine's own timers say about whether a wake can be completed.
///
/// The bias is toward saying the useful thing out loud: showup's whole job
/// after a wake is to turn the display on, ring, and wait for a login, and if
/// the Mac is configured to drop the display before that work is done, the
/// wake is theatre whether the code believes it or not.
public struct IdleWindowReport: Equatable, Sendable {
    /// What the machine is set to do, in one sentence.
    public var summary: String
    /// What that costs showup, where it costs anything.
    public var warnings: [String]

    public init(summary: String, warnings: [String]) {
        self.summary = summary
        self.warnings = warnings
    }
}

public func auditIdleWindow(_ settings: PowerSettings?) -> IdleWindowReport {
    guard let settings else {
        return IdleWindowReport(
            summary: "could not read the power settings, so the idle timers are unknown",
            warnings: ["the machine's own idle timers could not be read, so a wake cannot be checked against them"]
        )
    }

    let timers = "displaysleep \(settings.displaySleepMinutes)m, sleep \(settings.systemSleepMinutes)m"
    let source = settings.source == .ac ? "on AC power" : "on battery"

    guard let window = settings.idleWindowSeconds else {
        return IdleWindowReport(
            summary: "this Mac is set never to sleep on its own \(source) (\(timers)), so a wake has all the time it needs",
            warnings: []
        )
    }

    var warnings: [String] = []
    if window < loginTimeoutSeconds {
        warnings.append(
            """
            the machine sleeps on its own after \(describeDelay(window)), which is shorter than the \
            \(loginTimeoutSeconds)s showup may spend waiting for login: a wake can time out \
            before the display ever comes back
            """
        )
    }

    return IdleWindowReport(
        summary: "this Mac sleeps on its own after \(describeDelay(window)) without input \(source) (\(timers))",
        warnings: warnings
    )
}