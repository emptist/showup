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
    idle_seconds: fn() { 600 },
    slept_during: fn(_, _) { Ok(False) },
    show: showing,
    alarm: alarming,
    output_volume: fn() { Ok(100) },
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
  ))
}

/// A machine we had to wake needs a person woken first. This is the fork
/// between the two programs, so it is pinned down directly.
/// Not knowing is treated as having slept. A window raised at a machine
/// nobody is looking at achieves nothing, so when the evidence is thin the
/// loud reading wins.
pub fn asks_the_kernel_to_wake_two_minutes_early_test() {
  scheduler.lead_split(3 * 3600, 300) |> should.equal(#(3 * 3600 - 300, 300))
}

pub fn leaves_a_wake_with_no_lead_window_whole_test() {
  // Forty seconds away is inside the lead window already, so there is no
  // early wake to ask for and nothing to hold back.
  scheduler.lead_split(40, 300) |> should.equal(#(40, 0))
}

pub fn an_exact_lead_length_wake_is_all_lead_test() {
  scheduler.lead_split(300, 300) |> should.equal(#(0, 300))
}

pub fn a_morning_wake_gets_a_minutes_lead_test() {
  scheduler.lead_for(9) |> should.equal(60)
}

pub fn an_afternoon_wake_gets_a_minutes_lead_test() {
  scheduler.lead_for(16) |> should.equal(60)
}

pub fn an_evening_wake_gets_five_minutes_test() {
  scheduler.lead_for(22) |> should.equal(300)
}

pub fn a_small_hours_wake_gets_five_minutes_test() {
  scheduler.lead_for(2) |> should.equal(300)
}

pub fn a_seven_o_clock_wake_is_treated_as_day_test() {
  // The hour a person gets up is the hour the Mac has been up for hours too,
  // so the night lead is no longer wanted.
  scheduler.lead_for(7) |> should.equal(60)
}

pub fn a_ten_past_midnight_wake_gets_five_minutes_test() {
  // 00:10 the next day, so this is the small hours and not the evening.
  scheduler.lead_for(0) |> should.equal(300)
}

/// A log that says the machine never went down is believed, even when the
/// idle counter looks frozen — which it always does when someone is sitting
/// at the machine. This was the false positive that rang at a user who never
/// left the chair.
pub fn a_log_saying_no_is_believed_over_the_counter_test() {
  macos.slept_in("", duration.seconds(64 * 60 + 26), 94)
  |> should.equal(False)
}

/// And the same window with a real Sleep in it still rings.
pub fn a_log_saying_yes_still_wakes_the_person_test() {
  macos.slept_in(real_sleep, duration.seconds(52 * 60 + 50), 370)
  |> should.equal(True)
}

const real_sleep: String =
  "2026-10-19 00:53:02 +0800 Sleep               \tEntering Sleep state due to 'Software Sleep pid=660' 359 secs  "
/// A login that times out must report the time it actually spent.
///
/// It reported `remaining`, which is zero on that branch, so the caller
/// thought nothing had been waited and slept out the whole lead window
/// again — putting a window that needed a password a full lead plus two
/// minutes late, on top of the lateness it had already suffered.
