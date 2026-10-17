import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import gleam/time/calendar.{type TimeOfDay}
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
      effects.log(
        "waking at "
        <> schedule.to_string(wake.at)
        <> ", in "
        <> describe_delay(wake.delay),
      )
      effects.sleep(wake.delay)
      let showed = effects.show(app)
      report(app, showed, effects)
      let rung = ring(effects, showed)
      Surfaced(wake: wake, showed: showed, rung: rung)
    }
  }
}

/// Rings the alarm once the app is up, unless it could not be shown at all.
///
/// Ringing for an app that is not installed would be noise about nothing.
fn ring(effects: Effects, showed: macos.Outcome) -> alarm.Outcome {
  case showed {
    macos.Failed(reason: reason) -> {
      effects.warn("not ringing for an app that could not be shown: " <> reason)
      alarm.Awake
    }
    macos.Launched | macos.Surfaced ->
      case effects.alarm() {
        alarm.Awake -> {
          effects.log("you are at the machine, so no alarm")
          alarm.Awake
        }
        alarm.Rung(rings: rings) -> {
          effects.log("rang " <> int.to_string(rings) <> " times to be heard")
          alarm.Rung(rings: rings)
        }
        alarm.Silent(reason: reason) -> {
          effects.warn("could not ring: " <> reason)
          alarm.Silent(reason: reason)
        }
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
