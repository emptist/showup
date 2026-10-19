import Foundation

/// What kind of wake the machine actually came back from.
///
/// The alarm is only worth anything if somebody can hear it, and a DarkWake is
/// the machine coming up for network and mail maintenance with the screen still
/// off. Nothing can be seen or heard during one, and a ring started there is
/// theatre. A DarkWake is logged as such by powerd, which is the only signal
/// available: `pmset -g powerstate` returns "Internal failure" on this hardware.
public enum WakeKind: Equatable, Sendable {
    /// A wake a person could hear: the machine came all the way up.
    case full
    /// Maintenance only. The screen is off and stays off.
    case dark
    /// The log does not say, or says something too old to be this wake.
    case unknown
}

/// How far back a wake entry may be and still be counted as this wake.
public let wakeEvidenceWindowSeconds = 90

/// The kind of the wake we are in the middle of.
///
/// The log is written by powerd, which has not necessarily recorded our wake by
/// the time we ask, so a stale entry must not be read as ours: if the newest
/// wake in the log is older than the window, the honest answer is `unknown`,
/// which rings rather than going quiet. That is the direction that fails into
/// noise instead of into silence.
public func newestWake(_ log: String, now: Int) -> WakeKind {
    guard let newest = latestWakeEvent(log) else { return .unknown }
    guard secondsBetween(newest.at, now) <= wakeEvidenceWindowSeconds else { return .unknown }
    return newest.kind
}

struct WakeEvent: Equatable {
    var at: Int
    var kind: WakeKind
}

/// The last `Wake` or `DarkWake` line in the log, which `pmset` prints oldest
/// first, so position already is the chronology.
func latestWakeEvent(_ log: String) -> WakeEvent? {
    var newest: WakeEvent?
    for line in log.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let event = wakeEvent(String(line)) else { continue }
        newest = event
    }
    return newest
}

func wakeEvent(_ line: String) -> WakeEvent? {
    let fields = line.split(separator: " ", omittingEmptySubsequences: true)
    guard fields.count >= 5 else { return nil }

    // 2026-10-19 10:34:00 +0800 DarkWake  DarkWake from Deep Idle ...
    let parts = fields[1].split(separator: ":")
    guard parts.count == 3, let hour = Int(parts[0]), let minute = Int(parts[1]), let second = Int(parts[2])
    else {
        return nil
    }

    let kind: WakeKind
    switch fields[3] {
    case "Wake": kind = .full
    case "DarkWake": kind = .dark
    default: return nil
    }
    return WakeEvent(at: hour * 3_600 + minute * 60 + second, kind: kind)
}