/// What the keyboard idle counter can prove about a wait.
///
/// The counter runs only while the machine is up, so it freezes across a sleep
/// and resumes where it stopped. Two readings and the length of the wait settle
/// it: a machine that stayed up would have advanced the counter by the length
/// of the wait.
public enum SleepEvidence: Equatable {
    /// The counter advanced with the wall clock. The Mac never went down.
    case awake
    /// The counter went backwards, which only happens when input arrives.
    /// The machine was up and somebody was using it.
    case inputArrived
    /// The counter barely moved while the wall clock ran on.
    case slept
    /// `ioreg` could not be read, so nothing is known.
    case unreadable

    /// A wake we should treat as having had to rouse somebody. Unknown counts
    /// as asleep, deliberately: raising a window at a machine nobody is looking
    /// at achieves nothing, and the ring costs a few seconds of noise.
    public var wokeTheUser: Bool {
        self != .awake && self != .inputArrived
    }

    /// The line that goes in the log, carrying the numbers it was decided from.
    ///
    /// A wake that rings when it should not, or stays silent when it should
    /// not, is otherwise undiagnosable after the fact.
    public func report(idleBefore: Int?, idleAfter: Int?, elapsed: Int) -> String {
        let counter = "\(idleBefore.map { "\($0)s" } ?? "?") -> \(idleAfter.map { "\($0)s" } ?? "?")"
        return switch self {
        case .awake:
            "the Mac was awake throughout (idle \(counter) over \(elapsed)s), nothing to wake"
        case .inputArrived:
            "input arrived during the wait (idle \(counter) over \(elapsed)s), so the Mac was up"
        case .slept:
            "the Mac was asleep (idle \(counter) over \(elapsed)s), waking you up first"
        case .unreadable:
            "the idle counter could not be read, so this is treated as a sleep (over \(elapsed)s)"
        }
    }
}

/// How far short of the wall clock the idle counter may fall and still count as
/// a machine that stayed up. One step of the sleep loop, plus the slack of a
/// counter that ticks on its own schedule.
public let awakeToleranceSeconds = 10

/// Decides whether the Mac was asleep during a wait, from two idle readings.
public func sleepEvidence(idleBefore: Int?, idleAfter: Int?, elapsed: Int) -> SleepEvidence {
    guard let before = idleBefore, let after = idleAfter else { return .unreadable }

    let advanced = after - before
    if advanced < 0 { return .inputArrived }
    return advanced + awakeToleranceSeconds < elapsed ? .slept : .awake
}