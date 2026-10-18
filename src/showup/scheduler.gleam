import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import gleam/time/calendar.{type TimeOfDay, TimeOfDay}
import gleam/time/duration.{type Duration}
import gleam/time/timestamp
import showup/alarm
import showup/macos
import showup/schedule

/// Everything the scheduler needs from the outside world, gathered in one
/// place so the loop can be driven by a fake clock in the tests.
pub type Effects {
  Effects(
    now: fn() -> Duration,
    sleep: fn(Duration) -> Nil,
    schedule_wake: fn(String) -> Result(Nil, String),
    keep_awake: fn(Int) -> Result(Nil, String),
    /// How long the keyboard and mouse have been untouched.
    idle_seconds: fn() -> Int,
    /// Whether the machine went to sleep inside a wait beginning at the
    /// given time of day. Errors are reported as a sleep, because not
    /// knowing must not mean silence.
    slept_during: fn(Duration, Int) -> Result(Bool, String),
    show: fn(String) -> macos.Outcome,
    /// Rings until someone touches the keyboard or mouse.
    alarm: fn() -> alarm.Outcome,
    at_desktop: fn() -> Bool,
    log: fn(String) -> Nil,
    warn: fn(String) -> Nil,
  )
}

/// The outcome of one iteration of the scheduler.
pub type Step {
  /// Slept until `wake.at`, then surfaced the app. `showed` is how that went.
  ///
  /// There is no field for what the alarm did: it runs in its own process
  /// and reports by logging, so by the time this is built there is nothing
  /// truthful left to record.
  Surfaced(wake: schedule.Wake, showed: macos.Outcome)
  /// There are no times to wait for.
  Idle
}

/// The effects that talk to the real system clock and to macOS.
pub fn live(alarm: fn() -> alarm.Outcome) -> Effects {
  Effects(
    now: now,
    sleep: sleep,
    schedule_wake: macos.schedule_wake,
    keep_awake: macos.keep_awake,
    idle_seconds: macos.idle_seconds,
    slept_during: macos.slept_during,
    show: macos.show,
    alarm: alarm,
    at_desktop: macos.at_desktop,
    log: fn(message) {
      io.println("showup: " <> message)
      record(message)
    },
    warn: fn(message) {
      io.println_error("showup: " <> message)
      record("WARNING " <> message)
    },
  )
}

/// Writes one line to the log file, stamped with the time.
///
/// Best effort: a log that cannot be written is not a reason to stop
/// surfacing apps, so the result is discarded.
fn record(message: String) -> Nil {
  let #(seconds, _) = duration.to_seconds_and_nanoseconds(now())
  let line = clock(seconds) <> "  " <> message
  let _ = macos.append_log(line)
  Nil
}

/// Seconds since midnight as `HH:MM:SS`.
fn clock(seconds: Int) -> String {
  pad(seconds / 3600)
  <> ":"
  <> pad(seconds / 60 % 60)
  <> ":"
  <> pad(seconds % 60)
}

fn pad(value: Int) -> String {
  string.pad_start(int.to_string(value), to: 2, with: "0")
}

/// Surfaces `app` at every time, for as long as the program runs.
pub fn run(app: String, times: List(TimeOfDay), effects: Effects) -> Nil {
  loop(app, times, effects, from: effects.now())
}

fn loop(
  app: String,
  times: List(TimeOfDay),
  effects: Effects,
  from instant: Duration,
) -> Nil {
  case step(app, times, effects, from: instant) {
    Surfaced(wake: wake, ..) ->
      loop(
        app,
        times,
        effects,
        from: next_instant(instant, wake.delay, effects.now()),
      )
    Idle -> effects.log("no times to wait for, stopping")
  }
}

/// The instant the next wake is measured from.
///
/// Measuring from the wake that was just planned, rather than from the clock
/// read after it, keeps the interval at a whole day even though surfacing an
/// app always costs a second or two. If the machine slept through the wake the
/// plan is a fiction, so the clock takes over again.
pub fn next_instant(
  planned: Duration,
  delay: Duration,
  now: Duration,
) -> Duration {
  let target = duration.add(planned, delay)
  case whole_seconds(now) - whole_seconds(target) > resync_after_seconds {
    True -> now
    False -> target
  }
}

