import gleam/int
import gleam/list
import gleam/string
import gleam/time/calendar.{type TimeOfDay}
import gleam/time/duration.{type Duration}
import gleeunit
import gleeunit/should
import intime/schedule

pub fn main() -> Nil {
  gleeunit.main()
}

fn at(hours: Int, minutes: Int) -> TimeOfDay {
  let assert Ok(parsed) =
    schedule.parse(int.to_string(hours) <> ":" <> pad(minutes))
  parsed
}

fn pad(value: Int) -> String {
  case value < 10 {
    True -> "0" <> int.to_string(value)
    False -> int.to_string(value)
  }
}

fn render(time: TimeOfDay) -> String {
  schedule.to_string(time)
}

fn parse(input: String) -> Result(TimeOfDay, schedule.Error) {
  schedule.parse(input)
}

fn parse_list(inputs: List(String)) -> Result(List(TimeOfDay), schedule.Error) {
  schedule.parse_list(string.join(inputs, with: ","))
}

fn seconds_of(delay: Duration) -> Int {
  let #(seconds, _nanoseconds) = duration.to_seconds_and_nanoseconds(delay)
  seconds
}

fn since(hours: Int, minutes: Int) -> Duration {
  schedule.since_midnight(at(hours, minutes))
}

fn next_of(
  times: List(TimeOfDay),
  now: Duration,
) -> Result(schedule.Wake, schedule.NoTimes) {
  schedule.next(times, from: now)
}

fn wake_at(hours: Int, minutes: Int, delay_seconds: Int) -> schedule.Wake {
  schedule.Wake(at: at(hours, minutes), delay: duration.seconds(delay_seconds))
}

pub fn parses_a_full_time_test() {
  parse("08:30") |> should.equal(Ok(at(8, 30)))
}

pub fn parses_a_bare_hour_test() {
  parse("8") |> should.equal(Ok(at(8, 0)))
}

pub fn parses_a_single_digit_hour_test() {
  parse("8:05") |> should.equal(Ok(at(8, 5)))
}

pub fn parses_midnight_test() {
  parse("0:00") |> should.equal(Ok(at(0, 0)))
}

pub fn reads_the_end_of_the_day_as_midnight_test() {
  parse("24:00") |> should.equal(Ok(at(0, 0)))
}

pub fn rejects_times_past_the_end_of_the_day_test() {
  parse("24:30") |> should.equal(Error(schedule.HourOutOfRange("24:30", 24)))
}

pub fn rejects_an_hour_that_is_too_large_test() {
  parse("25:00") |> should.equal(Error(schedule.HourOutOfRange("25:00", 25)))
}

pub fn rejects_minutes_that_are_too_large_test() {
  parse("8:60") |> should.equal(Error(schedule.MinuteOutOfRange("8:60", 60)))
}

pub fn rejects_text_test() {
  parse("noon") |> should.equal(Error(schedule.Malformed("noon")))
}

pub fn rejects_an_empty_time_test() {
  parse("") |> should.equal(Error(schedule.Malformed("")))
}

pub fn rejects_extra_colons_test() {
  parse("8:00:00") |> should.equal(Error(schedule.Malformed("8:00:00")))
}

pub fn parses_a_list_of_times_test() {
  parse_list(["8:00", "12:00", "20:00"])
  |> should.equal(Ok([at(8, 0), at(12, 0), at(20, 0)]))
}

pub fn ignores_spaces_around_times_test() {
  parse_list([" 8:00 ", "  12:00"])
  |> should.equal(Ok([at(8, 0), at(12, 0)]))
}

pub fn rejects_an_empty_list_test() {
  schedule.parse_list("   ") |> should.equal(Error(schedule.NoTimesGiven))
}

pub fn rejects_an_empty_item_in_a_list_test() {
  parse_list(["8:00", ""]) |> should.equal(Error(schedule.Malformed("")))
}

pub fn renders_times_with_a_leading_zero_test() {
  render(at(8, 5)) |> should.equal("08:05")
}

pub fn renders_midnight_test() {
  render(at(0, 0)) |> should.equal("00:00")
}

pub fn reports_how_far_into_the_day_a_time_is_test() {
  since(6, 30) |> seconds_of |> should.equal(6 * 3600 + 30 * 60)
}

pub fn sorts_times_and_removes_repeats_test() {
  let assert Ok(parsed) = parse_list(["20:00", "8:00", "20:00", "12:00"])
  parsed
  |> schedule.normalise
  |> list.map(render)
  |> should.equal(["08:00", "12:00", "20:00"])
}

pub fn picks_the_soonest_time_today_test() {
  let times = [at(20, 0), at(8, 0), at(12, 0)]
  next_of(times, since(9, 0)) |> should.equal(Ok(wake_at(12, 0, 3 * 3600)))
}

pub fn waits_for_a_time_later_today_test() {
  next_of([at(20, 0)], since(9, 0))
  |> should.equal(Ok(wake_at(20, 0, 11 * 3600)))
}

pub fn wraps_to_tomorrow_when_the_time_has_passed_test() {
  next_of([at(8, 0)], since(9, 0))
  |> should.equal(Ok(wake_at(8, 0, 23 * 3600)))
}

pub fn waits_a_whole_day_when_the_time_is_now_test() {
  next_of([at(9, 0)], since(9, 0))
  |> should.equal(Ok(wake_at(9, 0, 86_400)))
}

pub fn treats_midnight_as_later_today_when_it_is_asked_for_test() {
  next_of([at(24, 0)], since(23, 0))
  |> should.equal(Ok(wake_at(0, 0, 3600)))
}

pub fn has_no_next_time_without_times_test() {
  next_of([], since(9, 0)) |> should.equal(Error(schedule.NothingToSchedule))
}

pub fn lists_the_next_wakes_in_order_test() {
  let times = [at(8, 0), at(12, 0), at(20, 0)]
  times
  |> schedule.upcoming(from: since(7, 0), count: 4)
  |> list.map(fn(wake) { render(wake.at) })
  |> should.equal(["08:00", "12:00", "20:00", "08:00"])
}

pub fn keeps_repeating_the_schedule_over_several_days_test() {
  let times = [at(12, 0), at(20, 0)]
  times
  |> schedule.upcoming(from: since(9, 0), count: 4)
  |> list.map(fn(wake) { #(render(wake.at), seconds_of(wake.delay)) })
  |> should.equal([
    #("12:00", 3 * 3600),
    #("20:00", 8 * 3600),
    #("12:00", 16 * 3600),
    #("20:00", 8 * 3600),
  ])
}

pub fn lists_nothing_when_asked_for_nothing_test() {
  schedule.upcoming([at(8, 0)], from: since(0, 0), count: 0) |> should.equal([])
}

pub fn lists_nothing_without_times_test() {
  schedule.upcoming([], from: since(0, 0), count: 3) |> should.equal([])
}

pub fn describes_every_error_test() {
  let errors = [
    schedule.Malformed("noon"),
    schedule.HourOutOfRange("25:00", 25),
    schedule.MinuteOutOfRange("8:60", 60),
    schedule.NoTimesGiven,
  ]
  errors
  |> list.map(schedule.error_message)
  |> list.all(fn(message) { message != "" })
  |> should.be_true
}
