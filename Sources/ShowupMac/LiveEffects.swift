import Foundation
import ShowupCore

extension Effects {
    /// Everything the scheduler needs, wired to the real Mac.
    ///
    /// The alarm is passed in rather than built here so the entry point decides
    /// its options and this stays a plain mapping of hooks to commands.
    public static func live(alarm: @escaping @Sendable (Int?) -> AlarmOutcome) -> Effects {
        Effects(
            now: { secondsSinceMidnight(Date()) },
            currentDate: { Date() },
            sleep: { Thread.sleep(forTimeInterval: Double($0)) },
            scheduleWake: { ScheduledWake.shared.schedule(in: $0) },
            idleSeconds: { Mac.idleSeconds() },
            show: { Mac.showApp($0) },
            alarm: alarm,
            outputVolume: { Mac.speakerVolume() },
            setOutputVolume: { Mac.setSpeakerVolume($0) },
            powerSettings: { Mac.configuredPowerSettings },
            wakeKind: { Mac.currentWakeKind(requestedAt: $0) },
            powerCycle: { PowerNotifications.shared?.takeCycle() },
            wakeArrived: { PowerNotifications.shared?.hasCompletedWake() ?? false },
            loginFinished: { Mac.loginFinished() },
            log: { Log.write($0) },
            warn: { Log.write("WARNING \($0)", to: .standardError) }
        )
    }
}

/// The real alarm, on the real machine.
///
/// Written as an initialiser rather than property defaults because a property
/// named `idleSeconds` cannot call `Mac.idleSeconds()` from its own initialiser.
public struct LiveAlarmEffects: AlarmEffects {
    public var now: @Sendable () -> Int
    public var keyboardIdleSeconds: @Sendable () -> Int?
    public var play: @Sendable (String) -> Result<Void, ShowError>
    public var sleep: @Sendable (Int) -> Void

    public init() {
        now = { secondsSinceMidnight(Date()) }
        keyboardIdleSeconds = { Mac.keyboardIdleSeconds() }
        play = { Mac.playSound($0) }
        sleep = { Thread.sleep(forTimeInterval: Double($0)) }
    }
}