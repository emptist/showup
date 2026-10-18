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
    keep_awake: fn(Int) -> Result(Nil, String),
    show: fn(String) -> macos.Outcome,
    alarm: fn() -> alarm.Outcome,
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
    keep_awake: macos.keep_awake,
    show: macos.show,
    alarm: alarm,
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

/// Seconds for the power assertion. 60s is long enough to cover
/// `open -a`, any ringing, and a small drift margin, while still short
/// enough that the Mac can sleep again within one minute of finishing.
const keep_awake_seconds: Int = 60

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

      // Ring → Brighten → Wait → Show. The wait between alarm stopping and
      // the `open -a` call is crucial: the alarm stops when the user touches
      // the keyboard, but they are still typing their password. If we call
      // `open -a` during login, macOS queues it and processes it 30+ seconds
      // later. A short wait after alarm stops lets the login complete first,
      // so `open -a` fires into an already-active desktop session.
      let rung = effects.alarm()
      case rung {
        alarm.Awake -> effects.log("you were already awake, skipping alarm")
        alarm.Rung(rings: rings) ->
          effects.log("rang " <> int.to_string(rings) <> " times to be heard")
        alarm.Silent(reason: reason) -> effects.warn("could not ring: " <> reason)
      }

      case effects.keep_awake(keep_awake_seconds) {
        Error(reason) -> effects.warn("could not prevent sleep: " <> reason)
        Ok(_) -> Nil
      }

      // Give login screen time to process the user's password input.
      effects.sleep(duration.seconds(5))

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
