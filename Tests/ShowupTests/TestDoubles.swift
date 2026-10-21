import Foundation
import ShowupCore

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// A Mac that does whatever the test tells it to, standing in for both the
/// clock and the machine.
///
/// Every value the scheduler can observe or change goes through here, which is
/// the only reason the loop can be tested at all.
final class FakeMachine: @unchecked Sendable {
    private let lock = NSLock()

    // Clock
    private var clockSeconds = 3 * 3_600  // 03:00

    // The idle counter, modelled the way the real one behaves: it runs only
    // while the machine is up, so it freezes across a sleep and picks up where
    // it stopped.
    private var idleCounter = 0
    private var idleReadAt = 0
    private(set) var idleReadCount = 0

    /// Whether the Mac goes to sleep during the wait.
    var sleepsDuringWait = false

    // What was asked of the machine
    private(set) var sleptFor: [Int] = []
    private(set) var wakeRequestedIn: [Int] = []
    private(set) var shownApps: [String] = []
    /// Outcomes handed back by `show`, in order. The last one repeats.
    private var showOutcomes: [ShowOutcome] = [.surfaced]

    // Scripted behaviour
    var volume = 50
    private(set) var volumeWasSetTo: [Int] = []
    var powerSettings: PowerSettings? = PowerSettings(
        source: .ac, displaySleepMinutes: 20, systemSleepMinutes: 25, powerNap: true
    )
    var scheduleWakeFails = false
    var wakeKind: WakeKind = .full
    /// How long the alarm takes to be answered, in seconds of the fake clock.
    var alarmTakesSeconds = 0
    /// What the alarm reports when it is done. A wake nobody answered is a
    /// failure, and the app is not brought up for it.
    var alarmOutcome: AlarmOutcome = .rung(rings: 3)
    private(set) var lastBudget: Int?
    var powerCycle: PowerCycle? = PowerCycle(willSleep: true, hasPoweredOn: true)
    /// Whether the login has finished. A machine that was asleep and woke to a
    /// login window has not finished it until the password is typed.
    var loginIsFinished = true
    /// How many readings of the login state it takes before the login finishes.
    var loginFinishesAfter = 0
    private var loginReadings = 0
    private(set) var requestedAt: Int?

    // Outcomes the tests assert on
    private(set) var alarmCount = 0
    private(set) var logLines: [String] = []
    private(set) var warnings: [String] = []

    // MARK: Clock

    var now: Int { lock.withLock { clockSeconds } }

    // MARK: Effects

    var effects: Effects {
        Effects(
            now: { [self] in self.now },
            currentDate: { Date(timeIntervalSince1970: 1_788_000_000) },
            sleep: { [self] in self.recordSleep($0) },
            scheduleWake: { [self] in self.recordWakeRequest($0) },
            idleSeconds: { [self] in self.readIdle() },
            show: { [self] app in self.recordShow(app) },
            alarm: { [self] budget in
                self.lastBudget = budget
                self.alarmCount += 1
                // The alarm rings until somebody answers, and only then is
                // there anybody to show an app to.
                self.recordSleep(self.alarmTakesSeconds)
                return self.alarmOutcome
            },
            outputVolume: { [self] in .success(self.volume) },
            setOutputVolume: { [self] percent in
                self.lock.withLock { self.volumeWasSetTo.append(percent) }
                return .success(())
            },
            powerSettings: { [self] in self.powerSettings },
            wakeKind: { [self] in self.recordWakeKind($0) },
            powerCycle: { [self] in self.powerCycle },
            loginFinished: { [self] in self.readLoginState() },
            log: { [self] in self.logLines.append($0) },
            warn: { [self] in self.warnings.append($0) }
        )
    }

    // MARK: Recording

    private func recordSleep(_ seconds: Int) {
        lock.withLock {
            sleptFor.append(seconds)
            clockSeconds = (clockSeconds + seconds) % secondsPerDay
        }
    }

