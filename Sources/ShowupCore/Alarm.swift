/// The alarm's knobs, so tests can run it without waiting for real time.
public struct AlarmOptions: Equatable, Sendable {
    /// Seconds between rings.
    public var between: Int
    /// Give up after this many rings. `nil` never gives up, which is the
    /// default and the point: a ring that stops is a ring that woke nobody.
    public var giveUpAfter: Int?
    /// Give up after the sound fails this many times. An audio device that is
    /// still coming up after a wake fails the first few plays.
    public var playFailures: Int

    public init(
        between: Int = ringBetweenSeconds,
        giveUpAfter: Int? = nil,
        playFailures: Int = defaultPlayFailures
    ) {
        self.between = between
        self.giveUpAfter = giveUpAfter
        self.playFailures = playFailures
    }
}

/// What the alarm needs from the machine. It runs on its own queue and must
/// not need anything else.
public protocol AlarmEffects: Sendable {
    /// Seconds since the last keyboard, mouse or network input, or `nil` when
    /// the counter cannot be read at all.
    var idleSeconds: @Sendable () -> Int? { get }
    var play: @Sendable (String) -> Result<Void, ShowError> { get }
    var sleep: @Sendable (Int) -> Void { get }
}

public let ringBetweenSeconds = 5
public let defaultPlayFailures = 40

/// How long to keep ringing when the machine's own idle timers cannot be read.
/// Long enough to be woken by, short enough that the loop is not stranded.
public let defaultRouseBudgetSeconds = 15 * 60

public let ringbackTone = """
    /System/Library/Components/CoreAudio.component/Contents/SharedSupport/\
    SystemSounds/facetime/multiway_invitation.caf
    """

/// Rings until somebody answers, and does not give up on its own.
public func alarmRing(_ options: AlarmOptions, _ effects: AlarmEffects) -> AlarmOutcome {
    // Read before the first ring, so the ring itself, or a sudo password typed
    // moments ago, cannot be mistaken for the user answering.
    ring(options, effects, baseline: effects.idleSeconds(), rings: 0, failures: 0)
}

private func ring(
    _ options: AlarmOptions,
    _ effects: AlarmEffects,
    baseline: Int?,
    rings: Int,
    failures: Int
) -> AlarmOutcome {
    var rings = rings
    var failures = failures

    while true {
        switch effects.play(ringbackTone) {
        case .success:
            effects.sleep(options.between)
            rings += 1
            if answered(idleNow: effects.idleSeconds(), baseline: baseline)
                || options.giveUpAfter.map({ rings >= $0 }) == true
            {
                return .rung(rings: rings)
            }
            failures = 0

        case .failure(let reason):
            failures += 1
            guard failures < options.playFailures else { return .silent(reason: reason.description) }
            effects.sleep(options.between)
        }
    }
}

/// Whether input arrived while the ring was going.
///
/// The counter is compared against the reading taken before the first ring: it
/// only ever grows on its own, so anything lower is a hand on the keyboard. A
/// zero is treated the same way whatever the baseline was, because after a real
/// wait with no input the counter cannot still be zero.
private func answered(idleNow: Int?, baseline: Int?) -> Bool {
    guard let idleNow else { return false }   // unreadable: no evidence, keep ringing
    guard let baseline, baseline > 0 else { return idleNow == 0 }
    return idleNow == 0 || idleNow < baseline
}