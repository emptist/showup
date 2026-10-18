import gleam/int
import gleam/time/calendar.{type TimeOfDay}
import gleam/time/duration.{type Duration}
import gleeunit
import gleeunit/should
import showup/alarm
import showup/macos
import showup/schedule
import showup/scheduler

pub fn main() -> Nil {
  gleeunit.main()
}

fn at(hours: Int, minutes: Int) -> TimeOfDay {
  let assert Ok(parsed) =
    schedule.parse(int.to_string(hours) <> ":" <> int.to_string(minutes))
  parsed
}

fn nine_o_clock() -> Duration {
  duration.hours(9)
}

fn noon() -> Duration {
  duration.hours(12)
}

fn seconds_of(period: Duration) -> Int {
  let #(seconds, _nanoseconds) = duration.to_seconds_and_nanoseconds(period)
  seconds
}

fn effects(
  now: Duration,
  showing: fn(String) -> macos.Outcome,
) -> scheduler.Effects {
  effects_alarming(now, showing, fn() { alarm.Awake })
}

fn effects_alarming(
  now: Duration,
  showing: fn(String) -> macos.Outcome,
  alarming: fn() -> alarm.Outcome,
) -> scheduler.Effects {
  scheduler.Effects(
    now: fn() { now },
    sleep: fn(_) { Nil },
    schedule_wake: fn(_) { Ok(Nil) },
    cancel_wake: fn() { Ok(Nil) },
    show: showing,
    alarm: alarming,
    at_desktop: fn() { True },
    log: fn(_) { Nil },
    warn: fn(_) { Nil },
  )
}

fn wake_at(hours: Int, minutes: Int, delay_hours: Int) -> schedule.Wake {
  schedule.Wake(at: at(hours, minutes), delay: duration.hours(delay_hours))
}

pub fn waits_then_surfaces_the_app_test() {
  let result =
    scheduler.step(
      "Safari",
      [at(12, 0)],
      effects(nine_o_clock(), fn(_) { macos.Launched }),
      from: nine_o_clock(),
    )
  result
  |> should.equal(scheduler.Surfaced(
    wake: wake_at(12, 0, 3),
    showed: macos.Launched,
    rung: alarm.Awake,
  ))
}

pub fn passes_the_app_name_to_the_platform_test() {
  let result =
    scheduler.step(
      "Safari",
      [at(12, 0)],
      effects(nine_o_clock(), fn(app) {
        case app {
          "Safari" -> macos.Surfaced
          other -> macos.Failed(reason: "asked for " <> other)
        }
      }),
      from: nine_o_clock(),
    )
  result
  |> should.equal(scheduler.Surfaced(
    wake: wake_at(12, 0, 3),
    showed: macos.Surfaced,
    rung: alarm.Awake,
  ))
}

pub fn reports_a_failure_without_stopping_test() {
  let result =
    scheduler.step(
      "Nope",
      [at(12, 0)],
      effects(nine_o_clock(), fn(_) {
        macos.Failed(reason: "Unable to find application")
      }),
      from: nine_o_clock(),
    )
  result
  |> should.equal(scheduler.Surfaced(
    wake: wake_at(12, 0, 3),
    showed: macos.Failed(reason: "Unable to find application"),
    rung: alarm.Awake,
  ))
}

pub fn does_nothing_without_times_test() {
  scheduler.step(
    "Safari",
    [],
    effects(nine_o_clock(), fn(_) { macos.Launched }),
    from: nine_o_clock(),
  )
  |> should.equal(scheduler.Idle)
}

pub fn describes_whole_hours_test() {
  scheduler.describe_delay(duration.hours(1)) |> should.equal("1h")
}

pub fn describes_hours_and_minutes_test() {
  scheduler.describe_delay(
    duration.hours(1) |> duration.add(duration.minutes(5)),
  )
  |> should.equal("1h 5m")
}

pub fn describes_minutes_and_seconds_test() {
  scheduler.describe_delay(
    duration.minutes(5) |> duration.add(duration.seconds(3)),
  )
  |> should.equal("5m 3s")
}

pub fn describes_seconds_test() {
  scheduler.describe_delay(duration.seconds(9)) |> should.equal("9s")
}

pub fn describes_no_delay_test() {
  scheduler.describe_delay(duration.seconds(0)) |> should.equal("0s")
}

pub fn keeps_the_planned_instant_after_a_slow_wake_test() {
  let planned = noon()
  let now = duration.add(noon(), duration.seconds(2))
  scheduler.next_instant(planned, duration.hours(24), now)
  |> seconds_of
  |> should.equal(86_400 + 12 * 3600)
}

pub fn gives_up_on_the_plan_after_missing_a_wake_test() {
  // The machine slept past tomorrow's noon wake, so the plan is stale.
  let target = duration.add(noon(), duration.hours(24))
  let now = duration.add(target, duration.minutes(90))
  scheduler.next_instant(noon(), duration.hours(24), now)
  |> seconds_of
  |> should.equal(seconds_of(now))
}

pub fn rings_after_surfacing_the_app_test() {
  let result =
    scheduler.step(
      "Safari",
      [at(12, 0)],
      effects_alarming(nine_o_clock(), fn(_) { macos.Surfaced }, fn() {
        alarm.Rung(rings: 3)
      }),
      from: nine_o_clock(),
    )
  result
  |> should.equal(scheduler.Surfaced(
    wake: wake_at(12, 0, 3),
    showed: macos.Surfaced,
    rung: alarm.Rung(rings: 3),
  ))
}

pub fn rings_even_for_an_app_it_could_not_show_test() {
  // Alarm fires BEFORE show, so the user is woken even if the app cannot be
  // surfaced. Silence would defeat the purpose — the user needs to know
  // something is supposed to happen.
  let result =
    scheduler.step(
      "Nope",
      [at(12, 0)],
      effects_alarming(
        nine_o_clock(),
        fn(_) { macos.Failed(reason: "no such app") },
        fn() { alarm.Rung(rings: 3) },
      ),
      from: nine_o_clock(),
    )
  result
  |> should.equal(scheduler.Surfaced(
    wake: wake_at(12, 0, 3),
    showed: macos.Failed(reason: "no such app"),
    rung: alarm.Rung(rings: 3),
  ))
}
