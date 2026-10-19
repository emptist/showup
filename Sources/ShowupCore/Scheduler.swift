import Foundation

/// Surfaces the app at every configured time, for as long as the program runs.
public func run(_ config: Config, effects: Effects) {
    reportIdleWindow(effects)

    var instant = effects.now()
    while true {
        switch step(config, effects: effects, from: instant) {
        case .surfaced(let wake, _):
            instant = nextInstant(planned: instant, delay: wake.delay, now: effects.now())
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

    let (ahead, remaining) = leadSplit(delaySeconds: wake.delay, leadSeconds: leadFor(hour: wake.at.hour))
    let datetime = pmsetDatetime(now: effects.currentDate(), secondsFromNow: ahead)
    effects.log("waking at \(wake.at.rendered) (pmset \(datetime)), in \(describeDelay(wake.delay))")

    let started = effects.now()
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
        return .surfaced(wake: wake, showed: surface(config.app, effects))
    }

    sleepSeconds(effects, remaining)
    return .surfaced(wake: wake, showed: surface(config.app, effects))
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
        switch effects.alarm() {
        case .rung(let rings):
            effects.log("rang \(rings) times to be heard; somebody is back")
        case .silent(let reason):
            effects.warn("could not ring: \(reason)")
        }
    } else {
        effects.log("--no-ring was given, staying quiet")
    }

    // The alarm only works while the machine is up, and the machine decides
    // that for itself after this many seconds of silence.
    if let window = effects.powerSettings()?.idleWindowSeconds {
        effects.log("it has \(describeDelay(window)) before it sleeps again, so the alarm has to be answered before then")
    }
}

/// An alarm nobody can hear is the worst failure this program has, and nothing
/// else here would reveal it. A real 04:00 wake rang 55 times over five minutes
/// and was not heard at all, because the volume was 13.
private func checkAudible(_ effects: Effects) {
    guard case .success(let volume) = effects.outputVolume(), volume < quietVolume else { return }
    effects.warn("the alarm plays at the speaker volume, which is \(volume) - you will not hear it")
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