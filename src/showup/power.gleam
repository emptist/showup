import gleam/int
import gleam/string
import gleam/time/calendar.{type Month, Date, TimeOfDay}
import gleam/time/timestamp.{type Timestamp}

/// What macOS was asked to do, and whether it listened.
pub type Armed {
  /// The machine will wake itself at that time.
  Yes
  /// The machine will keep sleeping through it, because the request was
  /// refused. The usual reason is that `pmset schedule wake` needs to run as
  /// root.
  No(reason: String)
}

@external(erlang, "showup_erl", "run")
fn exec(executable: String, arguments: List(String)) -> Result(String, String)

/// Asks macOS to wake the machine at the given moment, so that a time which
/// comes round while the machine is asleep still happens.
///
/// This is armed with `sudo -n`, which never prompts, so an unattended run
/// reports that it could not do it rather than hanging on a password.
///
/// Only ever one wake is armed at a time, and this replaces the previous
/// request rather than adding to it. It must never cancel the schedule, as
/// that would also clear the wake times the Clock app has armed.
pub fn arm_wake(at: Timestamp) -> Armed {
  case
    exec("/usr/bin/sudo", [
      "-n",
      "/usr/bin/pmset",
      "schedule",
      "wake",
      wake_argument(at),
    ])
  {
    Ok(_) -> Yes
    Error(reason) -> No(reason: string.trim(reason))
  }
}

/// The moment `pmset schedule wake` wants, as `MM/DD/YY HH:MM:SS` in the local
/// time zone.
pub fn wake_argument(at: Timestamp) -> String {
  let #(
    Date(year: year, month: month, day: day),
    TimeOfDay(
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      nanoseconds: _nanoseconds,
    ),
  ) = timestamp.to_calendar(at, calendar.local_offset())
  pad(month_to_int(month))
  <> "/"
  <> pad(day)
  <> "/"
  <> pad(year % 100)
  <> " "
  <> pad(hours)
  <> ":"
  <> pad(minutes)
  <> ":"
  <> pad(seconds)
}

/// Why a wake could not be armed, said in terms of what to do about it.
pub fn advice(reason: String) -> String {
  case
    string.contains(reason, "must be run as root")
    || string.contains(reason, "not permitted")
    || string.contains(reason, "password is required")
  {
    True ->
      "pmset needs to run as root to arm a wake, so times that come while the "
      <> "Mac is asleep are being skipped. To allow it, add "
      <> quoted("<you> ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake")
      <> " to a file under /etc/sudoers.d, where <you> is the output of whoami."
    False -> reason
  }
}

fn pad(value: Int) -> String {
  string.pad_start(int.to_string(value), to: 2, with: "0")
}

fn quoted(value: String) -> String {
  "\"" <> value <> "\""
}

fn month_to_int(month: Month) -> Int {
  calendar.month_to_int(month)
}
