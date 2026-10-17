import gleam/int
import gleam/list
import gleam/order
import gleam/result
import gleam/string
import gleam/time/calendar.{type TimeOfDay, TimeOfDay}
import gleam/time/duration.{type Duration}

/// A moment the scheduler is going to wake up at.
pub type Wake {
  Wake(at: TimeOfDay, delay: Duration)
}

/// The one way scheduling a wake can fail: there is nothing to wake for.
pub type NoTimes {
  NothingToSchedule
}

pub type Error {
  /// The text was not shaped like `H`, `H:MM` or `HH:MM`.
  Malformed(input: String)
  HourOutOfRange(input: String, hour: Int)
  MinuteOutOfRange(input: String, minute: Int)
  NoTimesGiven
}

/// Parses a time of day, written as `8`, `8:00` or `08:00`.
///
/// `24:00` is the end of the day, which is the same moment as midnight at the
/// start of the next one, so it is read as `0:00`.
pub fn parse(input: String) -> Result(TimeOfDay, Error) {
  case string.split(input, on: ":") {
    [hour] -> build(input, hour, "0")
    [hour, minute] -> build(input, hour, minute)
    _ -> Error(Malformed(input: input))
  }
}

/// Parses a comma separated list of times, such as `8:00,12:00,20:00`.
pub fn parse_list(input: String) -> Result(List(TimeOfDay), Error) {
  case string.trim(input) {
    "" -> Error(NoTimesGiven)
    _ ->
      input
      |> string.split(on: ",")
      |> list.map(string.trim)
      |> list.map(parse)
      |> result.all
  }
}

fn build(
  input: String,
  hour: String,
  minute: String,
) -> Result(TimeOfDay, Error) {
  case int.parse(hour) {
    Error(_) -> Error(Malformed(input: input))
    Ok(hour) ->
      case int.parse(minute) {
        Error(_) -> Error(Malformed(input: input))
        Ok(minute) -> of_day(input, hour, minute)
      }
  }
}

fn of_day(input: String, hour: Int, minute: Int) -> Result(TimeOfDay, Error) {
  let hours = case hour == 24 && minute == 0 {
    True -> 0
    False -> hour
  }
  let time =
    TimeOfDay(hours: hours, minutes: minute, seconds: 0, nanoseconds: 0)
  case calendar.is_valid_time_of_day(time) {
    True -> Ok(time)
    False -> Error(describe_invalid(input, time))
  }
}

fn describe_invalid(input: String, time: TimeOfDay) -> Error {
  let TimeOfDay(hours: hours, minutes: minutes, ..) = time
  case hours < 0 || hours > 23 {
    True -> HourOutOfRange(input: input, hour: hours)
    False -> MinuteOutOfRange(input: input, minute: minutes)
  }
}

/// Sorts times into the order they occur, discarding repeated ones.
pub fn normalise(times: List(TimeOfDay)) -> List(TimeOfDay) {
  let by_time = fn(one: TimeOfDay, other: TimeOfDay) {
    int.compare(
      whole_seconds(since_midnight(one)),
      whole_seconds(since_midnight(other)),
    )
  }
  times |> list.unique |> list.sort(by: by_time)
}

/// How long it is from the start of the day until the given time.
pub fn since_midnight(time: TimeOfDay) -> Duration {
  let TimeOfDay(
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    nanoseconds: nanoseconds,
  ) = time
  duration.hours(hours)
  |> duration.add(duration.minutes(minutes))
  |> duration.add(duration.seconds(seconds))
  |> duration.add(duration.nanoseconds(nanoseconds))
}

/// The length of a period in whole seconds.
///
/// Durations are compared as plain integers because `gleam_time`'s own
/// comparison orders negative durations wrongly, and a delay is negative for
/// the whole of the day before a time is due.
fn whole_seconds(period: Duration) -> Int {
  let #(seconds, _nanoseconds) = duration.to_seconds_and_nanoseconds(period)
  seconds
}

/// Renders a time as `HH:MM`.
pub fn to_string(time: TimeOfDay) -> String {
  let TimeOfDay(hours: hours, minutes: minutes, ..) = time
  pad(hours) <> ":" <> pad(minutes)
}

/// The soonest of `times` that has not happened yet, wrapping to tomorrow.
pub fn next(
  times: List(TimeOfDay),
  from now: Duration,
) -> Result(Wake, NoTimes) {
  times |> list.map(fn(at) { wake(at, now) }) |> soonest
}

/// The next `count` wake times, in the order they occur.
pub fn upcoming(
  times: List(TimeOfDay),
  from now: Duration,
  count count: Int,
) -> List(Wake) {
  case count <= 0 {
    True -> []
    False ->
      case next(times, now) {
        Ok(Wake(at: at, delay: delay)) -> [
          Wake(at: at, delay: delay),
          ..upcoming(times, duration.add(now, delay), count - 1)
        ]
        Error(NothingToSchedule) -> []
      }
  }
}

fn soonest(wakes: List(Wake)) -> Result(Wake, NoTimes) {
  case wakes {
    [] -> Error(NothingToSchedule)
    [soonest, ..rest] ->
      Ok(
        list.fold(rest, from: soonest, with: fn(current, candidate) {
          case
            int.compare(
              whole_seconds(candidate.delay),
              whole_seconds(current.delay),
            )
          {
            order.Lt -> candidate
            order.Eq | order.Gt -> current
          }
        }),
      )
  }
}

fn wake(at: TimeOfDay, now: Duration) -> Wake {
  let until = whole_seconds(since_midnight(at)) - whole_seconds(now) % 86_400
  let delay_seconds = case int.compare(until, 0) {
    order.Gt -> until
    order.Eq | order.Lt -> until + 86_400
  }
  Wake(at: at, delay: duration.seconds(delay_seconds))
}

pub fn error_message(error: Error) -> String {
  case error {
    Malformed(input: input) ->
      "expected a time like 8:00, but got " <> quoted(input)
    HourOutOfRange(input: input, hour: hour) ->
      "expected an hour between 0 and 23, or 24:00 for midnight, but got "
      <> quoted(input)
      <> " (hour "
      <> int.to_string(hour)
      <> ")"
    MinuteOutOfRange(input: input, minute: minute) ->
      "expected minutes between 00 and 59, but got "
      <> quoted(input)
      <> " (minutes "
      <> int.to_string(minute)
      <> ")"
    NoTimesGiven -> "no times were given"
  }
}

fn pad(value: Int) -> String {
  string.pad_start(int.to_string(value), to: 2, with: "0")
}

fn quoted(value: String) -> String {
  "\"" <> value <> "\""
}
