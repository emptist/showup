import Foundation

/// Seconds on a clock that only ever moves forward.
///
/// `mach_absolute_time` is the one clock on macOS that is the same length on
/// both sides of a clock change and never goes backwards, which is what a
/// duration has to be measured with: a time of day jumps an hour in spring
/// and an hour back in autumn, and a wait counted on it is an hour long or an
/// hour short on the two days that matter.
///
/// It stops while the Mac is suspended. That is why it measures durations and
/// not evidence: the seconds a sleep cost are exactly what the idle counter is
/// asked about, and a clock that slept through the sleep would answer "none".
public func monotonicSeconds() -> Double {
    let ticks = mach_absolute_time()
    let nanos = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
    return nanos / 1_000_000_000
}

/// The conversion from ticks to nanoseconds, read once: it is a property of
/// the machine and does not change while the program runs.
private let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()
