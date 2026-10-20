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

/// What the alarm needs from the machine. It runs on its own queue and must
/// not need anything else.
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

public let ringbackTone = """
    /System/Library/Components/CoreAudio.component/Contents/SharedSupport/\
    SystemSounds/facetime/multiway_invitation.caf
    """

/// Rings until somebody hits a key, or until this wake is no longer worth
/// anything: the machine is due to sleep again and nobody came.
public func alarmRing(_ options: AlarmOptions, _ effects: AlarmEffects) -> AlarmOutcome {
    // Read before the first ring, so the ring itself, or a sudo password typed
    // moments ago, cannot be mistaken for the user answering.
    ring(options, effects, previous: effects.keyboardIdleSeconds(), rings: 0, elapsed: 0, failures: 0)
}

private func ring(
    _ options: AlarmOptions,
    _ effects: AlarmEffects,
    previous: Int?,
    rings: Int,
    elapsed: Int,
    failures: Int
) -> AlarmOutcome {
    var previous = previous
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

        let idleNow = effects.keyboardIdleSeconds()
        if answered(idleNow: idleNow, previous: previous) {
            return .rung(rings: rings)
        }
        // Compared against the reading before this one, not against the one
        // taken before the first ring. The counter only grows on its own, so
        // any fall is input. Measuring against the original baseline instead
        // loses the tap as soon as the counter climbs back above it, which is
        // exactly what happens when the user was recently at the keyboard.
        if let idleNow { previous = idleNow }

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

/// Whether a key was pressed since the reading before it.
///
/// The counter only ever grows on its own, so anything lower than the previous
/// reading is a hand on the keyboard. Reading it against the last reading rather
/// than against one taken at the start is what keeps a tap visible: the counter
/// is back at zero the instant a key lands, and it climbs again from there, so a
/// small number of seconds is all the evidence a tap leaves if it is sampled a
/// few seconds late.
///
/// The first reading is measured against the one taken before the first ring, so
/// the wake itself, or a `sudo` password typed moments ago, still cannot be
/// mistaken for the answer. A zero reading is treated the same way whatever the
/// previous one was, because after a real wait with no input the counter cannot
/// still be zero.
private func answered(idleNow: Int?, previous: Int?) -> Bool {
    guard let idleNow else { return false }   // unreadable: no evidence, keep ringing
    guard let previous else { return idleNow == 0 }
    return idleNow == 0 || idleNow < previous
}