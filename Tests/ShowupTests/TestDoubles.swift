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

    /// The wall clock: a time of day, which jumps an hour in spring and an
    /// hour back in autumn. There is no second clock. A duration is the
    /// distance between two readings of this one, because this is the only
    /// clock that keeps running while the Mac is suspended - and a wait that
    /// is measured on any other clock adds the suspension to itself.
    private var date: Date

    // The idle counter, modelled the way the real one behaves: it runs only
    // while the machine is up, so it freezes across a sleep and picks up where
    // it stopped.
    private var idleCounter = 0
    private var idleReadAt = 0
    private(set) var idleReadCount = 0

    init() {
        // 03:00, where the clock starts.
        let anchor = Date(timeIntervalSince1970: 1_788_000_000)
        self.date = Calendar.current.startOfDay(for: anchor).addingTimeInterval(3 * 3_600)
    }

    /// Whether the Mac goes to sleep during the wait.
    var sleepsDuringWait = false
    /// Extra seconds the wall clock moves during a sleep, over and above the
    /// wait that was asked for, keyed by which sleep it is. This is what the
    /// two clock changes of the year look like from inside a wait - the time
    /// of day moves an hour and the machine believes it - and equally what a
    /// suspension looks like: the RTC runs on while the process is frozen, so
    /// a sleep asked for as ten seconds can cost ten minutes of wall clock.
    var sleepAdvancesClock: (Int) -> Int = { _ in 0 }

    /// Seconds the wall clock moves with the process frozen inside a sleep,
    /// keyed by which sleep it is, over and above the wait that was asked for.
    ///
    /// This is a suspension as the machine actually performs one: the caller
    /// asked for ten seconds, the idle timer took the Mac down for an hour, and
    /// `Thread.sleep` returned to a clock an hour on. It is the same event as
    /// `sleepAdvancesClock` from inside the program — nothing accumulated
    /// survives it — but it is kept as a separate hook because the two are
    /// written for different tests: a clock change moves the wall clock while
    /// the process runs, a suspension moves it while the process does not, and
    /// a test that means to reproduce a sleep should say so by name.
    var suspendsDuringSleep: (Int, Int) -> Int = { _, _ in 0 }

    /// The Mac goes down inside the given sleep — the first one by default —
    /// and stays down for `seconds`, the way its own idle timer takes it rather
    /// than a clock change.
    ///
    /// Sleeps are counted as the waits that actually asked for something: the
    /// alarm's own bookkeeping asks for zero seconds between rings, and a test
    /// that means to interrupt a wait does not mean to interrupt that.
    func suspendsDuring(_ nth: Int = 1, for seconds: Int) {
        var seen = 0
        suspendsDuringSleep = { index, asked in
            // A wait that asked for nothing is bookkeeping, not a wait: the
            // alarm reads the clock between rings without sleeping, and a test
            // that means to interrupt a wait does not mean to interrupt that.
            guard asked > 0 else { return 0 }
            seen += 1
            return seen == nth ? seconds : 0
        }
    }

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
    /// A wake refused where the kernel list is root ground: the designed
    /// handoff instead of a failure. The handoff line rides the first refusal
    /// of the run; refusals after that are the same standing fact, already
    /// said, exactly as the real wake act reports it.
    var scheduleWakeIsARootlessHandoff = false
    private var handoffAnnounced = false
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

    /// The time of day, as the machine reports it.
    var now: Int { lock.withLock { secondsSinceMidnight(date) } }

    /// The wall clock, paired with the time of day the way the real machine's
    /// is: the date the seconds since midnight were read from.
    var currentDate: Date { lock.withLock { date } }

    // MARK: Effects

    var effects: Effects {
        Effects(
            now: { [self] in self.now },
            currentDate: { [self] in self.currentDate },
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
            let index = sleptFor.count
            sleptFor.append(seconds)
            // The wall clock moves by the wait that was asked for, plus
            // whatever the machine's own idea of the time did while it was
            // down: a clock change, or a suspension the RTC slept through.
            // Nothing distinguishes them from inside the program, which is the
            // point — a wait measured on this clock survives both.
            date = date.addingTimeInterval(
                Double(seconds + sleepAdvancesClock(index) + suspendsDuringSleep(index, seconds))
            )
        }
    }

    private func recordWakeRequest(_ seconds: Int) -> Result<Void, ShowError> {
        let refused: Result<Void, ShowError>? = lock.withLock {
            wakeRequestedIn.append(seconds)
            guard scheduleWakeIsARootlessHandoff else { return nil }
            let first = !handoffAnnounced
            handoffAnnounced = true
            return .failure(.wakeIsNotOurs(announced: first))
        }
        if let refused { return refused }
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
            let reading = secondsSinceMidnight(date)
            if !sleepsDuringWait { idleCounter += reading - idleReadAt }
            idleReadAt = reading
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
            idleReadAt = secondsSinceMidnight(date)
        }
    }

    /// Sets the time of day, leaving the date and every duration alone.
    func setClock(_ seconds: Int) {
        lock.withLock {
            let dayStart = Calendar.current.startOfDay(for: date)
            date = dayStart.addingTimeInterval(Double(seconds % secondsPerDay))
        }
    }

    /// The given number of seconds really pass.
    func advance(_ seconds: Int) {
        lock.withLock {
            date = date.addingTimeInterval(Double(seconds))
        }
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