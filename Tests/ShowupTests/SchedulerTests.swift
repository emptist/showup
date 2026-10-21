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
    /// moment can straddle midnight. Counting the seconds that passed forward
    /// round the clock is what stops that from reading as most of a day: a bare
    /// subtraction would hold the window until tomorrow over a one second wait.
    @Test func aWaitThatStraddlesMidnightIsNotAWholeDay() {
        let machine = FakeMachine()
        // The machine has just crossed into the day, and the caller's reading is
        // from the last second of the one before it.
        machine.setClock(0)
        machine.sleepsDuringWait = false

        _ = step(config(hour: 0), effects: machine.effects, from: secondsPerDay - 1)

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

    // MARK: Degenerate input

    @Test func noTimesStopsTheLoop() {
        let machine = FakeMachine()
        let config = Config(app: "Safari", times: [], ring: true, dryRun: false)

        #expect(step(config, effects: machine.effects, from: 0) == .idle)
        #expect(machine.said("no times to wait for, stopping"))
    }
}