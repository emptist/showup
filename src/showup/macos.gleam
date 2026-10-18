import child_process
import child_process/stdio
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
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

/// What the machine was doing while showup was waiting for the time to come.
///
/// The timer expiring does not say whether the Mac spent that time awake
/// or asleep, because the clock reads the same either way. Only the power
/// log can tell the two apart, so we ask it.
pub type Rest {
  /// The Mac was up and running for the whole wait. Someone is very likely
  /// sitting at it, so there is nobody to wake and nothing to wait for.
  Awake
  /// The Mac was asleep, and the wake that released us is the one we asked
  /// the kernel for. Someone has to be woken, and may still have to log in.
  Slept
  /// The log could not be read. Take the least intrusive reading and just
  /// surface the app, rather than making a noise we cannot justify.
  Unknown
}

/// Asks the power log what happened while we were waiting.
///
/// Costs about four seconds, so it is asked once per wake and never on the
/// path that has to be fast.
pub fn rest(now: Duration) -> Rest {
  case exec("/bin/sh", ["-c", rest_query]) {
    Ok(log) -> parse_rest(log, now)
    Error(_) -> Unknown
  }
}

/// `pmset -g log` prints several megabytes of history, so the shell narrows
/// it to the two lines that matter before we ever see it. `tail` bounds it
/// again. The alternative — shipping megabytes into the VM to find the last
/// line — is far more work for no extra information.
const rest_query: String =
  "/usr/bin/pmset -g log | /usr/bin/grep -E 'Entering Sleep state|Wake from' | /usr/bin/tail -20"

/// Reads `rest` out of filtered `pmset -g log` output.
///
/// The line we want is the last one, and it answers the question only if it
/// is the wake that just released us. A `Wake` line from this morning means
/// nothing when the timer expires tonight, so recency is part of the test
/// rather than an afterthought: `pmset` records how long each wake took, and
/// it is routinely a fraction of a second, so the wake that resumes us is
/// within a minute or so of the clock reading we were handed.
///
/// A `DarkWake` is the machine coming up for maintenance with the screen
/// still off. It is not a wake we asked for, and the user cannot see
/// anything during it, so it counts as `Awake` — software that rings at
/// nobody into a dark screen helps no one.
pub fn parse_rest(log: String, now: Duration) -> Rest {
  let entries =
    log
    |> string.split(on: "\n")
    |> list.filter_map(entry)
    |> list.filter(fn(one) { one.event == "Sleep" || one.event == "Wake" })
  case entries {
    [] -> Unknown
    _ -> classify(entries, now)
  }
}

type Entry {
  Entry(event: String, at: Int)
}

fn entry(line: String) -> Result(Entry, Nil) {
  case event_of(line) {
    Error(Nil) -> Error(Nil)
    Ok(event) ->
      case timestamp_of(line) {
        Error(Nil) -> Error(Nil)
        Ok(at) -> Ok(Entry(event: event, at: at))
      }
  }
}

/// Decides from the tail of the log.
///
/// Order is taken from the log's own line order, never from comparing
/// timestamps. `pmset -g log` prints oldest first, so position is already
/// the chronology, and comparing parsed times would break at midnight: the
/// wake before last is at 23:45 and the sleep after it is at 00:17, so the
/// numbers say the wake is later when the log says the opposite. That bug
/// read a real overnight wake as a machine that had never slept.
///
/// So: did the log go down to sleep after its last recorded wake? If the
/// last thing that happened was a Sleep, we did — and that also covers the
/// case where the log has not caught up with the wake yet, which is the
/// normal state a fraction of a second after the kernel resumes us.
///
/// DarkWake entries are filtered out before this, which is what makes it
/// robust: hours of Power Nap maintenance wakes sit between our Sleep and
/// the wake still being written, and they must not hide the sleep.
fn classify(entries: List(Entry), now: Duration) -> Rest {
  let #(went_down_after, last_wake) = fold(entries, #(False, option.None), step)
  case went_down_after {
    True -> Slept
    False ->
      case last_wake {
        option.None -> Unknown
        option.Some(at) -> recently(at, now)
      }
  }
}

/// Remembers whether the log's last down/up transition was down, and when the
/// last full wake was.
fn step(seen: #(Bool, Option(Int)), entry: Entry) -> #(Bool, Option(Int)) {
  case entry.event {
    "Sleep" -> #(True, seen.1)
    _ -> #(False, option.Some(entry.at))
  }
}

fn fold(
  entries: List(Entry),
  from initial: #(Bool, Option(Int)),
  with each: fn(#(Bool, Option(Int)), Entry) -> #(Bool, Option(Int)),
) -> #(Bool, Option(Int)) {
  list.fold(entries, initial, each)
}

fn recently(at: Int, now: Duration) -> Rest {
  // Measured round the clock rather than by subtraction, so a wake just
  // before midnight and a clock reading just after it are two seconds apart
  // rather than nearly a day.
  let difference = whole_seconds(now) - at
  let gap = case difference < 0 {
    True -> difference + 86_400
    False -> difference
  }
  case gap >= 0 && gap <= just_woke_seconds {
    True -> Slept
    False -> Awake
  }
}

/// The event name sits in a fixed column, after the date, the clock and the
/// timezone: `... +0800 Wake   \tWake from Deep Idle ...`.
fn event_of(line: String) -> Result(String, Nil) {
  line |> words |> list.drop(3) |> list.first
}

fn timestamp_of(line: String) -> Result(Int, Nil) {
  case words(line) {
    [_, clock, ..] ->
      case parse_clock(clock) {
        Ok(#(hour, minute, second)) -> Ok(hour * 3600 + minute * 60 + second)
        Error(_) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// Splits on whitespace of either kind. `pmset` pads its columns with runs
/// of spaces and then a tab, so both have to go and the gaps have to go
/// with them.
fn words(line: String) -> List(String) {
  line
  |> string.replace(each: "\t", with: " ")
  |> string.split(on: " ")
  |> list.filter(fn(part) { part != "" })
}

/// How long after the recorded wake the clock may read and still count as
/// the same wake. Generous next to the fractions of a second `pmset`
/// reports for a wake, tight enough that last night's wake can never look
/// like tonight's.
const just_woke_seconds: Int = 60

fn whole_seconds(period: Duration) -> Int {
  let #(seconds, _nanoseconds) = duration.to_seconds_and_nanoseconds(period)
  seconds
}

/// `21:18:00` as (hour, minute, second).
fn parse_clock(clock: String) -> Result(#(Int, Int, Int), Nil) {
  case string.split(clock, on: ":") {
    [hour, minute, second] ->
      result.all([int.parse(hour), int.parse(minute), int.parse(second)])
      |> result.map(fn(parts) {
        case parts {
          [h, m, s] -> #(h, m, s)
          _ -> #(0, 0, 0)
        }
      })
      |> result.map_error(fn(_) { Nil })
    _ -> Error(Nil)
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
