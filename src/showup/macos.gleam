import child_process
import child_process/stdio
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/string
import gleam/time/duration.{type Duration}

/// Calls a local Erlang BIF directly without writing any `.erl`.
/// `calendar:local_time/0` returns `{{Year, Month, Day}, {Hour, Minute, Second}}`
/// which Gleam maps to `#(#(Int, Int, Int), #(Int, Int, Int))`.
@external(erlang, "calendar", "local_time")
fn local_time() -> #(#(Int, Int, Int), #(Int, Int, Int))

/// What happened when macOS was asked to surface an app.
pub type Outcome {
  /// The app was not running and has been launched.
  Launched
  /// The app was already running and has been brought to the front.
  Surfaced
  /// The app could not be surfaced, most likely because it is not installed.
  Failed(reason: String)
}

fn exec(executable: String, args: List(String)) -> Result(String, String) {
  case
    child_process.from_file(executable)
    |> child_process.args(args)
    |> child_process.run(stdio.capture(True))
  {
    Ok(child_process.Output(status_code: code, output: output)) ->
      case code {
        0 -> Ok(output)
        _ -> Error("exit code " <> int.to_string(code) <> ": " <> output)
      }
    Error(err) -> Error(child_process.describe_start_error(err))
  }
}

/// Brings `app` to the foreground, launching it when it is not running.
///
/// IMPORTANT: showup runs as root (for pmset), so `open -a` would launch
/// the app in root's session instead of the logged-in user's — the window
/// would never appear on their screen. We use `launchctl asuser <uid>` to
/// re-execute `open -a` in the correct GUI session.
pub fn show(app: String) -> Outcome {
  let was_running = is_running(app)
  case console_uid() {
    Ok(uid) ->
      case
        exec("/bin/launchctl", [
          "asuser",
          int.to_string(uid),
          "/usr/bin/open",
          "-a",
          app,
        ])
      {
        Error(reason) -> Failed(reason: reason)
        Ok(_) ->
          case was_running {
            True -> Surfaced
            False -> Launched
          }
      }
    Error(reason) -> Failed(reason: reason)
  }
}

/// Runs `echo "show State:/Users/ConsoleUser" | scutil`.
/// scutil reads commands from stdin, not from argv — passing them as args
/// causes it to hang waiting for stdin input forever.
fn scutil_query() -> Result(String, String) {
  exec("/bin/sh", [
    "-c",
    "echo 'show State:/Users/ConsoleUser' | /usr/sbin/scutil",
  ])
}

/// Extracts the ConsoleUser's UID from scutil. Returns the UID of the user
/// currently holding the GUI session, or an error if we cannot determine it.
///
/// We need this because showup runs as root and cannot directly open apps
/// in the user's GUI session — we must delegate to `launchctl asuser <uid>`.
pub fn console_uid() -> Result(Int, String) {
  case scutil_query() {
    Ok(output) -> parse_uid(output)
    Error(reason) -> Error(reason)
  }
}

/// Parses `UID : 501` from scutil output.
///
/// Matches whole lines rather than searching for the substring `UID : `,
/// because `CGSSessionUniqueSessionUUID : 3CC66676-...` ends with that same
/// substring and a plain split on it finds two matches, not one.
pub fn parse_uid(output: String) -> Result(Int, String) {
  let candidates =
    output
    |> string.split(on: "\n")
    |> list.filter(fn(line) { string.starts_with(string.trim(line), uid_key) })
  case candidates {
    [] -> Error("no UID line in scutil output")
    [line, ..] ->
      case string.split(string.trim(line), on: uid_key) {
        [_, value] ->
          case value |> string.trim |> int.parse {
            Ok(0) -> Error("no console user (UID is 0)")
            Ok(uid) -> Ok(uid)
            Error(_) -> Error("could not parse UID from scutil output")
          }
        _ -> Error("malformed scutil output")
      }
  }
}

const uid_key: String = "UID : "

/// Whether the app is running already, asked without launching it.
///
/// `lsappinfo info` prints the app's record when it is running and prints
/// nothing at all when it is not. Asking the app about itself with an
/// AppleScript instead needs Automation permission, which many terminals are
/// not granted, and a refused answer is indistinguishable from "not running",
/// which would report an activation as a launch.
fn is_running(app: String) -> Bool {
  case exec("/usr/bin/lsappinfo", ["info", app]) {
    Ok(record) -> !string.is_empty(string.trim(record))
    Error(_) -> False
  }
}

/// How long the keyboard and mouse have been untouched, in whole seconds.
///
/// A locked screen counts as idle, because a locked screen produces no input
/// either. Zero means either that the user is at the machine or that the
/// answer could not be read, and either way the caller stays quiet.
pub fn idle_seconds() -> Int {
  case exec("/usr/sbin/ioreg", ["-r", "-c", "IOHIDSystem", "-d1"]) {
    Ok(report) -> parse_idle_seconds(report)
    Error(_) -> 0
  }
}

/// Whether the user is currently at their desktop (not on the login
/// window). True when we can read a valid console UID AND scutil reports
/// LoginDoneKey = TRUE. Returns False while the login window is showing.
///
/// One scutil call answers both questions — the UID and the login flag are
/// in the same output — so this is a single query rather than two. That
/// matters because the login poll calls it once a second for up to two
/// minutes, and each query spawns a shell as well as scutil.
pub fn at_desktop() -> Bool {
  case scutil_query() {
    Ok(output) ->
      case parse_uid(output) {
        Ok(_) -> string.contains(output, login_done_key)
        Error(_) -> False
      }
    Error(_) -> True
  }
}

const login_done_key: String = "kCGSessionLoginDoneKey : TRUE"

