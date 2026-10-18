import child_process
import child_process/stdio
import gleam/int
import gleam/io
import gleam/string

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
  case
    exec("/bin/sh", [
      "-c",
      "echo 'show State:/Users/ConsoleUser' | /usr/sbin/scutil",
    ])
  {
    Ok(output) -> {
      io.println(
        "[debug] scutil output ("
        <> int.to_string(string.length(output))
        <> " chars)",
      )
      Ok(output)
    }
    Error(reason) -> {
      io.println_error("[debug] scutil failed: " <> reason)
      Error(reason)
    }
  }
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
fn parse_uid(output: String) -> Result(Int, String) {
  case string.contains(output, "UID : 0") {
    True -> Error("no console user (UID is 0)")
    False ->
      case string.split(output, on: "UID : ") {
        [_, rest] ->
          case string.split(rest, on: "\n") {
            [value, ..] ->
              case string.trim(value) |> int.parse {
                Ok(uid) -> Ok(uid)
                Error(_) -> Error("could not parse UID from scutil output")
              }
            _ -> Error("malformed scutil output")
          }
        _ -> Error("UID line not found in scutil output")
      }
  }
}

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
pub fn at_desktop() -> Bool {
  case console_uid() {
    Ok(_) ->
      case scutil_query() {
        Ok(output) -> string.contains(output, "kCGSessionLoginDoneKey : TRUE")
        Error(_) -> True
      }
    Error(_) -> False
  }
}

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
/// The `-u` flag is critical here. `pmset schedule wake` wakes the CPU
/// but leaves the display dark. `-d` only PREVENTS future sleep — it
/// cannot turn a display that is already sleeping back on. `-u` declares
/// user activity, which DOES turn the display on, speaker-enables the
/// ringback tone, and ensures `open -a` surfaces an app the user can
/// actually see. Without `-u`, the show + alarm run headless.
pub fn keep_awake(seconds: Int) -> Result(Nil, String) {
  let cmd = "/usr/bin/caffeinate -i -d -u -t " <> int.to_string(seconds) <> " &"
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

/// Removes any previously scheduled one-shot wake events we set.
///
/// Before setting a new wake, we cancel all old ones so a stale schedule
/// does not accidentally wake the Mac at the wrong time. Uses `pmset schedule
/// cancelall wake`, which removes ALL pending one-shot wake events including
/// those set by other processes. `cancelall` is required because `cancel`
/// alone needs the exact datetime of the event to cancel.
pub fn cancel_wake() -> Result(Nil, String) {
  case exec("/usr/bin/pmset", ["schedule", "cancelall", "wake"]) {
    Ok(_) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}

/// Builds the `MM/DD/YYYY HH:MM:SS` string pmset expects for a wake that is
/// `delay_seconds` from now, targeting a specific hour and minute on that day.
///
/// Reads today's date via Erlang's `calendar:local_time/0`, then advances by
/// 1 day if the target time has already passed today.
pub fn pmset_datetime(hour: Int, minute: Int, delay_seconds: Int) -> String {
  let #(#(year, month, day), _) = local_time()
  let target_hour = hour
  let target_minute = minute
  let target_second = 0
  let total_day_seconds = 86_400
  let days_ahead = delay_seconds / total_day_seconds
  let #(final_year, final_month, final_day) =
    advance_date(year, month, day, days_ahead)
  string.join(
    [
      pad(final_month),
      "/",
      pad(final_day),
      "/",
      int.to_string(final_year),
      " ",
      pad(target_hour),
      ":",
      pad(target_minute),
      ":",
      pad(target_second),
    ],
    with: "",
  )
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
