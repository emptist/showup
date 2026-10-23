/// The alarm's knobs, so tests can run it without waiting for real time.
public struct AlarmOptions: Equatable, Sendable {
    /// Seconds between rings.
    public var between: Int
    /// Give up after the sound fails this many times. An audio device that is
    /// still coming up after a wake fails the first few plays.
    public var playFailures: Int
    /// How long the alarm may ring before it concludes this wake has failed.
    ///
    /// This is the machine's own idle window, measured. `nil` when there is no
    /// deadline to work to, which is not the same as never: the Mac going back
    /// to sleep ends the alarm too.
    public var budget: Int?

    public init(
        between: Int = ringBetweenSeconds,
        playFailures: Int = defaultPlayFailures,
        budget: Int? = nil
    ) {
        self.between = between
        self.playFailures = playFailures
        self.budget = budget
    }
}

/// What the alarm needs from the machine. It blocks the caller on purpose, so
/// it must not need anything else.
public protocol AlarmEffects: Sendable {
    /// Seconds since local midnight, to tell a wait that ended on time from one
    /// the machine spent asleep.
    var now: @Sendable () -> Int { get }
    /// Seconds since the last key was pressed, or `nil` when the counter cannot
    /// be read at all. Keys only: a hand on the keyboard is what answers, and a
    /// trackpad twitch while nobody is there is not.
    var keyboardIdleSeconds: @Sendable () -> Int? { get }
    var play: @Sendable (String) -> Result<Void, ShowError> { get }
    var sleep: @Sendable (Int) -> Void { get }
}

public let ringBetweenSeconds = 5
public let defaultPlayFailures = 40

/// How many seconds into the alarm a key press counts as the answer from.
///
/// Keys that landed before the alarm started are the machine's own - the wake
/// itself, a `sudo` password typed a minute before it - and the counter cannot
/// be told to exclude them directly, because the counter restarts with the
/// wake and so does this alarm's view of it. Five seconds of grace is what
/// separates a hand that is typing now from the bookkeeping that just woke
/// the machine, and it is narrower than the gap between ring and ring, so a
/// hand anywhere near the keyboard is answered within the first ring or two.
public let keyAnswerToleranceSeconds = 5

public let ringbackTone = """
    /System/Library/Components/CoreAudio.component/Contents/SharedSupport/\
    SystemSounds/facetime/multiway_invitation.caf
    """

/// Rings until somebody hits a key, or until this wake is no longer worth
/// anything: the machine is due to sleep again and nobody came.
public func alarmRing(_ options: AlarmOptions, _ effects: AlarmEffects) -> AlarmOutcome {
    ring(options, effects, wokeAt: effects.now(), rings: 0, elapsed: 0, failures: 0)
}

private func ring(
    _ options: AlarmOptions,
    _ effects: AlarmEffects,
    wokeAt: Int,
    rings: Int,
    elapsed: Int,
    failures: Int
) -> AlarmOutcome {
    var rings = rings
    var elapsed = elapsed
    var failures = failures

    while true {
        let played: Bool
        switch effects.play(ringbackTone) {
        case .success:
            rings += 1
            played = true
        case .failure(let reason):
            failures += 1
            guard failures < options.playFailures else { return .silent(reason: reason.description) }
            played = false
        }

        let stayedUp = waited(effects, options.between)
        elapsed += options.between

        // A key press since the alarm started is the answer, however it is
        // sampled: the counter is read against the wall clock since the alarm
        // started, never against the reading before this one. Measured on a
        // real afternoon: four rings went out at a person who was continuously
        // typing their password at the login window, because samples taken a
        // few seconds apart climb as well as fall while somebody is right
        // there at the keyboard.
        let idleNow = effects.keyboardIdleSeconds()
        let since = secondsBetween(wokeAt, effects.now())
        if answered(idleNow: idleNow, since: since) {
            return .rung(rings: rings)
        }

        // The Mac is about to go down again with nobody there, so this wake has
        // passed and there is nothing left to ring for. Either way the loop gets
        // back to arming the next wake instead of parking here.
        if !stayedUp { return .failed(rings: rings) }
        if let budget = options.budget, elapsed >= budget { return .failed(rings: rings) }

        failures = played ? 0 : failures
    }
}

/// Waits, and reports whether the machine was up for the whole of it.
///
/// Nobody answered, so the Mac went back to sleep on its own idle timer, and a
/// sleeping Mac cannot ring. The wait is how the alarm finds out: `Thread.sleep`
/// counts uptime and does not advance while the system is suspended, so a five
/// second sleep returns far later than five seconds in wall clock terms if the
/// machine went down. Stopping here is what clears up the failed wake, because
/// the loop gets back to arming the next one instead of resuming this ring
/// whenever the Mac next comes up.
private func waited(_ effects: AlarmEffects, _ seconds: Int) -> Bool {
    let started = effects.now()
    effects.sleep(seconds)
    let elapsed = (effects.now() - started + secondsPerDay) % secondsPerDay
    return elapsed <= seconds + awakeToleranceSeconds
}

/// Whether a key has been pressed since the alarm started.
///
/// The counter reads seconds since the last key, and it restarts with the
/// wake the alarm serves, so against a wall clock anchored at the alarm's own
/// start it sits level while nobody is there and takes a permanent fall the
/// moment a hand lands on the keyboard. That is why the reading is not
/// compared with the one before it: samples taken a few seconds apart climb
/// as often as they fall, and a password being typed in one continuous stream
/// produced readings that never fell - measured, four rings went out at
/// somebody who was typing the whole time.
///
/// `keyAnswerToleranceSeconds` is the slack, for the counter restarting a
/// moment behind the alarm's clock and for a reading taken a few seconds
/// after its key. Keys in that first stretch are the wake's own bookkeeping,
/// not a hand; anything typed after is - including a password at a login
/// window, which is exactly the person this alarm exists to fetch.
private func answered(idleNow: Int?, since woke: Int) -> Bool {
    guard let idleNow else { return false }   // unreadable: no evidence, keep ringing
    return idleNow + keyAnswerToleranceSeconds < woke
}