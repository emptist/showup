/// How long before a wake the kernel is asked to bring the Mac back.
///
/// Asking it to wake *at* the time would make the app late every single time,
/// because the display coming up, the person waking, and the password all have
/// to happen inside the very minute the app was supposed to appear. So the
/// work is done ahead of the time and the window still goes up on the time.
public let dayLeadSeconds = 60
public let nightLeadSeconds = 300

/// After this long missing the plan, stop pretending it is still the plan.
public let resyncAfterSeconds = 60

/// How long to wait for the login window to go away before giving up on it.
public let loginTimeoutSeconds = 120

/// Below this the alarm is playing into a speaker nobody can hear.
public let quietVolume = 30

/// Whether the kernel is told to wake at `ahead` or `delay`, and how much of the
/// window is left afterwards for the rousing and the wait.
public func leadSplit(delaySeconds: Int, leadSeconds: Int) -> (ahead: Int, remaining: Int) {
    if delaySeconds >= leadSeconds {
        return (delaySeconds - leadSeconds, leadSeconds)
    }
    return (delaySeconds, 0)
}

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

/// Where the next iteration should start counting from.
///
/// If the machine slept through a wake the plan is a fiction, so the clock
/// takes over again rather than the loop chasing an instant it can never reach.
public func nextInstant(planned: Int, delay: Int, now: Int) -> Int {
    let target = planned + delay
    return secondsBetween(target, now) > resyncAfterSeconds ? now : target
}