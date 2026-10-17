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
