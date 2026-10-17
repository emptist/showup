import gleam/result
import gleam/string

/// What happened when macOS was asked to surface an app.
pub type Outcome {
  /// The app was not running and has been launched.
  Launched
  /// The app was already running and has been brought to the front.
  Surfaced
  /// The app came to the front but its window could not be raised. This
  /// normally means the program running `showup` has not been granted
  /// Accessibility permission in System Settings > Privacy & Security.
  CouldNotRaise(reason: String)
  /// The app could not be surfaced at all, most likely because it is not
  /// installed.
  Failed(reason: String)
}

@external(erlang, "showup_erl", "run")
fn exec(executable: String, arguments: List(String)) -> Result(String, String)

/// Brings `app` to the foreground, launching it when it is not running.
pub fn show(app: String) -> Outcome {
  let was_running = is_running(app)
  case exec("/usr/bin/open", ["-a", app]) {
    Error(reason) -> Failed(reason: reason)
    Ok(_) ->
      case raise(app) {
        Ok(_) ->
          case was_running {
            True -> Surfaced
            False -> Launched
          }
        Error(reason) -> CouldNotRaise(reason: reason)
      }
  }
}

/// Whether the app is running already, asked without launching it.
///
/// `lsappinfo` is used rather than an AppleScript query because asking an app
/// about itself needs Automation permission, which many terminals are not
/// granted. A refused query is indistinguishable from the app not running, and
/// would report an activation as a launch.
///
/// `lsappinfo info` prints the app's record when it is running and prints
/// nothing at all when it is not.
fn is_running(app: String) -> Bool {
  case exec("/usr/bin/lsappinfo", ["info", app]) {
    Ok(record) -> !string.is_empty(string.trim(record))
    Error(_) -> False
  }
}

/// Asks System Events to make the app the frontmost process.
fn raise(app: String) -> Result(Nil, String) {
  let script =
    "tell application \"System Events\" to set frontmost of application process \""
    <> app
    <> "\" to true"
  exec("/usr/bin/osascript", ["-e", script]) |> result.map(fn(_) { Nil })
}