const resync_after_seconds: Int = 60

/// How long to hold the machine awake once the sleep returns.
///
/// Sized to cover the work that follows a wake rather than the day: the
/// login poll can spend up to 120 seconds, and six alarm rings take about
/// 45 more (a 2.2 second tone plus a 5 second gap each). After this the
/// Mac is free to sleep again on its own idle timer.
const keep_awake_seconds: Int = 180

fn whole_seconds(period: Duration) -> Int {
  let #(seconds, _nanoseconds) = duration.to_seconds_and_nanoseconds(period)
  seconds
}

/// Waits for the next time, surfaces the app, and reports what happened.
pub fn step(
  app: String,
  times: List(TimeOfDay),
  effects: Effects,
  from now: Duration,
) -> Step {
  case schedule.next(times, now) {
    Error(schedule.NothingToSchedule) -> Idle
    Ok(wake) -> {
      let #(delay_seconds, _) = duration.to_seconds_and_nanoseconds(wake.delay)

      // Waking the Mac early is what makes the window land on the time. If
      // we asked the kernel for the time itself, the display would come up
      // and the user would have to be woken and logged in during the very
      // minute the app was supposed to appear, so it would always be late.
      // Instead the kernel is asked for the lead window beforehand, and the
      // waking is done inside it.
      let TimeOfDay(hours: hour, ..) = wake.at
      let lead_seconds = lead_for(hour)
      let #(ahead, remaining) = lead_split(delay_seconds, lead_seconds)
      let datetime = macos.pmset_datetime(ahead)
      effects.log(
        "waking at "
        <> schedule.to_string(wake.at)
        <> " (pmset "
        <> datetime
        <> "), in "
        <> describe_delay(wake.delay),
      )
      // Ask the kernel to wake the Mac at that earlier moment. pmset
      // schedule is a one-shot — it fires once and then the kernel forgets
      // about it, so there is no need to cancel stale ones beforehand.
      case effects.schedule_wake(datetime) {
        Error(reason) ->
          effects.warn(
            "could not schedule wake (did you run with sudo?): " <> reason,
          )
        Ok(_) -> Nil
      }
      // Did the machine go down while we waited? The clock cannot say, and
      // neither can the idle counter, which freezes both across a sleep and
      // under a pair of hands — so an awake machine with someone at it reads
      // as a sleeping one, and rings at them.
      //
      // The power log can, because a `Sleep` line is written when the
      // machine goes down, minutes before we could ask, while a `Wake` line
      // is only written once powerd has finished waking. Only the second one
      // lags, and only the first one is needed: is there a Sleep inside the
      // window we just waited?
      let started = effects.now()
      effects.sleep(duration.seconds(ahead))
      let elapsed = seconds_between(started, effects.now())

      // The log is the only thing consulted, and it is believed when it
      // answers. It used to be OR-ed with the frozen-counter heuristic as a
      // "belt and braces" second opinion, which rang at a user sitting at an
      // awake machine: the counter cannot tell sleep from hands on a
      // keyboard, so it disagreed with a log that had the real answer. A
      // fallback that is consulted when the primary is right is not a
      // fallback, it is a second opinion with no evidence behind it.
      //
      // Silence is still the worse failure, so a log that cannot be read is
      // treated as a sleep — but a log that says no is believed.
      let slept = case effects.slept_during(started, elapsed) {
        Ok(slept) -> slept
        Error(reason) -> {
          effects.warn("could not read the power log: " <> reason)
          True
        }
      }

      case slept {
        True -> {
          effects.log("the Mac was asleep, waking you up first")
          let spent = rouse(effects)
          sleep_remaining(remaining - spent, effects)
        }
        False -> {
          effects.log("the Mac was awake throughout, nothing to wake")
          sleep_remaining(remaining, effects)
        }
      }

      let showed = surface(app, effects)
      Surfaced(wake: wake, showed: showed)
    }
  }
}