/// Reads the idle time out of an `ioreg` report, which gives it in
/// nanoseconds as `"HIDIdleTime" = 12624548166`.
pub fn parse_idle_seconds(report: String) -> Int {
  case idle_nanoseconds(report) {
    Ok(nanoseconds) -> nanoseconds / 1_000_000_000
    Error(_) -> 0
  }
}

fn idle_nanoseconds(report: String) -> Result(Int, Nil) {
  case string.split(report, on: "\"HIDIdleTime\" = ") {
    [_, field] ->
      case string.split(field, on: "\n") {
        [value, ..] -> value |> string.trim |> int.parse
        [] -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// Plays a sound file to completion, such as one of the system sounds.
pub fn play(sound: String) -> Result(Nil, String) {
  case exec("/usr/bin/afplay", [sound]) {
    Ok(_) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}

/// Holds three assertions for `seconds` seconds:
///   - PreventUserIdleSystemSleep    (-i) keep CPU awake
///   - PreventDisplaySleep            (-d) keep display from going back to sleep
///   - UserIsActive                   (-u) WAKES THE DISPLAY if it's off
///
/// Spawns `caffeinate -i -d -u -t <seconds>` via `/bin/sh ... &` so the
/// exec call returns immediately — caffeinate runs in the background,
/// holds the assertions, and exits by itself after the timeout. No PID
/// tracking needed, no manual kill. Zero or more concurrent assertions
/// are fine; macOS counts them independently.
///
/// `&` alone is not enough. A backgrounded child keeps the stdout and
/// stderr it inherited, and `exec` reads those to end of stream, so the
/// caller would block until caffeinate exited — the full timeout. Sending
/// both to /dev/null closes the pipe immediately, which is what makes the
/// backgrounding actually return.
///
/// The `-u` flag is critical here. `pmset schedule wake` wakes the CPU
/// but leaves the display dark. `-d` only PREVENTS future sleep — it
/// cannot turn a display that is already sleeping back on. `-u` declares
/// user activity, which DOES turn the display on, speaker-enables the
/// ringback tone, and ensures `open -a` surfaces an app the user can
/// actually see. Without `-u`, the show + alarm run headless.
pub fn keep_awake(seconds: Int) -> Result(Nil, String) {
  let cmd =
    "/usr/bin/caffeinate -i -d -u -t "
    <> int.to_string(seconds)
    <> " >/dev/null 2>&1 &"
  case exec("/bin/sh", ["-c", cmd]) {
    Ok(_) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}

/// Asks the kernel to wake the Mac at a specific wall-clock datetime.
///
/// Calls `pmset schedule wake "MM/DD/YYYY HH:MM:SS"`. This is a one-shot
/// schedule — the kernel fires it once and then forgets about it. Only
/// root can call pmset schedule, so showup must be run with `sudo`.
pub fn schedule_wake(datetime: String) -> Result(Nil, String) {
  case exec("/usr/bin/pmset", ["schedule", "wake", datetime]) {
    Ok(_) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}

/// Builds the `MM/DD/YYYY HH:MM:SS` string pmset expects for a wake that is
/// `seconds_from_now` seconds away.
///
/// Computed from the current wall clock rather than from the hour and minute
/// of the wake itself, because the wake we ask for is no longer the time the
/// user asked for — it is that time less the lead window. Deriving it from
/// the target time of day also used to be wrong across midnight: a 00:30
/// wake found at 23:50 has forty minutes to run but lands on today's 00:30,
/// which is already behind us.
pub fn pmset_datetime(seconds_from_now: Int) -> String {
  let #(#(year, month, day), #(hour, minute, second)) = local_time()
  let seconds_today = hour * 3600 + minute * 60 + second
  let target = seconds_today + seconds_from_now
  let #(days_ahead, time_of_day) = case target >= 86_400 {
    True -> #(1, target - 86_400)
    False -> #(0, target)
  }
  let #(final_year, final_month, final_day) =
    advance_date(year, month, day, days_ahead)
  let #(final_hour, final_minute, final_second) = split_clock(time_of_day)
  string.join(
    [
      pad(final_month),
      "/",
      pad(final_day),
      "/",
      int.to_string(final_year),
      " ",
      pad(final_hour),
      ":",
      pad(final_minute),
      ":",
      pad(final_second),
    ],
    with: "",
  )
}

/// Seconds since midnight back into an hour, minute and second.
fn split_clock(seconds: Int) -> #(Int, Int, Int) {
  #(seconds / 3600, seconds / 60 % 60, seconds % 60)
}

/// Advances a Gregorian date by `days` days. For our use case `days` is
/// always 0 (today) or 1 (tomorrow — the target time already passed today).
fn advance_date(
  year: Int,
  month: Int,
  day: Int,
  days: Int,
) -> #(Int, Int, Int) {
  case days > 0 {
    True -> advance_one_day(year, month, day)
    False -> #(year, month, day)
  }
}

fn advance_one_day(year: Int, month: Int, day: Int) -> #(Int, Int, Int) {
  let max_day = days_in_month(year, month)
  case day + 1 > max_day {
    True ->
      case month + 1 > 12 {
        True -> #(year + 1, 1, 1)
        False -> #(year, month + 1, 1)
      }
    False -> #(year, month, day + 1)
  }
}

fn days_in_month(year: Int, month: Int) -> Int {
  case month {
    2 ->
      case is_leap_year(year) {
        True -> 29
        False -> 28
      }
    4 | 6 | 9 | 11 -> 30
    _ -> 31
  }
}

fn is_leap_year(year: Int) -> Bool {
  year % 4 == 0 && year % 100 != 0 || year % 400 == 0
}

fn pad(value: Int) -> String {
  string.pad_start(int.to_string(value), to: 2, with: "0")
}
