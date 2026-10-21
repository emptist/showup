import Foundation

/// How long before a wake the kernel is asked to bring the Mac back.
///
/// Asking it to wake *at* the time would make the app late every single time,
/// because the display coming up, the person waking, and the password all have
/// to happen inside the very minute the app was supposed to appear. So the
/// work is done ahead of the time and the window still goes up on the time.
public let dayLeadSeconds = 60
public let nightLeadSeconds = 300

/// Below this the alarm is playing into a speaker nobody can hear.
public let quietVolume = 30

/// What the speaker is raised to before the alarm rings, when it is quieter
/// than this.
public let ringVolume = 20

/// How long before a wake the kernel is asked to bring the Mac back, for the
/// hour the required time falls in.
///
/// The scheduler takes the whole lead off the front of the wait, so a wait
/// shorter than the lead is not woken for at all and the window simply waits for
/// the time it exists for.
public func leadFor(hour: Int) -> Int {
    isNight(hour) ? nightLeadSeconds : dayLeadSeconds
}

/// 22:00 to 06:59 is when the Mac is usually asleep and a person has to be woken.
func isNight(_ hour: Int) -> Bool {
    hour >= 22 || hour < 7
}

/// The soonest of `times`, counting a time that has passed today as tomorrow's.
public func nextWake(_ times: [TimeOfDay], from now: Int) -> Wake? {
    times
        .map { at -> Wake in
            var until = at.secondsSinceMidnight - (now % secondsPerDay)
            if until <= 0 { until += secondsPerDay }
            return Wake(at: at, delay: until)
        }
        .min { $0.delay < $1.delay }
}

/// The soonest of `times`, with the wall-clock instant it falls on.
///
/// `nextWake` answers in seconds, and a second is not the same length as a
/// second of the calendar on the two days of the year when the clock changes:
/// a 02:30 requirement on the day the clocks go forward is 30 minutes away as
/// the wall clock counts it, and 90 minutes away as the afternoon arrives. The
/// instant is settled by the calendar instead - `date(bySettingHour:)` knows
/// which of those hours exist - so a wait measured to the instant is measured
/// in the seconds that will actually pass.
///
/// A moment that has already arrived today is tomorrow's, by the same rule
/// `nextWake` answers it with: a whole day of delay. That includes the moment
/// that is arriving exactly now, which is what keeps a window served a second
/// early from being what a clamp of a day-minus-one did to it.
public func nextWakeAbsolute(
    _ times: [TimeOfDay], from now: Int, on date: Date, calendar: Calendar = .current
) -> (wake: Wake, target: Date)? {
    guard let wake = nextWake(times, from: now) else { return nil }

    let today = calendar.date(bySettingHour: wake.at.hour, minute: wake.at.minute, second: 0, of: date)
    guard let today else { return nil }
    // A requirement whose moment has arrived is tomorrow's. The comparison is
    // between instants, not between times of day, so it holds across a clock
    // change as well.
    let target = today > date ? today : calendar.date(byAdding: .day, value: 1, to: today)
    guard let target else { return nil }
    return (wake, target)
}

/// The next `count` wakes, for `--dry-run`.
public func upcoming(_ times: [TimeOfDay], from now: Int, count: Int) -> [Wake] {
    guard count > 0 else { return [] }
    var result: [Wake] = []
    var cursor = now
    for _ in 0..<count {
        guard let wake = nextWake(times, from: cursor) else { break }
        result.append(wake)
        cursor = (cursor + wake.delay) % secondsPerDay
    }
    return result
}