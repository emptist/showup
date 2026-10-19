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

    if case .failure(let reason) = effects.scheduleWake(ahead) {
        effects.warn("could not schedule wake (did you run with sudo?): \(reason)")
    }

    let started = effects.now()
    let idleBefore = effects.idleSeconds()
    sleepSeconds(effects, ahead)
    let elapsed = secondsBetween(started, effects.now())
    let idleAfter = effects.idleSeconds()

    let evidence = sleepEvidence(idleBefore: idleBefore, idleAfter: idleAfter, elapsed: elapsed)
    effects.log(evidence.report(idleBefore: idleBefore, idleAfter: idleAfter, elapsed: elapsed))

    var spent = 0
    if evidence.wokeTheUser {
        spent = rouse(config, effects)
    }
    sleepSeconds(effects, remaining - spent)

    return .surfaced(wake: wake, showed: present(config, effects))
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

/// Program 2. Takes the display off sleep, rings, and waits for the login
/// window if there is one. Returns how many seconds it spent.
private func rouse(_ config: Config, _ effects: Effects) -> Int {
    checkAudible(effects)

    if config.ring {
        let alarm = effects.alarm
        let log = effects.log
        let warn = effects.warn
        alarmQueue.async {
            switch alarm() {
            case .rung(let rings):
                log("rang \(rings) times to be heard")
            case .silent(let reason):
                warn("could not ring: \(reason)")
            }
        }
    } else {
        effects.log("--no-ring was given, staying quiet")
    }

    // The alarm only works while the machine is up, and the machine decides
    // that for itself after this many seconds of silence.
    if let window = effects.powerSettings()?.idleWindowSeconds {
        effects.log("it has \(describeDelay(window)) before it sleeps again, so the alarm has to be answered before then")
    }

    return ensureLoggedIn(effects)
}

/// An alarm nobody can hear is the worst failure this program has, and nothing
/// else here would reveal it. A real 04:00 wake rang 55 times over five minutes
/// and was not heard at all, because the volume was 13.
private func checkAudible(_ effects: Effects) {
    guard case .success(let volume) = effects.outputVolume(), volume < quietVolume else { return }
    effects.warn("the alarm plays at the speaker volume, which is \(volume) - you will not hear it")
}

/// Waits for somebody to log in, up to `loginTimeoutSeconds`.
///
/// What is being waited for is a *console user*, not a visible desktop: a
/// locked screen still has one, and `open -a` run in that session is already
/// in front of the user the moment they unlock. Only the login window, where
/// the console user is `loginwindow` and there is no uid to run anything in,
/// needs waiting for.
private func ensureLoggedIn(_ effects: Effects) -> Int {
    if effects.hasConsoleUser() {
        effects.log("already logged in")
        return 0
    }

    effects.log("waiting for login to complete...")
    var waited = 0
    while waited < loginTimeoutSeconds {
        effects.sleep(1)
        waited += 1
        if effects.hasConsoleUser() {
            effects.log("login complete, session ready")
            return waited
        }
    }
    effects.warn("timed out after \(loginTimeoutSeconds)s waiting for login")
    return waited
}

/// The alarm is unbounded by design, so it gets a queue of its own rather than
/// a thread on the cooperative pool that it would occupy for as long as it takes.
private let alarmQueue = DispatchQueue(label: "showup.alarm")

/// Surfaces the app, and if that fails off the desktop, waits for the login
/// and tries again.
///
/// A locked screen accepts `open` and shows nothing at all, so a failure while
/// nobody is logged in is the lock rather than the app. Retrying is what makes
/// "log in and the window is there" true rather than something the user has to
/// think about.
private func present(_ config: Config, _ effects: Effects) -> ShowOutcome {
    let first = surface(config.app, effects)
    guard case .failed = first, !effects.hasConsoleUser() else { return first }

    effects.log("nobody is logged in, so waiting before trying \(config.app) again")
    _ = ensureLoggedIn(effects)
    return surface(config.app, effects)
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