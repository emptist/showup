import Foundation

/// Surfaces the app at every configured time, for as long as the program runs.
public func run(_ config: Config, effects: Effects) {
    reportIdleWindow(effects)

    var instant = effects.now()
    var instantDate = effects.currentDate()
    while true {
        switch step(config, effects: effects, from: instant, at: instantDate) {
        // The payloads are what a test asserts on; the loop needs the wake.
        case .surfaced(let wake, _):
            // Step past the wake that was just handled by its required moment,
            // not by the machine's clock at the moment of serving.
            //
            // The moment is what the wake exists for, so the cursor moves past
            // it however the serving went: on time, late because the rouse ran
            // long, or not at all because nobody came. A cursor left at the
            // clock would land back on a wake whose moment had not passed yet -
            // a rouse that failed at 03:58 used to re-arm a wake for 03:58 and
            // serve the same 04:00 again. The next wake is read against the
            // machine's own clock for its date, so a moment that has passed
            // waits for tomorrow on its own and the same wake is not served
            // twice.
            instant = (wake.at.secondsSinceMidnight + 1) % secondsPerDay
            instantDate = effects.currentDate()
        case .idle:
            return
        }
    }
}

/// The outcome of one iteration.
public enum Step: Equatable {
    /// Slept until `wake.at`, then surfaced the app.
    ///
    /// There is no field for what the alarm did. It runs inside `rouse`, which
    /// has already returned by the time this is built, and it reports by
    /// logging, so there is nothing truthful left to record here.
    case surfaced(wake: Wake, showed: ShowOutcome)
    /// There are no times to wait for.
    case idle
}

/// The instant the caller's reading was taken at.
///
/// The wait is the distance from here to the required moment, and the moment
/// is settled by the calendar: `nextWakeAbsolute` knows which of the two
/// 02:30s is next and that 02:30 does not exist at all in spring. It is not
/// the difference of two times of day, which is an hour out on the day the
/// clock changes.
///
/// The reading defaults to now, which is what it is when a caller has nothing
/// earlier to report.
public func step(
    _ config: Config, effects: Effects, from now: Int, at instantDate: Date? = nil
) -> Step {
    let callerDate = instantDate ?? effects.currentDate()
    guard let (wake, target) = nextWakeAbsolute(config.times, from: now, on: callerDate) else {
        effects.log("no times to wait for, stopping")
        return .idle
    }

    let started = effects.now()
    let stepDate = effects.currentDate()
    // The wait is the distance from this reading to the required moment,
    // counted on the calendar. A negative one cannot happen - the moment is
    // today's or tomorrow's by construction - but a clock that was corrected
    // under the program's feet is not worth arguing with: the window goes up
    // at once, which is late and allowed.
    let wait = max(0, Int(target.timeIntervalSince(stepDate).rounded(.down)))
    // The kernel is asked to bring the Mac back a lead before the required
    // time, so that the display coming up, the person waking and the password
    // all happen inside the window rather than in the minute the app was
    // supposed to appear.
    let ahead = max(0, wait - leadFor(hour: wake.at.hour))
    // The instant the RTC alarm is set for. It settles whether a DarkWake was
    // ours or the machine's own, which the label alone cannot.
    let requestedAt = (started + ahead) % secondsPerDay
    if ahead > 0 {
        let datetime = pmsetDatetime(now: effects.currentDate(), secondsFromNow: ahead)
        effects.log("waking at \(wake.at.rendered) (pmset \(datetime)), in \(describeDelay(wait))")
        if case .failure(let reason) = effects.scheduleWake(ahead) {
            effects.warn("could not schedule wake (did you run with sudo?): \(reason)")
        }
    } else {
        // The required time is nearer than the lead, so there is nothing to
        // wake for: the machine is up, because it is running this program.
        // Asking the kernel for a wake in the past is a log line nobody can
        // use, and an alarm armed for the moment it was already at.
        effects.log(
            "waking at \(wake.at.rendered), in \(describeDelay(wait))"
                + " (the time is nearer than the lead; no wake asked for)"
        )
    }

    let idleBefore = effects.idleSeconds()
    sleepSeconds(effects, ahead)
    let elapsed = secondsBetween(started, effects.now())
    let idleAfter = effects.idleSeconds()

    let evidence = sleepEvidence(idleBefore: idleBefore, idleAfter: idleAfter, elapsed: elapsed)
    effects.log(evidence.report(idleBefore: idleBefore, idleAfter: idleAfter, elapsed: elapsed))

    if evidence.wokeTheUser {
        // Wait for the person, then surface. Not the other way round.
        //
        // Measured: launching the app into the session at the target time, while
        // the screen was still locked, left it nowhere. `open` reported success
        // and nothing was in front after the unlock - the activation does not
        // survive the screen coming back. So the alarm is not a courtesy before
        // the work; it is the thing that tells us there is somebody there, and
        // the app goes up the moment there is.
        switch rouse(config, effects, requestedAt: requestedAt) {
        case .answered:
            // Somebody is there. The key press that stopped the alarm may have
            // been the first letter of a password, so the login is waited out
            // before the app is brought up - the activation does not survive the
            // screen coming back.
            guard waitForTheLogin(effects) else {
                return .surfaced(wake: wake, showed: .notShown(reason: "the login did not finish"))
            }
            holdUntilTheTime(effects, until: target)
            return .surfaced(wake: wake, showed: surface(config.app, effects))
        case .nobodyCame:
            // The app is for the user to see, and there is no user. The run
            // ends here, and the loop goes on to arm the next wake.
            return .surfaced(wake: wake, showed: .notShown(reason: "nobody came back"))
        case .notRung:
            // Nothing was rung, so nothing is known about whether somebody is
            // there. Phase one still happens: the app is surfaced on the time.
            holdUntilTheTime(effects, until: target)
            return .surfaced(wake: wake, showed: surface(config.app, effects))
        }
    }

    holdUntilTheTime(effects, until: target)
    return .surfaced(wake: wake, showed: surface(config.app, effects))
}