/// Whole seconds from one clock reading to another, round the clock so a
/// wait that crosses midnight is not read as a negative.
fn seconds_between(from: Duration, to: Duration) -> Int {
  let difference = whole_seconds(to) - whole_seconds(from)
  case difference < 0 {
    True -> difference + 86_400
    False -> difference
  }
}

/// Splits a wait into the part before the kernel is asked to wake the Mac
/// and the lead window that follows it.
///
/// A wake closer than the lead window has none to give, so it is left whole
/// rather than turned inside out.
pub fn lead_split(delay_seconds: Int, lead_seconds: Int) -> #(Int, Int) {
  case delay_seconds >= lead_seconds {
    True -> #(delay_seconds - lead_seconds, lead_seconds)
    False -> #(delay_seconds, 0)
  }
}

/// How far ahead of the scheduled time to wake the machine, decided by the
/// hour the wake falls in rather than by anything we can observe.
///
/// In the morning the machine has usually been up for hours and whoever owns
/// it is at it, so a minute is enough to have the window ready on the time.
///
/// Overnight that assumption is wrong in both directions: the machine is
/// likely asleep, and the person has to be woken and may have to type a
/// password before a window means anything. Five minutes of lead is what
/// that takes, and it is also why the alarm is given a budget to match —
/// see `ring_budget`. The lead has to cover the 120 second login poll on its
/// own, before any ringing is counted.
pub fn lead_for(hour: Int) -> Int {
  case is_night(hour) {
    True -> night_lead_seconds
    False -> day_lead_seconds
  }
}

fn is_night(hour: Int) -> Bool {
  hour >= night_starts_at || hour < night_ends_at
}

const night_starts_at: Int = 22

const night_ends_at: Int = 7

const day_lead_seconds: Int = 60

const night_lead_seconds: Int = 300

/// How many rings fit in a lead window.
///
/// One ring is the 2.2 second tone plus the 5 second gap after it, so this
/// is the most rings that can be played before the window is up. Without it
/// the alarm gives up long before the window ends, and a five minute lead
/// would sit silent for four of those five minutes.
pub fn ring_budget(lead_seconds: Int) -> Int {
  case lead_seconds / ring_seconds {
    rings if rings < 1 -> 1
    rings -> rings
  }
}

const ring_seconds: Int = 7

/// Sleeps out whatever is left of the lead window, and no longer.
fn sleep_remaining(seconds: Int, effects: Effects) -> Nil {
  case seconds > 0 {
    True -> effects.sleep(duration.seconds(seconds))
    False -> Nil
  }
}

/// Program 2. Brings a sleeping machine and its owner back to life.
///
/// Only runs when the power log says the wake we asked for is the one that
/// released us. Everything here is deliberately skipped when the machine
/// was already up: ringing at someone who is working, or waiting for a
/// login that is not happening, is worse than doing nothing.
///
/// The ring goes to its own process so we do not wait for it to stop, and
/// the desktop check starts immediately rather than after it — if the login
/// finishes quickly the window can go up while the ring is still going.
///
/// Returns roughly how long it took, so the caller can work out how much of
/// the lead window is left. That matters: the whole point of the lead is
/// that the window still goes up on the time, and a caller that blindly
/// slept for the full lead afterwards would put it back where it started.
fn rouse(effects: Effects) -> Int {
  // `pmset schedule wake` wakes the CPU but leaves the display dark. `-u`
  // declares user activity, which is what actually brings the screen back
  // and speaker-enables the tone. A Power Nap window can also close again
  // before the work below finishes, so the assertion is held for as long as
  // that work can take. Failing to get it is not a reason to skip the wake.
  case effects.keep_awake(keep_awake_seconds) {
    Ok(_) -> Nil
    Error(reason) ->
      effects.warn("could not hold a power assertion: " <> reason)
  }

  process.spawn(fn() {
    let rung = effects.alarm()
    case rung {
      alarm.Awake -> effects.log("you were already awake, skipping alarm")
      alarm.Rung(rings: rings) ->
        effects.log("rang " <> int.to_string(rings) <> " times to be heard")
      alarm.Silent(reason: reason) -> effects.warn("could not ring: " <> reason)
    }
  })

  ensure_at_desktop(effects)
}

