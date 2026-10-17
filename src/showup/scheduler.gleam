import gleam/int
import gleam/io
import gleam/list
import gleam/string
import gleam/time/calendar.{type TimeOfDay}
import gleam/time/duration.{type Duration}
import gleam/time/timestamp
import showup/macos
import showup/schedule

/// Everything the scheduler needs from the outside world, gathered in one
/// place so the loop can be driven by a fake clock in the tests.
pub type Effects {
  Effects(
    now: fn() -> Duration,
    sleep: fn(Duration) -> Nil,
    show: fn(String) -> macos.Outcome,
    log: fn(String) -> Nil,
    warn: fn(String) -> Nil,
  )
}

/// The outcome of one iteration of the scheduler.
pub type Step {
  /// Slept until `wake.at`, then surfaced the app. `showed` is how that went.
  Surfaced(wake: schedule.Wake, showed: macos.Outcome)
  /// There are no times to wait for.
  Idle
}

/// The effects that talk to the real system clock and to macOS.
pub fn live() -> Effects {
  Effects(
    now: local_time_of_day,
    sleep: sleep,
    show: macos.show,
    log: fn(message) { io.println("showup: " <> message) },
    warn: fn(message) { io.println_error("showup: " <> message) },
  )
}

/// Surfaces `app` at every time, for as long as the program runs.
pub fn run(app: String, times: List(TimeOfDay), effects: Effects) -> Nil {
  case step(app, times, effects) {
    Surfaced(..) -> run(app, times, effects)
    Idle -> effects.log("no times to wait for, stopping")
  }
}

/// Waits for the next time, surfaces the app, and reports what happened.
pub fn step(app: String, times: List(TimeOfDay), effects: Effects) -> Step {
  case schedule.next(times, effects.now()) {
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
      Surfaced(wake: wake, showed: showed)
    }
  }
}

fn report(app: String, showed: macos.Outcome, effects: Effects) -> Nil {
  case showed {
    macos.Launched -> effects.log("launched " <> app)
    macos.Surfaced -> effects.log("brought " <> app <> " to the foreground")
    macos.CouldNotRaise(reason: reason) ->
      effects.warn(
        "surfaced "
        <> app
        <> " but could not raise its window, grant Accessibility permission to this program: "
        <> reason,
      )
    macos.Failed(reason: reason) ->
      effects.warn("could not show " <> app <> ": " <> reason)
  }
}

/// How long it has been since local midnight, read from the system clock.
///
/// The local offset is the one in force right now, which is what makes this
/// correct across daylight saving changes for a schedule that repeats daily.
fn local_time_of_day() -> Duration {
  let #(unix_seconds, _nanoseconds) =
    timestamp.to_unix_seconds_and_nanoseconds(timestamp.system_time())
  let #(offset_seconds, _offset_nanoseconds) =
    duration.to_seconds_and_nanoseconds(calendar.local_offset())
  let local_seconds = unix_seconds + offset_seconds
  duration.seconds(local_seconds % 86_400)
}

@external(erlang, "showup_erl", "sleep_ms")
fn sleep_ms(milliseconds: Int) -> Nil

fn sleep(delay: Duration) -> Nil {
  sleep_ms(duration.to_milliseconds(delay))
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
