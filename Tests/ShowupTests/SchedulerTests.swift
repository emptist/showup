import Testing
@testable import ShowupCore

/// The scheduler loop, driven by a fake clock and a fake Mac.
///
/// This is where the two programs diverge, and the divergence used to be
/// untested: `-q` was parsed, tested at the parser, and then never read.
@Suite struct SchedulerTests {
    func config(hour: Int, minute: Int = 0, ring: Bool = true, app: String = "Safari") -> Config {
        Config(
            app: app,
            times: [TimeOfDay(hour: hour, minute: minute)],
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

        #expect(machine.alarmCount == 0)
    }

    // MARK: Program 2: the machine slept

    @Test func aWakeOnASleepingMachineRingsFirst() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true  // the counter freezes, as it does

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

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

    /// The warning is about an alarm nobody can hear, so it belongs where there
    /// is an alarm. `--no-ring` plays nothing at all, and a speaker that is too
    /// quiet for a sound that never comes is not a failure this program has.
    @Test func noRingDoesNotWarnAboutASpeakerItWillNotUse() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.volume = 13  // below quietVolume, and irrelevant

        _ = step(config(hour: 9, ring: false), effects: machine.effects, from: 0)

        #expect(!machine.didWarn("you will not hear it"))
        #expect(machine.alarmCount == 0)
        #expect(machine.shownApps == ["Safari"])
    }

