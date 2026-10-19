import Foundation

/// The boundary between the scheduler and the world.
///
/// Every value here is `@Sendable`, so the scheduler can hand the whole set to
/// the alarm's own queue without copying anything or worrying about what it
/// captures. Tests build one of these with a fake clock and a fake Mac, which is
/// the only reason the scheduler can be tested at all.
public struct Effects: Sendable {
    /// Seconds since local midnight.
    public var now: @Sendable () -> Int
    /// The real date, for the argument `pmset` has to be given in calendar terms.
    public var currentDate: @Sendable () -> Date
    /// Sleeps for the given number of seconds, stepped against the wall clock.
    public var sleep: @Sendable (Int) -> Void
    /// Asks the kernel to bring the Mac back in that many seconds.
    public var scheduleWake: @Sendable (Int) -> Result<Void, ShowError>
    /// Seconds since the last input, or `nil` if the counter cannot be read.
    public var idleSeconds: @Sendable () -> Int?
    /// Surfaces the app, launching it if it is not running.
    public var show: @Sendable (String) -> ShowOutcome
    /// Rings until somebody answers. Runs on its own queue.
    public var alarm: @Sendable () -> AlarmOutcome
    /// Speaker volume, 0 to 100.
    public var outputVolume: @Sendable () -> Result<Int, ShowError>
    /// How long the Mac is configured to stay awake with nobody touching it.
    public var powerSettings: @Sendable () -> PowerSettings?
    /// Whether this wake can be heard, or only the machine's own maintenance.
    public var wakeKind: @Sendable () -> WakeKind
    public var log: @Sendable (String) -> Void
    public var warn: @Sendable (String) -> Void

    public init(
        now: @escaping @Sendable () -> Int,
        currentDate: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Int) -> Void,
        scheduleWake: @escaping @Sendable (Int) -> Result<Void, ShowError>,
        idleSeconds: @escaping @Sendable () -> Int?,
        show: @escaping @Sendable (String) -> ShowOutcome,
        alarm: @escaping @Sendable () -> AlarmOutcome,
        outputVolume: @escaping @Sendable () -> Result<Int, ShowError>,
        powerSettings: @escaping @Sendable () -> PowerSettings?,
        wakeKind: @escaping @Sendable () -> WakeKind,
        log: @escaping @Sendable (String) -> Void,
        warn: @escaping @Sendable (String) -> Void
    ) {
        self.now = now
        self.currentDate = currentDate
        self.sleep = sleep
        self.scheduleWake = scheduleWake
        self.idleSeconds = idleSeconds
        self.show = show
        self.alarm = alarm
        self.outputVolume = outputVolume
        self.powerSettings = powerSettings
        self.wakeKind = wakeKind
        self.log = log
        self.warn = warn
    }
}

/// The longest single sleep, in seconds.
///
/// A monotonic timer stops while the system is suspended, so a 396 second sleep
/// returns after 396 seconds of *uptime* — every second the Mac spent asleep is
/// added to the wait. Stepping bounds the overshoot to one step.
public let sleepStepSeconds = 10

/// The next step of a stepped wait, or `nil` when the target has been reached.
///
/// `budget` is how much of the wait is left; if the wall clock has already run
/// past the target there is nothing to sleep, which is what stops a machine
/// that was asleep from being slept for twice.
public func nextSleepStep(target: Int, now: Int, budget: Int) -> Int? {
    let ahead = (target - now + secondsPerDay) % secondsPerDay
    guard ahead > 0, ahead <= budget else { return nil }
    return min(ahead, sleepStepSeconds)
}