import gleam/int
import gleam/string

/// What happened when macOS was asked to surface an app.
pub type Outcome {
  /// The app was not running and has been launched.
  Launched
  /// The app was already running and has been brought to the front.
  Surfaced
  /// The app could not be surfaced, most likely because it is not installed.
  Failed(reason: String)
}

@external(erlang, "showup_erl", "run")
fn exec(executable: String, arguments: List(String)) -> Result(String, String)

/// Brings `app` to the foreground, launching it when it is not running.
///
/// `open -a` is all that is needed here. macOS activates a running app
/// through LaunchServices, which brings its windows to the front and gives it
/// focus, and asking System Events to raise the window on top of that only
/// added a permission that has to be granted before it works at all.
pub fn show(app: String) -> Outcome {
  let was_running = is_running(app)
  case exec("/usr/bin/open", ["-a", app]) {
    Error(reason) -> Failed(reason: reason)
    Ok(_) ->
      case was_running {
        True -> Surfaced
        False -> Launched
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
  case exec("/usr/bin/ioreg", ["-r", "-c", "IOHIDSystem", "-d1"]) {
    Ok(report) -> parse_idle_seconds(report)
    Error(_) -> 0
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
