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

    private(set) var desktopPolls = 0

    // Scripted behaviour
    var loginSeconds = 0
    var volume = 50
    var powerSettings: PowerSettings? = PowerSettings(
        source: .ac, displaySleepMinutes: 20, systemSleepMinutes: 25, powerNap: true
    )
    var scheduleWakeFails = false
    var wakeKind: WakeKind = .full
    /// How long the alarm takes to be answered, in seconds of the fake clock.
    var alarmTakesSeconds = 0
    private(set) var lastGiveUpAfter: Int?
    var powerCycle: PowerCycle? = PowerCycle(willSleep: true, hasPoweredOn: true)
    private(set) var requestedAt: Int?

    // Outcomes the tests assert on
    private let alarmRan = DispatchSemaphore(value: 0)
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
            alarm: { [self] giveUpAfter in
                self.lastGiveUpAfter = giveUpAfter
                self.alarmRan.signal()
                self.alarmCount += 1
                // The alarm rings until somebody answers, and only then is
                // there anybody to show an app to.
                self.recordSleep(self.alarmTakesSeconds)
                return .rung(rings: 3)
            },
            outputVolume: { [self] in .success(self.volume) },
            powerSettings: { [self] in self.powerSettings },
            wakeKind: { [self] in self.recordWakeKind($0) },
            powerCycle: { [self] in self.powerCycle },
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

    /// Input arriving, which resets the counter to where it started.
    func touchKeyboard() {
        lock.withLock { idleCounter = 0 }
    }

    func setClock(_ seconds: Int) {
        lock.withLock { clockSeconds = seconds % secondsPerDay }
    }

    /// The alarm runs on its own queue, so a test has to let it be dispatched.
    func waitForAlarm() {
        _ = alarmRan.wait(timeout: .now() + 5)
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

    private(set) var plays = 0
    private(set) var sleeps = 0

    init(readings: [Int?], playResult: Result<Void, ShowError> = .success(())) {
        self.idleReadings = readings.isEmpty ? [nil] : readings
        self.playOutcomes = [playResult]
    }

    init(readings: [Int?], playResults: [Result<Void, ShowError>]) {
        self.idleReadings = readings.isEmpty ? [nil] : readings
        self.playOutcomes = playResults.isEmpty ? [.success(())] : playResults
    }

    var idleSeconds: @Sendable () -> Int? {
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
        { [self] _ in lock.withLock { sleeps += 1 } }
    }
}