/// Program 1. Puts the app in front of whoever is there.
///
/// The whole of it. Once the machine is alive and someone is at it, raising
/// the window is the entire job — no sound, no waiting, no ceremony.
fn surface(app: String, effects: Effects) -> macos.Outcome {
  effects.log("about to show " <> app)
  let showed = effects.show(app)
  report(app, showed, effects)
  showed
}

fn report(app: String, showed: macos.Outcome, effects: Effects) -> Nil {
  case showed {
    macos.Launched -> effects.log("launched " <> app)
    macos.Surfaced -> effects.log("brought " <> app <> " to the foreground")
    macos.Failed(reason: reason) ->
      effects.warn("could not show " <> app <> ": " <> reason)
  }
}

/// After the alarm stops ringing we know the user is at the machine, but
/// they may still be on the login window typing their password. If they
/// autologin, `at_desktop()` returns immediately — nothing to wait for.
/// If they have a password we poll until the desktop appears, so `open -a`
/// fires into a real session instead of being queued behind the login.
///
/// Gives up after 120 seconds in case they walked away mid-login.
///
/// Returns roughly how long it waited, so the caller can spend what is left
/// of the lead window rather than overshooting the scheduled time.
fn ensure_at_desktop(effects: Effects) -> Int {
  case effects.at_desktop() {
    True -> {
      effects.log("already at desktop")
      0
    }
    False -> {
      effects.log("waiting for login to complete...")
      let waited = poll_until_desktop(effects, login_timeout_seconds)
      waited
    }
  }
}

const login_timeout_seconds: Int = 120

fn poll_until_desktop(effects: Effects, remaining: Int) -> Int {
  case effects.at_desktop() {
    True -> {
      effects.log("login complete, desktop ready")
      0
    }
    False ->
      case remaining > 0 {
        True -> {
          effects.sleep(duration.seconds(1))
          1 + poll_until_desktop(effects, remaining - 1)
        }
        False -> {
          effects.warn("timed out waiting for login")
          remaining
        }
      }
  }
}

/// How long it has been since local midnight, read from the system clock.
///
/// The local offset is the one in force right now, which is what makes this
/// correct across daylight saving changes for a schedule that repeats daily.
pub fn now() -> Duration {
  let #(unix_seconds, _nanoseconds) =
    timestamp.to_unix_seconds_and_nanoseconds(timestamp.system_time())
  let #(offset_seconds, _offset_nanoseconds) =
    duration.to_seconds_and_nanoseconds(calendar.local_offset())
  let local_seconds = unix_seconds + offset_seconds
  duration.seconds(local_seconds % 86_400)
}

fn sleep(delay: Duration) -> Nil {
  process.sleep(duration.to_milliseconds(delay))
}

/// Renders a delay as `1h 5m 3s`, leaving out any units that are zero.
pub fn describe_delay(delay: Duration) -> String {
  let #(total_seconds, _nanoseconds) =
    duration.to_seconds_and_nanoseconds(delay)
  let hours = total_seconds / 3600
  let minutes = total_seconds / 60 % 60
  let seconds = total_seconds % 60
  case hours {
    0 -> join([unit(minutes, "m"), unit(seconds, "s")])
    _ -> join([unit(hours, "h"), unit(minutes, "m"), unit(seconds, "s")])
  }
}

fn unit(size: Int, label: String) -> String {
  case size > 0 {
    True -> int.to_string(size) <> label
    False -> ""
  }
}

fn join(parts: List(String)) -> String {
  let present = list.filter(parts, fn(part) { part != "" })
  case present {
    [] -> "0s"
    _ -> string.join(present, with: " ")
  }
}
