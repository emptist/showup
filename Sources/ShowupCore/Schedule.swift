import Foundation

/// How long before a wake the kernel is asked to bring the Mac back.
///
/// Asking it to wake *at* the time would make the app late every single time,
/// because the display coming up, the person waking, and the password all have
/// to happen inside the very minute the app was supposed to appear. So the
/// work is done ahead of the time and the window still goes up on the time.
public let dayLeadSeconds = 120
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
/// shorter than the lead has no lead left in it — the alarm then goes to the
/// required moment itself, because failing to reach the moment is not the same
/// failure as reaching it without the display's lead time. See `Scheduler.step`.
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
/// The calendar is the system's, followed live, so which zone the moment is
/// read in is the machine's business. In a zone without daylight saving there
/// is no such day, and the instant is simply the time of day it says it is.
///
/// A moment that has already arrived today is tomorrow's, by the same rule
/// `nextWake` answers it with: a whole day of delay. That includes the moment
/// that is arriving exactly now, which is what keeps a window served a second
/// early from being what a clamp of a day-minus-one did to it.
public func nextWakeAbsolute(
    _ times: [TimeOfDay], from now: Int, on date: Date, calendar: Calendar = .autoupdatingCurrent
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

/// The next `count` wakes, each with the instant it falls on, for `--dry-run`.
///
/// The cursor is the instant the last wake falls on rather than a time of day,
/// so each wake is measured from where the machine will actually be. It matters
/// on the two nights a year the clock changes: a 03:30 requirement read at 01:30
/// on the night the clocks go forward is two hours away as the wall clock
/// counts it and one hour away as the hours pass, and a plan that printed the
/// first number would be wrong by an hour about when the app appears.
///
/// A moment that has arrived exactly is tomorrow's by the same rule
/// `nextWakeAbsolute` answers it with, so the same wake is not listed twice and
/// the cursor always moves.
public func upcomingAbsolute(
    _ times: [TimeOfDay], from date: Date, count: Int, calendar: Calendar = .autoupdatingCurrent
) -> [(wake: Wake, target: Date)] {
    guard count > 0 else { return [] }
    var result: [(wake: Wake, target: Date)] = []
    var cursor = date
    for _ in 0..<count {
        guard let (wake, target) = nextWakeAbsolute(
            times, from: secondsSinceMidnight(cursor, calendar: calendar), on: cursor, calendar: calendar
        ) else { break }
        result.append((wake, target))
        cursor = target
    }
    return result
}