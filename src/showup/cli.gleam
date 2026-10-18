import gleam/list
import gleam/string
import gleam/time/calendar.{type TimeOfDay}
import showup/schedule

/// A validated request, ready to be scheduled or described.
pub type Config {
  Config(
    app: String,
    times: List(TimeOfDay),
    /// Ring when nobody is at the machine, so a sleeping user is woken.
    ring: Bool,
    dry_run: Bool,
  )
}

pub type Command {
  /// Wait for each time in turn, surfacing the app every time.
  Show(config: Config)
  /// Print the next few wake times and exit.
  ShowSchedule(config: Config)
  Help
}

pub type Error {
  MissingApp
  EmptyApp
  NoTimesGiven
  InvalidTime(schedule.Error)
  /// The list of times was written with spaces after the commas, so the shell
  /// handed over only the first of several arguments.
  TimesSplitBySpaces(value: String)
  /// A flag that needs a value was the last argument.
  MissingValue(flag: String)
  UnknownArgument(argument: String)
}

type Options {
  Options(app: String, times: List(TimeOfDay), ring: Bool, dry_run: Bool)
}

pub fn parse(argv: List(String)) -> Result(Command, Error) {
  go(argv, Options(app: "", times: [], ring: True, dry_run: False))
}

fn go(argv: List(String), options: Options) -> Result(Command, Error) {
  case argv {
    [] -> finish(options)
    [flag, ..rest] -> step(flag, rest, options)
  }
}

fn step(
  flag: String,
  rest: List(String),
  options: Options,
) -> Result(Command, Error) {
  case flag {
    "-h" | "--help" -> Ok(Help)
    "-n" | "--dry-run" -> go(rest, Options(..options, dry_run: True))
    "-q" | "--no-ring" -> go(rest, Options(..options, ring: False))
    _ -> value_step(flag, rest, options)
  }
}

/// Handles the flags that take a value, written as either `--flag value` or
/// `--flag=value`.
fn value_step(
  flag: String,
  rest: List(String),
  options: Options,
) -> Result(Command, Error) {
  case string.split_once(flag, "=") {
    Ok(#(name, value)) -> assign(name, value, flag, rest, options)
    Error(_) ->
      case rest {
        [value, ..remaining] -> assign(flag, value, flag, remaining, options)
        [] -> Error(MissingValue(flag: flag))
      }
  }
}

fn assign(
  name: String,
  value: String,
  flag: String,
  rest: List(String),
  options: Options,
) -> Result(Command, Error) {
  case name {
    "-a" | "--app" ->
      case app_name(value) {
        Ok(app) -> go(rest, Options(..options, app: app))
        Error(error) -> Error(error)
      }
    "-t" | "--times" ->
      case string.ends_with(value, ",") {
        True -> Error(TimesSplitBySpaces(value: value))
        False -> parse_times(value, rest, options)
      }
    _ -> Error(UnknownArgument(argument: flag))
  }
}

fn parse_times(
  value: String,
  rest: List(String),
  options: Options,
) -> Result(Command, Error) {
  case schedule.parse_list(value) {
    Ok(times) ->
      go(rest, Options(..options, times: list.append(options.times, times)))
    Error(error) -> Error(InvalidTime(error))
  }
}

fn finish(options: Options) -> Result(Command, Error) {
  case options {
    Options(app: "", times: _, ring: _, dry_run: _) -> Error(MissingApp)
    Options(app: _, times: [], ring: _, dry_run: _) -> Error(NoTimesGiven)
    Options(app: app, times: times, ring: ring, dry_run: dry_run) -> {
      let config =
        Config(
          app: app,
          times: schedule.normalise(times),
          ring: ring,
          dry_run: dry_run,
        )
      case dry_run {
        True -> Ok(ShowSchedule(config: config))
        False -> Ok(Show(config: config))
      }
    }
  }
}

fn app_name(value: String) -> Result(String, Error) {
  let app = string.trim(value)
  case string.is_empty(app) {
    True -> Error(EmptyApp)
    False -> Ok(app)
  }
}

pub fn usage() -> String {
  [
    "showup - bring a macOS app to the foreground at times you choose",
    "",
    "Usage:",
    "  showup -a <app> -t <times> [-n] [-q]",
    "",
    "Arguments:",
    "  -a, --app <name>      The application to surface, for example \"Safari\".",
    "  -t, --times <times>   Comma separated times of day, for example",
    "                        8:00,12:00,16:00,20:00,24:00. A bare hour such",
    "                        as 8 means 8:00.",
    "  -n, --dry-run         Print the next few wake times and exit.",
    "  -q, --no-ring         Never make a sound. By default showup rings",
    "                       like an incoming FaceTime call, repeating every",
    "                       five seconds, whenever it had to wake the Mac from",
    "                       sleep and nothing answered it. Use this if you",
    "                       would rather it only ever brought the window",
    "                       forward silently.",
    "  -h, --help            Show this message.",
    "",
    "Both --flag value and --flag=value forms are accepted. A time that has",
    "already passed today waits for tomorrow.",
    "",
    "Examples:",
    "  showup -a Safari -t 8:00,12:00,16:00,20:00",
    "  showup -a Safari -t \"8:00, 12:00\"    # spaces need quoting",
    "  showup --app=\"Slack\" --times=\"9,17\"",
    "  showup -a Mail -t 24:00 --dry-run",
    "",
  ]
  |> string.join(with: "\n")
}

pub fn error_message(error: Error) -> String {
  case error {
    MissingApp -> "no app given, pass one with -a/--app"
    EmptyApp -> "the app name given with -a/--app is empty"
    NoTimesGiven -> "no times given, pass some with -t/--times"
    InvalidTime(error) -> "invalid time: " <> schedule.error_message(error)
    TimesSplitBySpaces(value: value) ->
      "the times "
      <> quoted(value)
      <> " end in a comma, so the shell split the list on the spaces after each "
      <> "one. Write them as a single argument, such as "
      <> quoted("8:00,12:00,16:00")
    MissingValue(flag: flag) -> quoted(flag) <> " needs a value"
    UnknownArgument(argument: argument) ->
      "unexpected argument " <> quoted(argument)
  }
}

fn quoted(value: String) -> String {
  "\"" <> value <> "\""
}
