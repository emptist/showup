import Foundation
import ShowupCore

extension Effects {
    /// Everything the scheduler needs, wired to the real Mac.
    ///
    /// The alarm is passed in rather than built here so the entry point decides
    /// its options and this stays a plain mapping of hooks to commands.
    public static func live(alarm: @escaping @Sendable () -> AlarmOutcome) -> Effects {
        Effects(
            now: { secondsSinceMidnight(Date()) },
            currentDate: { Date() },
            sleep: { Thread.sleep(forTimeInterval: Double($0)) },
            scheduleWake: { Mac.scheduleWake(in: $0) },
            idleSeconds: { Mac.idleSeconds() },
            show: { Mac.showApp($0) },
            alarm: alarm,
            outputVolume: { Mac.speakerVolume() },
            powerSettings: { Mac.configuredPowerSettings },
            wakeKind: { Mac.currentWakeKind(requestedAt: $0) },
            powerCycle: { PowerNotifications.shared?.takeCycle() },
            log: { Log.write($0) },
            warn: { Log.write("WARNING \($0)", to: .standardError) }
        )
    }
}

/// The real alarm, on the real machine.
public struct LiveAlarmEffects: AlarmEffects {
    public init() {}
    public var idleSeconds: @Sendable () -> Int? = { Mac.idleSeconds() }
    public var play: @Sendable (String) -> Result<Void, ShowError> = { Mac.playSound($0) }
    public var sleep: @Sendable (Int) -> Void = { Thread.sleep(forTimeInterval: Double($0)) }
}