    private func recordWakeRequest(_ seconds: Int) -> Result<Void, ShowError> {
        lock.withLock { wakeRequestedIn.append(seconds) }
        return scheduleWakeFails
            ? .failure(.failed(command: "pmset", status: 1, detail: "not permitted"))
            : .success(())
    }

    private func recordWakeKind(_ requestedAt: Int?) -> WakeKind {
        lock.withLock { self.requestedAt = requestedAt }
        return wakeKind
    }

    private func readIdle() -> Int? {
        lock.withLock {
            if !sleepsDuringWait { idleCounter += clockSeconds - idleReadAt }
            idleReadAt = clockSeconds
            idleReadCount += 1
            return idleCounter
        }
    }

    private func recordShow(_ app: String) -> ShowOutcome {
        lock.withLock {
            shownApps.append(app)
            return showOutcomes.count > 1 ? showOutcomes.removeFirst() : showOutcomes[0]
        }
    }

    /// The login state, as a machine would report it: finished, or not until
    /// enough readings have gone by.
    private func readLoginState() -> Bool {
        lock.withLock {
            guard !loginIsFinished else { return true }
            loginReadings += 1
            return loginReadings > loginFinishesAfter
        }
    }

    // MARK: Test setup

    /// Sets how long the keyboard had already been idle when the wait started.
    /// `show` hands back these in order, the last one repeating.
    func setShowOutcomes(_ outcomes: [ShowOutcome]) {
        lock.withLock { showOutcomes = outcomes.isEmpty ? [.surfaced] : outcomes }
    }

    func setIdleCounter(_ seconds: Int) {
        lock.withLock {
            idleCounter = seconds
            idleReadAt = clockSeconds
        }
    }

    func setClock(_ seconds: Int) {
        lock.withLock { clockSeconds = seconds % secondsPerDay }
    }

    /// The logged and warned text, for a test that cares about wording.
    func said(_ fragment: String) -> Bool {
        logLines.contains { $0.contains(fragment) }
    }

    func didWarn(_ fragment: String) -> Bool {
        warnings.contains { $0.contains(fragment) }
    }
}

/// An alarm driven by scripted readings: `idle` values in order, the last one
/// repeating, and the same for whether the sound plays.
final class FakeAlarm: AlarmEffects, @unchecked Sendable {
    private let lock = NSLock()
    private let idleReadings: [Int?]
    private let playOutcomes: [Result<Void, ShowError>]
    /// Seconds the clock jumps forward on each `sleep`, over and above the
    /// requested wait. Anything large is the machine having gone down.
    var sleepAdvancesClock: @Sendable (Int) -> Int = { _ in 0 }

    private(set) var plays = 0
    private(set) var sleeps = 0
    private(set) var clock: Int = 0

    init(readings: [Int?], playResult: Result<Void, ShowError> = .success(())) {
        self.idleReadings = readings.isEmpty ? [nil] : readings
        self.playOutcomes = [playResult]
    }

    init(readings: [Int?], playResults: [Result<Void, ShowError>]) {
        self.idleReadings = readings.isEmpty ? [nil] : readings
        self.playOutcomes = playResults.isEmpty ? [.success(())] : playResults
    }

    var now: @Sendable () -> Int {
        { [self] in lock.withLock { clock } }
    }

    var keyboardIdleSeconds: @Sendable () -> Int? {
        { [self] in lock.withLock { idleReadings[min(plays, idleReadings.count - 1)] } }
    }

    var play: @Sendable (String) -> Result<Void, ShowError> {
        { [self] _ in
            lock.withLock {
                let outcome = playOutcomes[min(plays, playOutcomes.count - 1)]
                plays += 1
                return outcome
            }
        }
    }

    var sleep: @Sendable (Int) -> Void {
        { [self] seconds in
            lock.withLock {
                sleeps += 1
                clock += seconds + sleepAdvancesClock(sleeps)
            }
        }
    }
}