/// Waits for the login to finish, if there is one.
///
/// The alarm stops at the first key press, and that key press may be the first
/// letter of a password typed at the login window. Bringing the app up then
/// would lose it: the activation does not survive the screen coming back, and
/// the app is launched into a session nobody is looking at yet.
///
/// So this is a wait of its own, and it is not the same wait as the clock's.
/// The clock says when the window belongs to the user; the login says whether
/// there is a user in front of the screen to receive it. Both have to be
/// satisfied, and the login is settled first: the window cannot be brought up
/// before the screen comes back, and it does not want to wait for the time
/// before the screen comes back either.
///
/// The wait is bounded by the same idle window the alarm is given. A person who
/// never types the password is not coming back, and the wake has failed like
/// any other.
///
/// The bound is the machine's own idle timer, read rather than assumed, and
/// `nil` when the timers cannot be read: an unreadable timer is not a timer
/// of zero, and a window of zero would skip a login that finishes a second
/// later. Without a bound the wait ends when the machine goes down, which the
/// alarm's own budget already accounts for.
private func waitForTheLogin(_ effects: Effects) -> Bool {
    guard !effects.loginFinished() else { return true }
    effects.log("a login window is up; waiting for the login to finish")
    let budget = effects.powerSettings()?.idleWindowSeconds
    var waited = 0
    while !effects.loginFinished() {
        if let budget, waited >= budget {
            effects.warn("the login did not finish; the window is not brought up")
            return false
        }
        effects.sleep(sleepStepSeconds)
        waited += sleepStepSeconds
    }
    effects.log("the login has finished")
    return true
}

/// Holds the window until the required moment has arrived.
///
/// The showing side trusts no arithmetic but the clock. The wake is scheduled
/// by a lead-time split and the ring ends when it ends, and both of those can
/// land minutes off the required time - a real 21:00 wake brought the app up
/// at 20:59:00 four runs out of four, once by nearly six minutes.
///
/// The wait is not counted at all. It is the distance to a moment, and the
/// machine's own clock says when that moment has arrived: the loop asks the
/// clock, sleeps a step, and asks again. Nothing is accumulated, so there is
/// nothing for a clock change or a midnight to get wrong - the moment is one
/// instant, and the calendar said which one it was when the wake was chosen.
///
/// This is also the only form that survives the machine going down. A wait
/// counted in seconds - on the wall clock or on a monotonic one - adds the
/// sleep to itself: the seconds a suspended Mac costs are exactly the seconds
/// the wait did not get, and the window goes up that much late. A real 04:00
/// wake went up at 04:16 and an 08:00 one at 09:40 that way. Asking the clock
/// instead means a machine that was asleep comes back to a clock that ran on
/// without it, and the window goes up then: late, which is allowed.
///
/// Late is possible; early is not.
private func holdUntilTheTime(_ effects: Effects, until target: Date) {
    while true {
        guard effects.currentDate() < target else { return }

        let missing = Int(target.timeIntervalSince(effects.currentDate()).rounded(.up))
        effects.log("holding the window for \(missing)s until the required time")
        let before = effects.currentDate()
        sleepSeconds(effects, missing)
        // A clock that does not move must not spin this loop for ever. The
        // window goes up late instead, which is a smaller failure than a
        // process that never returns and a log that never ends.
        guard effects.currentDate() != before else {
            effects.warn("the clock did not move while holding the window; showing now")
            return
        }
    }
}

/// How long this Mac is configured to stay awake with nobody touching it.
///
/// Read once, at startup, because it does not change while showup runs, and it
/// is the one number that says whether a wake can be completed at all.
private func reportIdleWindow(_ effects: Effects) {
    let report = auditIdleWindow(effects.powerSettings())
    effects.log(report.summary)
    for warning in report.warnings { effects.warn(warning) }
}

