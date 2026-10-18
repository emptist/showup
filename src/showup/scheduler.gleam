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
    cancel_wake: fn() -> Result(Nil, String),
    show: fn(String) -> macos.Outcome,
    alarm: fn() -> alarm.Outcome,
    idle_seconds: fn() -> Int,
    sleep_timer_seconds: fn() -> Int,
    at_desktop: fn() -> Bool,
    log: fn(String) -> Nil,
    warn: fn(String) -> Nil,
  )
}

/// The outcome of one iteration of the scheduler.
pub type Step {
  /// Slept until `wake.at`, then surfaced the app. `showed` is how that went
  /// and `rung` is what the alarm made of it.
  Surfaced(wake: schedule.Wake, showed: macos.Outcome, rung: alarm.Outcome)
  /// There are no times to wait for.
  Idle
}

/// The effects that talk to the real system clock and to macOS.
pub fn live(alarm: fn() -> alarm.Outcome) -> Effects {
  Effects(
    now: now,
    sleep: sleep,
    schedule_wake: macos.schedule_wake,
    cancel_wake: macos.cancel_wake,
    show: macos.show,
    alarm: alarm,
    idle_seconds: macos.idle_seconds,
    sleep_timer_seconds: macos.sleep_timer_seconds,
    at_desktop: macos.at_desktop,
    log: fn(message) { io.println("showup: " <> message) },
    warn: fn(message) { io.println_error("showup: " <> message) },
  )
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

/// Extra margin on top of the system sleep timer. If idle exceeds this we
/// know the Mac was actually asleep (not just the user stepped away for a
/// bit longer than their sleep timer).
const sleep_margin_seconds: Int = 60

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
      let TimeOfDay(hours: hour, minutes: minute, ..) = wake.at
      let #(delay_seconds, _) =
        duration.to_seconds_and_nanoseconds(wake.delay)
      let datetime = macos.pmset_datetime(hour, minute, delay_seconds)
      effects.log(
        "waking at "
        <> schedule.to_string(wake.at)
        <> " (pmset "
        <> datetime
        <> "), in "
        <> describe_delay(wake.delay),
      )
      // Ask the kernel to wake the Mac exactly when we need it. pmset
      // schedule is a one-shot — it fires once and then the kernel forgets
      // about it, so there is no need to cancel stale ones beforehand.
      case effects.schedule_wake(datetime) {
        Error(reason) ->
          effects.warn(
            "could not schedule wake (did you run with sudo?): " <> reason,
          )
        Ok(_) -> Nil
      }
      effects.sleep(wake.delay)

      // Read idle BEFORE ringing — the alarm waits for a keyboard/mouse
      // touch to stop ringing, and that touch resets HIDIdleTime to 0. If
      // we read idle after the alarm it will always be 0 and we could
      // never tell scenario 1 (Mac stayed awake) from scenario 2 (Mac
      // slept, pmset woke us).
      let idle = effects.idle_seconds()
      let threshold = effects.sleep_timer_seconds() + sleep_margin_seconds
      let was_sleeping = idle > threshold

      case was_sleeping {
        True ->
          effects.log(
            "machine was sleeping (idle "
            <> int.to_string(idle)
            <> "s > threshold "
            <> int.to_string(threshold)
            <> "s)",
          )
        False ->
          effects.log(
            "machine was awake (idle "
            <> int.to_string(idle)
            <> "s <= threshold "
            <> int.to_string(threshold)
            <> "s)",
          )
      }

      // Both scenarios ring — the user must acknowledge the alarm whether
      // they were actively working or were woken from sleep.
      let rung = effects.alarm()
      case rung {
        alarm.Awake -> effects.log("you were already awake, skipping alarm")
        alarm.Rung(rings: rings) ->
          effects.log(
            "rang " <> int.to_string(rings) <> " times to be heard",
          )
        alarm.Silent(reason: reason) ->
          effects.warn("could not ring: " <> reason)
      }

      // Scenario 2 only: user woke from sleep, likely typing password at
      // login window. Wait for desktop before surfacing so `open -a` fires
      // into a real session. Scenario 1 is already at the desktop.
      case was_sleeping {
        True -> ensure_at_desktop(effects)
        False -> Nil
      }

      let showed = effects.show(app)
      report(app, showed, effects)

      Surfaced(wake: wake, showed: showed, rung: rung)
    }
  }
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
fn ensure_at_desktop(effects: Effects) -> Nil {
  poll_until_desktop(effects, 120)
}

fn poll_until_desktop(effects: Effects, remaining: Int) -> Nil {
  case effects.at_desktop() {
    True -> Nil
    False ->
      case remaining > 0 {
        True -> {
          effects.sleep(duration.seconds(1))
          poll_until_desktop(effects, remaining - 1)
        }
        False -> effects.warn("timed out waiting for login")
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
