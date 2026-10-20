import Foundation

/// Surfaces the app at every configured time, for as long as the program runs.
public func run(_ config: Config, effects: Effects) {
    reportIdleWindow(effects)

    var instant = effects.now()
    while true {
        switch step(config, effects: effects, from: instant) {
        case .surfaced(let wake, _):
            // Step past the wake that was just handled, on the machine's own
            // clock, rather than on the scheduled one.
            //
            // The scheduled time is where the wake was *aimed*, and the machine
            // may not have been there when it was served: a rouse that runs
            // long leaves the window up late, and a window that went up early
            // put every later one early too. Carrying the machine's clock
            // forward means the next wait is measured from where the machine
            // actually is, and the drift cannot accumulate.
            //
            // A time whose moment has already passed today waits for tomorrow
            // on its own: `nextWake` reads the clock, and a time in the past
            // is tomorrow's. So the same wake is not served twice.
            instant = effects.now()
            _ = wake
        case .idle:
            return
        }
    }
}

/// The outcome of one iteration.
public enum Step: Equatable {
    /// Slept until `wake.at`, then surfaced the app.
    ///
    /// There is no field for what the alarm did: it runs on its own queue and
    /// reports by logging, so by the time this is built there is nothing
    /// truthful left to record.
    case surfaced(wake: Wake, showed: ShowOutcome)
    /// There are no times to wait for.
    case idle
}

public func step(_ config: Config, effects: Effects, from now: Int) -> Step {
    guard let wake = nextWake(config.times, from: now) else {
        effects.log("no times to wait for, stopping")
        return .idle
    }

    let started = effects.now()
    // How long the machine's own clock says it is until the required time.
    //
    // `wake.delay` is measured from the caller's clock, which is where the
    // machine was when the last window was served, while `started` is where it
    // is now. The difference is how far the two have drifted, and it is
    // exactly the error to undo: a window served a minute early put every
    // later one a minute early too, because each wait was measured from the
    // scheduled time rather than from where the machine actually was.
    //
    // The wait is bounded by a day. A negative one means the machine's clock
    // is already past the required time, which is late and allowed: the window
    // goes up at once.
    let wait = max(0, min(wake.delay + (now - started), secondsPerDay - 1))
    // The kernel is asked to bring the Mac back a lead before the required
    // time, so that the display coming up, the person waking and the password
    // all happen inside the window rather than in the minute the app was
    // supposed to appear.
    let ahead = max(0, wait - leadFor(hour: wake.at.hour))
    let datetime = pmsetDatetime(now: effects.currentDate(), secondsFromNow: ahead)
    effects.log("waking at \(wake.at.rendered) (pmset \(datetime)), in \(describeDelay(wait))")

    // The instant the RTC alarm is set for. It settles whether a DarkWake was
    // ours or the machine's own, which the label alone cannot.
    let requestedAt = (started + ahead) % secondsPerDay
    if case .failure(let reason) = effects.scheduleWake(ahead) {
        effects.warn("could not schedule wake (did you run with sudo?): \(reason)")
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
        rouse(config, effects, requestedAt: requestedAt)
        holdUntilTheTime(effects, since: started, wait: wait)
        return .surfaced(wake: wake, showed: surface(config.app, effects))
    }

    holdUntilTheTime(effects, since: started, wait: wait)
    return .surfaced(wake: wake, showed: surface(config.app, effects))
}

/// Holds the window until the required time has arrived.
///
/// The showing side trusts no arithmetic but the clock. The wake is scheduled
/// by a lead-time split and the ring ends when it ends, and both of those can
/// land minutes off the required time - a real 21:00 wake brought the app up
/// at 20:59:00 four runs out of four, once by nearly six minutes.
///
/// The wait is counted as seconds elapsed since this wake began, and the count
/// is monotone. The clock is a time of day and wraps at midnight, so the
/// seconds that passed are the difference between two readings plus the whole
/// day when the clock went round. A count that could go backwards would ask
/// for the wait again, and a wait that can never be satisfied would ask for
/// it for ever.
///
/// Late is possible; early is not.
private func holdUntilTheTime(_ effects: Effects, since started: Int, wait: Int) {
    // The time already spent counts: the wait for the wake and the rouse have
    // both happened, and the window may already be late.
    var elapsed = 0
    var last = started
    while true {
        let now = effects.now()
        // The clock wrapped round midnight, so the time it reads is smaller
        // than the one before it. The seconds that passed are the difference
        // plus the whole day it went round.
        elapsed += now >= last ? now - last : now + secondsPerDay - last
        last = now
        guard elapsed < wait else { return }

        let missing = wait - elapsed
        effects.log("holding the window for \(missing)s until the required time")
        let before = effects.now()
        sleepSeconds(effects, missing)
        // A clock that does not move must not spin this loop for ever. The
        // window goes up late instead, which is a smaller failure than a
        // process that never returns and a log that never ends.
        guard effects.now() != before else {
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

/// Program 2. Rings until somebody answers, then returns.
///
/// This blocks on purpose. The caller has nothing else to do until there is
/// somebody to show an app to, and waiting here is what makes the app appear
/// when they are back rather than at a time they were not there for.
private func rouse(_ config: Config, _ effects: Effects, requestedAt: Int) {
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
            return
        }
    } else {
        let wake = effects.wakeKind(requestedAt)
        switch wake {
        case .dark:
            // A DarkWake is the machine up for network and mail with the screen
            // still off. Nobody can hear this, so ringing would be a sound in
            // an empty house, and it would spend the alarm.
            effects.log("this was a DarkWake, so nothing can be heard or seen; not ringing")
            return
        case .unknown:
            effects.log("could not tell what kind of wake this was, so ringing anyway")
        case .full:
            break
        }
    }

    checkAudible(effects)

    if config.ring {
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
        case .failed(let rings):
            effects.log(
                "rang \(rings) times and nobody came back; this wake has passed"
            )
        case .silent(let reason):
            effects.warn("could not ring: \(reason)")
        }
    } else {
        effects.log("--no-ring was given, staying quiet")
    }
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