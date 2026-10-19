import Testing
@testable import ShowupCore

/// The scheduler loop, driven by a fake clock and a fake Mac.
///
/// This is where the two programs diverge, and the divergence used to be
/// untested: `-q` was parsed, tested at the parser, and then never read.
@Suite struct SchedulerTests {
    func config(hour: Int, ring: Bool = true, app: String = "Safari") -> Config {
        Config(
            app: app,
            times: [TimeOfDay(hour: hour, minute: 0)],
            ring: ring,
            dryRun: false
        )
    }

    // MARK: Program 1: the machine stayed up

    @Test func aWakeOnAnAwakeMachineJustSurfacesTheApp() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.sleepsDuringWait = false  // the idle counter keeps running

        let outcome = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(outcome == .surfaced(wake: Wake(at: TimeOfDay(hour: 9, minute: 0), delay: 9 * 3_600), showed: .surfaced))
        #expect(machine.shownApps == ["Safari"])
        #expect(machine.said("the Mac was awake throughout"))

        machine.waitForAlarm()
        #expect(machine.alarmCount == 0)
    }

    // MARK: Program 2: the machine slept

    @Test func aWakeOnASleepingMachineRingsFirst() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true  // the counter freezes, as it does

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        machine.waitForAlarm()
        #expect(machine.alarmCount == 1)
        #expect(machine.said("the Mac was asleep"))
        #expect(machine.shownApps == ["Safari"])
    }

    /// The regression: `--no-ring` was parsed and tested at the parser and then
    /// thrown away, so the alarm rang whatever the user asked for.
    @Test func noRingNeverRings() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true

        _ = step(config(hour: 9, ring: false), effects: machine.effects, from: 0)

        machine.waitForAlarm()
        #expect(machine.alarmCount == 0)
        #expect(machine.said("--no-ring was given, staying quiet"))
        // The app is still surfaced. -q is about the sound, not the surfacing.
        #expect(machine.shownApps == ["Safari"])
    }

    /// An alarm nobody can hear is the worst failure this program has.
    @Test func aMutedSpeakerIsWarnedAboutBeforeRinging() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.volume = 13

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.didWarn("you will not hear it"))
    }

    @Test func aLoudEnoughSpeakerSaysNothing() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.volume = 50

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(!machine.didWarn("you will not hear it"))
    }

    // MARK: Waiting for the login window

    // MARK: The lead window

    @Test func theKernelIsAskedToWakeAheadOfTheTime() {
        let machine = FakeMachine()
        machine.setClock(0)
        
        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        // 09:00 minus a one minute daytime lead.
        #expect(machine.wakeRequestedIn == [9 * 3_600 - dayLeadSeconds])
    }

    @Test func anEveningWakeGetsFiveMinutesOfLead() {
        let machine = FakeMachine()
        machine.setClock(0)
        
        _ = step(config(hour: 22), effects: machine.effects, from: 0)

        #expect(machine.wakeRequestedIn == [22 * 3_600 - nightLeadSeconds])
    }

    @Test func aFailedWakeScheduleIsWarnedAboutButDoesNotStopTheRun() {
        let machine = FakeMachine()
        machine.setClock(0)
                machine.scheduleWakeFails = true

        let outcome = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.didWarn("did you run with sudo?"))
        #expect(machine.shownApps == ["Safari"])
        #expect(outcome != .idle)
    }

    // MARK: The window actually lands on the time

    /// The point of the whole lead window: whatever happened inside it, the
    /// app goes up at the time it was asked for.
    @Test func theAppAppearsAtTheScheduledTime() {
        for (hour, isNightWake) in [(9, false), (22, true)] {
            let machine = FakeMachine()
            machine.setClock(0)
            machine.sleepsDuringWait = false
            
            _ = step(config(hour: hour), effects: machine.effects, from: 0)
            #expect(machine.now == hour * 3_600, "\(hour):00 wake landed at \(machine.now)")
            #expect(isNightWake == (hour >= 22))
        }
    }

    // MARK: Surfacing

    @Test func theResultOfSurfacingIsLoggedAccurately() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setShowOutcomes([.launched])

        _ = step(config(hour: 9), effects: machine.effects, from: 0)
        #expect(machine.said("launched Safari"))
    }

    @Test func aFailureToSurfaceIsWarnedAbout() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setShowOutcomes([.failed("no console user")])

        _ = step(config(hour: 9), effects: machine.effects, from: 0)
        #expect(machine.didWarn("could not show Safari: no console user"))
    }

    // MARK: The machine's own idle timers

    /// showup used to assume "typically 25-30 minutes" for a laptop's idle
    /// timer. It reads the real ones instead, and says what they are.
    @Test func reportsTheIdleTimersItMeasured() {
        let machine = FakeMachine()
        machine.powerSettings = PowerSettings(
            source: .ac, displaySleepMinutes: 20, systemSleepMinutes: 25, powerNap: true
        )
        let empty = Config(app: "Safari", times: [], ring: true, dryRun: false)

        run(empty, effects: machine.effects)  // returns at once: there are no times

        #expect(machine.said("sleeps on its own after 20m"))
        #expect(machine.said("displaysleep 20m, sleep 25m"))
    }

    /// The alarm is only audible while the machine is up, and the machine
    /// decides that for itself after this many seconds of silence.
    @Test func saysHowLongTheAlarmCanBeHeardFor() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.powerSettings = PowerSettings(
            source: .ac, displaySleepMinutes: 20, systemSleepMinutes: 25, powerNap: true
        )

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.said("20m before it sleeps again"))
        #expect(machine.didWarn("login") == false)
    }

    // MARK: Surfacing, and who is there to see it

    /// Measured: launching the app into the session at the target time, while
    /// the screen was still locked, left it nowhere. So the app goes up when
    /// the ringing stops, not when the clock says so.
    @Test func theAppIsSurfacedAfterTheAlarmIsAnswered() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.alarmTakesSeconds = 30

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.said("rang 3 times to be heard; somebody is back"))
        #expect(machine.shownApps == ["Safari"])
        // The window was spent ringing, not slept out in front of a locked screen.
        #expect(machine.now == 8 * 3_600 + 59 * 60 + 30)
    }

    /// Nobody is waiting for the clock when they are awake and at the machine.
    @Test func anAwakeMachineStillGetsTheAppOnTime() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.sleepsDuringWait = false
        machine.alarmTakesSeconds = 30  // would matter if the alarm ran at all

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.alarmCount == 0)
        #expect(machine.now == 9 * 3_600 - dayLeadSeconds + dayLeadSeconds)
        #expect(machine.shownApps == ["Safari"])
    }

    /// --no-ring on a sleeping machine has nobody to wait for, so the app goes
    /// up as soon as the window is up.
    @Test func noRingOnASleepingMachineSurfacesWithoutWaiting() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true

        _ = step(config(hour: 9, ring: false), effects: machine.effects, from: 0)

        #expect(machine.alarmCount == 0)
        #expect(machine.shownApps == ["Safari"])
        #expect(machine.now == 9 * 3_600 - dayLeadSeconds)
    }

    /// rouse now blocks until the alarm is answered, which means an unbounded
    /// alarm would strand the loop: nobody comes back, and tomorrow's wake is
    /// never asked for. The bound is the machine's own idle window, measured.
    @Test func theRingingIsBoundedByTheIdleWindowSoTheLoopContinues() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.powerSettings = PowerSettings(
            source: .ac, displaySleepMinutes: 20, systemSleepMinutes: 25, powerNap: true
        )

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        // 20 minutes of window, a ring every five seconds.
        #expect(machine.lastGiveUpAfter == 20 * 60 / 5)
    }

    @Test func anUnreadableIdleWindowStillBoundsTheRinging() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.powerSettings = nil

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.lastGiveUpAfter == defaultRouseBudgetSeconds / ringBetweenSeconds)
    }

    /// A machine set never to sleep on its own has no window to bound by.
    @Test func aMachineThatNeverSleepsRingsForItsDefaultBudget() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.powerSettings = PowerSettings(
            source: .ac, displaySleepMinutes: 0, systemSleepMinutes: 0, powerNap: false
        )

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.lastGiveUpAfter == defaultRouseBudgetSeconds / ringBetweenSeconds)
    }

    /// Measured: a rouse that waited 53 seconds for somebody to come back was
    /// read as a missed wake, and the loop started the same 13:37 again and
    /// surfaced the app a second time.
    @Test func aSlowRouseDoesNotServeTheSameWakeTwice() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.alarmTakesSeconds = 900  // somebody took a quarter of an hour

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.shownApps == ["Safari"])
        // 09:00 has been served, so the next one is tomorrow and the loop must
        // not land back on the wake it just did.
        let served = TimeOfDay(hour: 9, minute: 0).secondsSinceMidnight
        #expect(nextWake([TimeOfDay(hour: 9, minute: 0)], from: served)?.delay == 86_400)
    }

    /// Each configured time is served once per day, whatever the rouse cost.
    @Test func consecutiveTimesAreServedOnceEach() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.sleepsDuringWait = false
        let morning = Config(
            app: "Safari",
            times: [TimeOfDay(hour: 9, minute: 0), TimeOfDay(hour: 13, minute: 0)],
            ring: true, dryRun: false
        )

        var instant = 0
        var shown = 0
        for _ in 0..<3 {
            guard case .surfaced(let wake, _) = step(morning, effects: machine.effects, from: instant) else { break }
            shown += 1
            instant = wake.at.secondsSinceMidnight
        }

        #expect(shown == 3)
        #expect(machine.shownApps == ["Safari", "Safari", "Safari"])
    }

    // MARK: A wake nobody can hear

    /// A DarkWake is the machine up for mail with the screen still off. Ringing
    /// there is a sound in an empty house, and worse, it spends the alarm.
    @Test func aDarkWakeDoesNotRing() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.wakeKind = .dark
        machine.powerCycle = nil  // the kernel will not say; the log is the fallback

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        machine.waitForAlarm()
        #expect(machine.alarmCount == 0)
        #expect(machine.said("this was a DarkWake, so nothing can be heard or seen"))
        // Phase one still happens: the app is surfaced on time regardless.
        #expect(machine.shownApps == ["Safari"])
        machine.powerCycle = nil  // the kernel will not say; use the log
    }

    /// When the log cannot say, ring. That failure is noise; the other one is
    /// a silent wake, which is worse.
    /// The kernel says a DarkWake never completes a wake, so no ring. This is
    /// the documented behaviour rather than a label read out of a log.
    @Test func aKernelCycleThatDidNotCompleteDoesNotRing() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.powerCycle = PowerCycle(willSleep: true, hasPoweredOn: false)

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        machine.waitForAlarm()
        #expect(machine.alarmCount == 0)
        #expect(machine.said("no completed wake"))
        #expect(machine.shownApps == ["Safari"])
    }

    /// A completed wake from the kernel is the one thing that settles it.
    @Test func aKernelCycleThatCompletedRingsWithoutConsultingTheLog() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.powerCycle = PowerCycle(willSleep: true, hasPoweredOn: true)
        machine.wakeKind = .dark  // the log says DarkWake; the kernel disagrees

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        machine.waitForAlarm()
        #expect(machine.alarmCount == 1)
        #expect(machine.said("the wake completed"))
    }

    /// No sleep at all announced means the counter lied, and nobody was asleep
    /// to be woken.
    @Test func noSleepAnnouncedDoesNotRing() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.powerCycle = PowerCycle()

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        machine.waitForAlarm()
        #expect(machine.alarmCount == 0)
    }

    /// When the kernel would not say, the old evidence decides.
    @Test func withoutTheKernelThePowerLogStillDecides() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.powerCycle = nil
        machine.wakeKind = .dark

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        machine.waitForAlarm()
        #expect(machine.alarmCount == 0)
        #expect(machine.said("this was a DarkWake"))
    }

    @Test func anUnknownWakeStillRings() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.wakeKind = .unknown
        machine.powerCycle = nil

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        machine.waitForAlarm()
        #expect(machine.alarmCount == 1)
        #expect(machine.said("could not tell what kind of wake this was, so ringing anyway"))
        machine.powerCycle = nil  // the kernel will not say; use the log
    }

    @Test func aFullWakeRings() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.wakeKind = .full

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        machine.waitForAlarm()
        #expect(machine.alarmCount == 1)
        machine.powerCycle = nil  // the kernel will not say; use the log
    }

    @Test func theWakeWeAskedForIsRecordedForTheJudgement() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.wakeKind = .dark
        machine.powerCycle = nil

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        // 09:00 minus a one minute lead is the instant the kernel was asked for.
        #expect(machine.requestedAt == 8 * 3_600 + 59 * 60)
        machine.powerCycle = nil  // the kernel will not say; use the log
    }

    // MARK: Degenerate input

    @Test func noTimesStopsTheLoop() {
        let machine = FakeMachine()
        let config = Config(app: "Safari", times: [], ring: true, dryRun: false)

        #expect(step(config, effects: machine.effects, from: 0) == .idle)
        #expect(machine.said("no times to wait for, stopping"))
    }
}