/// What the rouse found.
private enum Rouse {
    /// Somebody answered: a hand reached the keyboard and stopped the alarm.
    case answered
    /// The alarm rang and nobody came back. The machine is going back to
    /// sleep, this wake has failed, and there is no user to bring the app up
    /// to.
    case nobodyCame
    /// No alarm was possible or wanted: a DarkWake, a wake that did not
    /// complete, or `--no-ring`. Phase one still happens - the app is surfaced
    /// on the time, because a quiet alarm says nothing about whether somebody
    /// is there.
    case notRung
}

/// Program 2. Rings until somebody answers, then returns.
///
/// This blocks on purpose. The caller has nothing else to do until there is
/// somebody to show an app to, and waiting here is what makes the app appear
/// when they are back rather than at a time they were not there for.
private func rouse(_ config: Config, _ effects: Effects, requestedAt: Int) -> Rouse {
    // The kernel's own account comes first, and when it speaks it decides alone:
    // it says which of the two things actually happened. The power log is only
    // consulted when the kernel would not say.
    if let cycle = effects.powerCycle() {
        effects.log(
            "the kernel reported: \(cycle.willSleep ? "a real sleep" : "no sleep"), "
                + "\(cycle.hasPoweredOn ? "the wake completed" : "no completed wake")"
        )
        guard cycle.completedFullWake else {
            effects.log("so nothing completed that a person could answer; not ringing")
            return .notRung
        }
    } else {
        let wake = effects.wakeKind(requestedAt)
        switch wake {
        case .dark:
            // A DarkWake is the machine up for network and mail with the screen
            // still off. Nobody can hear this, so ringing would be a sound in
            // an empty house, and it would spend the alarm.
            effects.log("this was a DarkWake, so nothing can be heard or seen; not ringing")
            return .notRung
        case .unknown:
            effects.log("could not tell what kind of wake this was, so ringing anyway")
        case .full:
            break
        }
    }

    if config.ring {
        // Only where there is an alarm to hear. Under `--no-ring` nothing plays
        // at all, so a quiet speaker is not a failure this program has, and
        // warning about it would be a warning about nothing.
        checkAudible(effects)

        // A wake is worth what its window is worth. This is the machine's own
        // idle timer, measured with `pmset -g custom`: by the time the Mac is
        // due to sleep again, a wake that has not reached anybody has failed,
        // and ringing past that point is ringing at a closed door.
        //
        // Nil when the timers cannot be read, or when the Mac is set never to
        // sleep. Neither is the same as never: the machine going down on its
        // own ends the alarm too.
        let window = effects.powerSettings()?.idleWindowSeconds
        raiseToBeHeard(effects)
        switch effects.alarm(window) {
        case .rung(let rings):
            effects.log(
                "rang \(rings) times to be heard; somebody is back"
            )
            return .answered
        case .failed(let rings):
            effects.log(
                "rang \(rings) times and nobody came back; this wake has passed"
            )
            return .nobodyCame
        case .silent(let reason):
            effects.warn("could not ring: \(reason)")
            return .notRung
        }
    } else {
        effects.log("--no-ring was given, staying quiet")
    }
    return .notRung
}

/// An alarm nobody can hear is the worst failure this program has, and nothing
/// else here would reveal it. A real 04:00 wake rang 55 times over five minutes
/// and was not heard at all, because the volume was 13.
private func checkAudible(_ effects: Effects) {
    guard case .success(let volume) = effects.outputVolume(), volume < quietVolume else { return }
    effects.warn("the alarm plays at the speaker volume, which is \(volume) - you will not hear it")
}

/// Raises the speaker to what can be heard before the alarm plays, and never
/// lowers it, because the volume somebody chose is not ours to change.
private func raiseToBeHeard(_ effects: Effects) {
    guard case .success(let volume) = effects.outputVolume(), volume < ringVolume else { return }
    switch effects.setOutputVolume(ringVolume) {
    case .success:
        effects.log("the speaker was at \(volume), so it was raised to \(ringVolume) for the alarm")
    case .failure(let reason):
        effects.warn("could not raise the speaker volume from \(volume): \(reason)")
    }
}

// MARK: - Program 1 (surface)

private func surface(_ app: String, _ effects: Effects) -> ShowOutcome {
    effects.log("about to show \(app)")
    let showed = effects.show(app)
    switch showed {
    case .launched: effects.log("launched \(app)")
    case .surfaced: effects.log("brought \(app) to the foreground")
    case .failed(let reason): effects.warn("could not show \(app): \(reason)")
    case .notShown(let reason): effects.log("did not show \(app): \(reason)")
    }
    return showed
}

// MARK: - Waiting

/// Sleeps for `seconds` against the wall clock, in steps.
///
/// See `sleepStepSeconds` for why this is not one long sleep.
func sleepSeconds(_ effects: Effects, _ seconds: Int) {
    let target = (effects.now() + seconds) % secondsPerDay
    var budget = seconds
    while budget > 0 {
        guard let step = nextSleepStep(target: target, now: effects.now(), budget: budget) else { return }
        effects.sleep(step)
        budget -= step
    }
}