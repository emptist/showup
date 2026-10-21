import Foundation

/// The boundary between the scheduler and the world.
///
/// Every value here is `@Sendable`, so the scheduler can hand the whole set to
/// the alarm without copying anything or worrying about what it captures. Tests
/// build one of these with a fake clock and a fake Mac, which is the only
/// reason the scheduler can be tested at all.
public struct Effects: Sendable {
    /// Seconds since local midnight.
    public var now: @Sendable () -> Int
    /// The real date, for the argument `pmset` has to be given in calendar terms.
    public var currentDate: @Sendable () -> Date
    /// Seconds on a clock that only ever moves forward.
    ///
    /// This is what a *duration* is measured with. The wall clock is a time of
    /// day, and a time of day is not a duration: it jumps an hour forward in
    /// spring and an hour back in autumn, and a wait counted on it would be an
    /// hour long or an hour short on the two days that matter. A monotonic
    /// clock is the same length on both sides of a clock change.
    ///
    /// It is not what *evidence* is read with: it stops while the Mac is
    /// suspended, and the seconds a sleep cost are exactly what the idle
    /// counter is asked about. That question keeps the wall clock.
    public var monotonicNow: @Sendable () -> Double
    /// Sleeps for the given number of seconds, stepped against the wall clock.
    public var sleep: @Sendable (Int) -> Void
    /// Asks the kernel to bring the Mac back in that many seconds.
    public var scheduleWake: @Sendable (Int) -> Result<Void, ShowError>
    /// Seconds since the last input, or `nil` if the counter cannot be read.
    public var idleSeconds: @Sendable () -> Int?
    /// Surfaces the app, launching it if it is not running.
    public var show: @Sendable (String) -> ShowOutcome
    /// Rings until somebody hits a key, or until `budget` seconds have gone by.
    public var alarm: @Sendable (Int?) -> AlarmOutcome
    /// Speaker volume, 0 to 100.
    public var outputVolume: @Sendable () -> Result<Int, ShowError>
    /// Sets the speaker volume, so the ring can be raised above silence.
    public var setOutputVolume: @Sendable (Int) -> Result<Void, ShowError>
    /// How long the Mac is configured to stay awake with nobody touching it.
    public var powerSettings: @Sendable () -> PowerSettings?
    /// Whether this wake can be heard, or only the machine's own maintenance.
    /// Takes the instant the RTC alarm was set for, which settles it.
    public var wakeKind: @Sendable (Int?) -> WakeKind
    /// What the kernel announced, or nil when the kernel would not say.
    public var powerCycle: @Sendable () -> PowerCycle?
    /// Whether the login has finished: nobody is sitting in front of a login
    /// window, waiting to type a password.
    public var loginFinished: @Sendable () -> Bool
    public var log: @Sendable (String) -> Void
    public var warn: @Sendable (String) -> Void

    public init(
        now: @escaping @Sendable () -> Int,
        currentDate: @escaping @Sendable () -> Date,
        monotonicNow: @escaping @Sendable () -> Double,
        sleep: @escaping @Sendable (Int) -> Void,
        scheduleWake: @escaping @Sendable (Int) -> Result<Void, ShowError>,
        idleSeconds: @escaping @Sendable () -> Int?,
        show: @escaping @Sendable (String) -> ShowOutcome,
        alarm: @escaping @Sendable (Int?) -> AlarmOutcome,
        outputVolume: @escaping @Sendable () -> Result<Int, ShowError>,
        setOutputVolume: @escaping @Sendable (Int) -> Result<Void, ShowError>,
        powerSettings: @escaping @Sendable () -> PowerSettings?,
        wakeKind: @escaping @Sendable (Int?) -> WakeKind,
        powerCycle: @escaping @Sendable () -> PowerCycle?,
        loginFinished: @escaping @Sendable () -> Bool,
        log: @escaping @Sendable (String) -> Void,
        warn: @escaping @Sendable (String) -> Void
    ) {
        self.now = now
        self.currentDate = currentDate
        self.monotonicNow = monotonicNow
        self.sleep = sleep
        self.scheduleWake = scheduleWake
        self.idleSeconds = idleSeconds
        self.show = show
        self.alarm = alarm
        self.outputVolume = outputVolume
        self.setOutputVolume = setOutputVolume
        self.powerSettings = powerSettings
        self.wakeKind = wakeKind
        self.powerCycle = powerCycle
        self.loginFinished = loginFinished
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