    /// A speaker quieter than the ring volume is raised before the alarm
    /// plays, because a Mac left quiet overnight otherwise rings into silence.
    @Test func aQuietSpeakerIsRaisedBeforeRinging() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.volume = 3

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.volumeWasSetTo == [ringVolume])
        #expect(machine.said("the speaker was at 3, so it was raised to \(ringVolume)"))
    }

    /// Raising is only ever upward. The volume somebody chose is not ours.
    @Test func aLoudSpeakerIsLeftAlone() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.volume = ringVolume

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.volumeWasSetTo == [])
    }

    /// There is no alarm, so there is nothing to be heard and nothing to raise.
    @Test func noRingNeverTouchesTheSpeaker() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.volume = 0

        _ = step(config(hour: 9, ring: false), effects: machine.effects, from: 0)

        #expect(machine.volumeWasSetTo == [])
        #expect(!machine.didWarn("you will not hear it"))
        #expect(machine.alarmCount == 0)
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

    // MARK: Surfacing, and who is there to see it

    /// Measured: launching the app into the session at the target time, while
    /// the screen was still locked, left it nowhere. So the app goes up when
    /// the ringing stops, not when the clock says so.
    /// The alarm is answered and the window waits for the required time: the
    /// answer may arrive before the time, and the window must not go up before
    /// the time it exists for.
    @Test func theAppIsSurfacedAfterTheAlarmIsAnswered() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.alarmTakesSeconds = 30

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.said("rang 3 times to be heard; somebody is back"))
        #expect(machine.shownApps == ["Safari"])
        // Answered at 08:59:30, and the window still waited for 09:00.
        #expect(machine.now == 9 * 3_600)
    }

    /// The alarm stops at the first key press, and that key press may be the
    /// first letter of a password typed at the login window. The app must not
    /// be brought up before the login has finished, because the activation does
    /// not survive the screen coming back.
    @Test func aLoginWindowIsWaitedOutBeforeTheAppIsBroughtUp() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(0)
        machine.sleepsDuringWait = true
        machine.alarmTakesSeconds = 30
        machine.loginIsFinished = false
        machine.loginFinishesAfter = 3  // three readings before the login is done

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.said("a login window is up; waiting for the login to finish"))
        #expect(machine.said("the login has finished"))
        // The login was waited out before the app was brought up.
        #expect(machine.shownApps == ["Safari"])
    }

    /// The two waits are different waits, and the order matters: the login
    /// first, because the window cannot be brought up before the screen comes
    /// back, and the clock second, because the window does not belong to the
    /// user before the time.
    @Test func theLoginIsWaitedOutBeforeTheRequiredTimeIsWaitedFor() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(0)
        machine.sleepsDuringWait = true
        machine.alarmTakesSeconds = 30
        machine.loginIsFinished = false
        machine.loginFinishesAfter = 2

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        // The login took two reads of ten seconds, and the clock was then
        // asked for the remaining time. The window is up at 09:00:00 and not
        // a second before, and not a second after.
        #expect(machine.now == 9 * 3_600)
        #expect(machine.shownApps == ["Safari"])
        // The two waits are visible in the log, in that order.
        let login = machine.logLines.firstIndex { $0.contains("the login has finished") }
        let holding = machine.logLines.firstIndex { $0.contains("holding the window") }
        #expect(login != nil)
        #expect(holding != nil)
        if let login, let holding {
            #expect(login < holding)
        }
    }

    /// A login that never finishes is a person who never came back. The app is
    /// for the user to see, and there is no user, so it is not brought up.
    @Test func aLoginThatNeverFinishesBringsUpNothing() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(0)
        machine.sleepsDuringWait = true
        machine.alarmTakesSeconds = 30
        machine.loginIsFinished = false
        machine.loginFinishesAfter = .max  // never finishes

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.didWarn("the login did not finish; the window is not brought up"))
        #expect(machine.shownApps == [])
    }

    /// Nobody came back for the alarm either. The app is for the user to see,
    /// and there is no user, so nothing is brought up at all - not even into
    /// the session behind the login window.
    @Test func nobodyComingBackBringsUpNothing() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(0)
        machine.sleepsDuringWait = true
        machine.alarmOutcome = .failed(rings: 12)

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.said("rang 12 times and nobody came back; this wake has passed"))
        #expect(machine.shownApps == [])
    }
    /// Nobody is waiting for the clock when they are awake and at the machine.
    @Test func anAwakeMachineStillGetsTheAppOnTime() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.sleepsDuringWait = false
        machine.alarmTakesSeconds = 30  // would matter if the alarm ran at all

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.alarmCount == 0)
        #expect(machine.now == 9 * 3_600)
        #expect(machine.shownApps == ["Safari"])
    }

    /// `--no-ring` on a sleeping machine has no sound to hold, but the window
    /// still does not go up before the time it exists for.
    @Test func noRingOnASleepingMachineStillWaitsForTheTime() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true

        _ = step(config(hour: 9, ring: false), effects: machine.effects, from: 0)

        #expect(machine.alarmCount == 0)
        #expect(machine.shownApps == ["Safari"])
        #expect(machine.now == 9 * 3_600)
    }

    /// The window waits for the required time even when the wake came early
    /// and the machine was up. A real run on this very Mac put the app up at
    /// 21:59:00 four times out of four against 22:00 requirements, because
    /// the waits were trusted instead of the clock. The scheduler now reads the
    /// clock and holds until it is time.
    @Test func theWindowIsHeldUntilTheRequiredTimeNoMatterWhatTheWaitsDid() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.sleepsDuringWait = false

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.now == 9 * 3_600)
        #expect(machine.shownApps == ["Safari"])
    }

    /// The two clock readings a wait is corrected by are a moment apart, and a
    /// moment can straddle midnight. The caller's reading is from the last
    /// second of the day and the step starts on the other side of it, which is
    /// a wait of nothing at all: counting the seconds forward round the clock
    /// is what stops that from reading as most of a day, and a wait of a whole
    /// day would hold the window until tomorrow over a one second wait.
    @Test func aWaitThatStraddlesMidnightIsNotAWholeDay() {
        let machine = FakeMachine()
        // The caller's reading is from the last second of the day, and the
        // step starts a second later, on the other side of midnight.
        machine.setClock(secondsPerDay - 1)
        let callerDate = machine.currentDate
        machine.advance(1)

        _ = step(config(hour: 0), effects: machine.effects, from: secondsPerDay - 1, at: callerDate)

        // Midnight has arrived, so the window goes up now and not in a day.
        #expect(machine.now == 0)
        #expect(machine.shownApps == ["Safari"])
    }

    /// A time whose moment has arrived exactly is tomorrow's, by the same rule
    /// `nextWake` answers it with: a whole day. The wait used to be clamped a
    /// second short of a day, which put the window up one second before the time
    /// it exists for - the one way this program can be early.
    @Test func aTimeWhoseMomentIsExactlyNowWaitsTheWholeDay() {
        let machine = FakeMachine()
        machine.setClock(9 * 3_600)
        machine.sleepsDuringWait = false

        _ = step(config(hour: 9), effects: machine.effects, from: 9 * 3_600)

        // 09:00 tomorrow, to the second, and not 08:59:59.
        #expect(machine.now == 9 * 3_600)
        #expect(machine.shownApps == ["Safari"])
    }

    /// The same hold runs in the sleeping case: answered, and still not early.
    @Test func anAnsweredAlarmStillShowsAtTheRequiredTime() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(0)
        machine.sleepsDuringWait = true
        machine.alarmTakesSeconds = 30

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.alarmCount == 1)
        #expect(machine.now == 9 * 3_600)
        #expect(machine.shownApps == ["Safari"])
    }

    /// The machine's clock and the schedule can disagree, and they did: a
    /// window served a minute early put every later one a minute early too,
    /// because the next wait was measured from the scheduled time rather than
    /// from where the machine actually was. Four runs of a real 21:00 wake put
    /// the app up at 20:59:00.
    ///
    /// The window goes up when the machine's clock says the time has come, and
    /// the schedule is what the machine's clock is measured against.
    @Test func aWindowIsNotEarlyBecauseTheClockAndTheScheduleDisagree() {
        let machine = FakeMachine()
        // The machine is a minute ahead of where the schedule thinks it is.
        machine.setClock(60)
        machine.sleepsDuringWait = false

        // The schedule says 09:00 is 9 hours away, as it would after a window
        // that was served a minute early.
        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        // The machine's own clock reached 09:00, and not a moment sooner.
        #expect(machine.now == 9 * 3_600)
        #expect(machine.shownApps == ["Safari"])
    }

    /// The chain that drifted: a window served early, then the next one, then
    /// the next. The schedule was carried forward by the time of day of the
    /// window that was served, so every window after an early one was early
    /// too - 20:59:00, 21:59:00, 22:59:00, 23:54:02 against 21:00, 22:00,
    /// 23:00 and 00:00.
    ///
    /// The loop carries the machine's own clock forward instead, so the drift
    /// cannot accumulate.
    @Test func anEarlyWindowDoesNotMakeTheNextOneEarly() {
        let machine = FakeMachine()
        machine.setClock(0)
        // The Mac was asleep, and the alarm was answered before the required
        // time, which is what a window served early looks like: the wake came
        // a minute early and the person answered straight away.
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.alarmTakesSeconds = 30
        let times = [TimeOfDay(hour: 21, minute: 0), TimeOfDay(hour: 22, minute: 0)]

        var instant = 0
        var served: [Int] = []
        for _ in 0..<2 {
            _ = step(
                Config(app: "Safari", times: times, ring: true, dryRun: false),
                effects: machine.effects,
                from: instant
            )
            served.append(machine.now)
            instant = machine.now
        }

        // 21:00 and 22:00, each to the second. The first window was ready at
        // 20:59:30, and it waited the half minute.
        #expect(served == [21 * 3_600, 22 * 3_600])
    }

    /// The alarm is given the machine's own idle window, measured rather than
    /// assumed: a wake is worth what its window is worth, and by the time the
    /// Mac is due to sleep again a wake that reached nobody has failed.
    @Test func theRingingIsBoundedByTheMeasuredIdleWindow() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.powerSettings = PowerSettings(
            source: .ac, displaySleepMinutes: 20, systemSleepMinutes: 25, powerNap: true
        )

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.lastBudget == 20 * 60)
    }

    /// A Mac set never to sleep on its own has no window to work to, so the
    /// alarm is left with only the key press and the machine going down.
    @Test func aMachineThatNeverSleepsHasNoBudget() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.powerSettings = PowerSettings(
            source: .ac, displaySleepMinutes: 0, systemSleepMinutes: 0, powerNap: false
        )

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.lastBudget == nil)
    }

    /// Timers that cannot be read are not the same as timers set to never, and
    /// both leave the alarm without a deadline rather than with an invented one.
    @Test func unreadableTimersInventNoBudget() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.powerSettings = nil

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.lastBudget == nil)
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

        guard case .surfaced(let wake, _) = step(config(hour: 9), effects: machine.effects, from: 0)
        else {
            Issue.record("no wake was served")
            return
        }

        #expect(machine.shownApps == ["Safari"])
        // The loop steps past the wake it just did by the wake's own moment,
        // which is the one thing that cannot land back on it: 09:00 has been
        // served at 09:15, and the cursor is at 09:00:01, so the next 09:00 is
        // tomorrow's.
        let cursor = (wake.at.secondsSinceMidnight + 1) % secondsPerDay
        #expect(nextWake([TimeOfDay(hour: 9, minute: 0)], from: cursor)?.delay == secondsPerDay - 1)
    }

    /// A rouse that reached nobody spends the wake: the app is for the user to
    /// see, and there is no user. The loop must move on to the next time. It
    /// used to leave the cursor on the machine's clock, so a wake whose moment
    /// had not passed yet was served a second time - re-arming a wake for the
    /// moment the program was already at, and bringing the app up for a wake
    /// that had failed.
    @Test func aRouseThatReachedNobodySpendsTheWake() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.alarmOutcome = .failed(rings: 1)
        let times = [TimeOfDay(hour: 0, minute: 20), TimeOfDay(hour: 0, minute: 40)]

        guard case .surfaced(let wake, _) = step(
            Config(app: "Safari", times: times, ring: true, dryRun: false),
            effects: machine.effects,
            from: 0
        ) else {
            Issue.record("no wake was served")
            return
        }

        #expect(wake.at == TimeOfDay(hour: 0, minute: 20))
        #expect(machine.said("this wake has passed"))
        #expect(machine.shownApps == [])
        // The wake is spent, so the next step serves 00:40.
        let cursor = (wake.at.secondsSinceMidnight + 1) % secondsPerDay
        #expect(nextWake(times, from: cursor)?.at == TimeOfDay(hour: 0, minute: 40))
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
            // The same thing the loop does: the machine's own clock, which is
            // also what keeps the wake just served from being served twice.
            instant = machine.now
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

        #expect(machine.alarmCount == 0)
        #expect(machine.said("this was a DarkWake, so nothing can be heard or seen"))
        // Phase one still happens: the app is surfaced on time regardless.
        #expect(machine.shownApps == ["Safari"])
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

        #expect(machine.alarmCount == 1)
        #expect(machine.said("could not tell what kind of wake this was, so ringing anyway"))
    }

    @Test func aFullWakeRings() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        machine.wakeKind = .full
        machine.powerCycle = nil  // the kernel will not say; use the log

        _ = step(config(hour: 9), effects: machine.effects, from: 0)

        #expect(machine.alarmCount == 1)
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
    }

    // MARK: A clock that moves under the program's feet

    /// The clock jumps forward while the window is being held - the machine's
    /// own idea of the time moves an hour, and no time passes while it does.
    /// The window goes up when the machine's clock reaches the required
    /// moment, so the deadline moves with the clock: the hour that was jumped
    /// is not an hour of waiting. A wait counted in seconds instead would
    /// sleep the whole ninety minutes and land an hour past the moment.
    @Test func aClockThatJumpsForwardMovesTheDeadlineWithIt() {
        let machine = FakeMachine()
        machine.setClock(2 * 3_600)  // 02:00, ninety minutes before 03:30
        machine.sleepsDuringWait = false
        // The clock moves an hour forward during the first sleep of the wait.
        machine.sleepAdvancesClock = { $0 == 1 ? 3_600 : 0 }

        _ = step(config(hour: 3, minute: 30), effects: machine.effects, from: 2 * 3_600)

        #expect(machine.shownApps == ["Safari"])
        // The machine's clock read 03:30, and the window went up then. Only
        // half an hour was really slept through: the hour the clock jumped is
        // not an hour of the wait.
        #expect(machine.now == 3 * 3_600 + 30 * 60)
        #expect(machine.sleptFor.reduce(0, +) <= 30 * 60)
    }

    /// The other direction: the clock goes back, and the time of day repeats
    /// an hour. The wait is measured against the machine's clock, so the hour
    /// that happened twice is waited again and the window still lands on the
    /// machine's 03:30 - not a day later, which is what a wait counted round
    /// the clock would read the repeated hour as.
    @Test func aClockThatGoesBackwardsIsWaitedAgain() {
        let machine = FakeMachine()
        machine.setClock(2 * 3_600)
        machine.sleepsDuringWait = false
        // The clock moves an hour back during the first sleep of the wait.
        machine.sleepAdvancesClock = { $0 == 1 ? -3_600 : 0 }

        _ = step(config(hour: 3, minute: 30), effects: machine.effects, from: 2 * 3_600)

        #expect(machine.shownApps == ["Safari"])
        // 03:30 on the machine's clock, however the hour is spent.
        #expect(machine.now == 3 * 3_600 + 30 * 60)
        // The repeated hour is waited again: ninety minutes of ask, plus the
        // hour the clock took back.
        #expect(machine.sleptFor.reduce(0, +) >= 90 * 60 + 3_600 - sleepStepSeconds)
    }

    // MARK: The machine going down mid-wait

    /// The regression from a real run: a 04:00 window that went up at 04:16.
    /// The Mac went down during the hold and came back afterwards, and the
    /// wait was counted in seconds that did not pass while it was down, so
    /// the hold owed itself the whole suspension again before the app came up.
    ///
    /// The hold asks the clock instead. A machine that was asleep comes back
    /// to a clock that ran on without it, and the window goes up then: late by
    /// the tail of the sleep, which is allowed, and not by the sleep itself.
    @Test func aSleepDuringTheHoldDoesNotAddTheSleepToTheWait() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.sleepsDuringWait = false
        // The Mac goes down during the hold and comes back five minutes
        // later: the RTC ran on while the process was frozen.
        machine.suspendsDuring(1, for: 310)

        _ = step(config(hour: 0, minute: 2), effects: machine.effects, from: 0)

        #expect(machine.shownApps == ["Safari"])
        // 00:05:20, and the arithmetic is the point: ten seconds of the wait
        // and then five minutes down with the process frozen, so the clock
        // read 00:05:20 when the machine came back — well past the 00:02 it
        // was waiting for — and the hold stopped there.
        //
        // Not 00:07:10, which is 00:02 plus the whole wait all over again: a
        // count that adds the suspension to itself owes itself the sleep twice.
        #expect(machine.now == sleepStepSeconds + 310)
    }

    /// The other half of the same run: an 08:00 window that went up at 09:40.
    /// The step began at 04:16, the Mac slept for two hours of the wait for
    /// the wake, and the hold was still owed the whole 08:00 distance counted
    /// from 04:16 - so it slept another hour and three quarters after the
    /// machine was already back and past the time.
    ///
    /// The moment is one instant, and the hold is entered whenever it is
    /// entered: it asks the clock how far off the moment is now, and the two
    /// hours the machine was down are not part of the answer.
    @Test func aWaitThatSpansASleepStillLandsOnTheTime() {
        let machine = FakeMachine()
        machine.setClock(0)
        machine.setIdleCounter(300)
        machine.sleepsDuringWait = true
        // The kernel would not say, so nothing is rung for; the hold is what
        // the test is about.
        machine.powerCycle = PowerCycle(willSleep: false, hasPoweredOn: false)
        // The Mac goes down two hours into the wait for the wake and comes
        // back before it, the way the 08:00 wake did.
        machine.suspendsDuring(1, for: 7_200)

        _ = step(config(hour: 4), effects: machine.effects, from: 0)

        #expect(machine.shownApps == ["Safari"])
        // 04:00, to the second. The two hours the machine was down are not
        // added to the wait.
        #expect(machine.now == 4 * 3_600)
    }

    /// A wake whose required time is nearer than the lead has nothing to wake
    /// for: the machine is up, because it is running this program. Asking the
    /// kernel for a wake in the past is a log line nobody can use.
    /// The regression, and the one the real run needed. A step that begins
    /// inside the lead has no room left for the lead — but the RTC alarm is
    /// not there to give the machine room, it is there to make the required
    /// moment *reachable*. A Mac whose idle timer takes it down mid-hold does
    /// not come back on its own, and a step that armed nothing left the
    /// window to whatever else the machine happened to be woken for later.
    ///
    /// Measured on this Mac, from a step that began at 03:58:20 for a 04:00
    /// window with nothing armed: the window went up at 08:58:30.
    @Test func aWakeInsideTheLeadStillAsksTheKernelForTheMomentItself() {
        let machine = FakeMachine()
        machine.setClock(3 * 3_600 + 58 * 60 + 20)  // 03:58:20
        machine.sleepsDuringWait = false

        // 04:00 is 100 seconds away and the night lead is five minutes, so the
        // lead no longer fits and the alarm has nowhere earlier to go.
        _ = step(config(hour: 4), effects: machine.effects, from: 3 * 3_600 + 58 * 60 + 20)

        // Armed anyway, and armed for the required moment itself — which is
        // still in the future, so this is not TECH-DEBT 11's alarm in the past.
        // 100 seconds from 03:58:20 is 04:00:00, not the 03:55:00 the lead
        // would have named.
        #expect(machine.wakeRequestedIn == [100])
        #expect(machine.said("(pmset"))
        #expect(!machine.said("no wake asked for"))
        #expect(machine.shownApps == ["Safari"])
        #expect(machine.now == 4 * 3_600)
    }

    /// What TECH-DEBT 11 was actually about, kept as its own test: the alarm
    /// must never be set for an instant that has already gone by. Inside the
    /// lead it moves to the required moment; it does not stay where the lead
    /// would have put it, because that instant is behind us.
    @Test func aWakeInsideTheLeadNeverAsksForAMomentAlreadyPast() {
        let machine = FakeMachine()
        machine.setClock(0)

        // 00:02 is two minutes away, and the night lead is five.
        _ = step(config(hour: 0, minute: 2), effects: machine.effects, from: 0)

        #expect(machine.wakeRequestedIn == [2 * 60])
        #expect(!machine.said("in the past"))
        #expect(machine.shownApps == ["Safari"])
        #expect(machine.now == 2 * 60)
    }

    /// The lead is gone, so the alarm sits on the required moment itself —
    /// and the moment is still ahead, so TECH-DEBT11's alarm in the past is
    /// not what this asks for. A moment that has *arrived* is tomorrow's by
    /// `aTimeWhoseMomentIsExactlyNowWaitsTheWholeDay`, so this is the only
    /// shape a short wait can have.
    /// The lead is gone, so the alarm sits on the required moment itself. What
    /// makes this worth a test of its own is that the alarm is the *only* thing
    /// standing between a doze inside the hold and a window hours late: the
    /// step sleeps nothing (there is no lead left to sleep off), so it reads
    /// the machine as awake, skips the rouse, and goes straight into the hold
    /// — where an idle timer can take the Mac down with nothing armed.
    @Test func theShortWaitSurvivesTheIdleTimerBecauseTheAlarmIsArmed() {
        let machine = FakeMachine()
        machine.setClock(3 * 3_600 + 58 * 60 + 20)  // 03:58:20
        machine.sleepsDuringWait = false
        // The idle timer takes the Mac down 74 seconds into the 100 second
        // hold and the alarm brings it back for 04:00, which is what a real
        // RTC wake does and what the fake models as a bounded sleep.
        machine.suspendsDuring(1, for: 74)

        _ = step(config(hour: 4), effects: machine.effects, from: 3 * 3_600 + 58 * 60 + 20)

        #expect(machine.wakeRequestedIn == [100])
        #expect(machine.shownApps == ["Safari"])
        #expect(machine.now == 4 * 3_600)
    }

    // MARK: Degenerate input

    @Test func noTimesStopsTheLoop() {
        let machine = FakeMachine()
        let config = Config(app: "Safari", times: [], ring: true, dryRun: false)

        #expect(step(config, effects: machine.effects, from: 0) == .idle)
        #expect(machine.said("no times to wait for, stopping"))
    }
}