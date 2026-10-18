import gleam/time/duration
import gleeunit
import gleeunit/should
import showup/macos

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn reads_the_idle_time_from_an_ioreg_report_test() {
  macos.parse_idle_seconds(
    "      \"HIDIdleTime\" = 12624548166\n      \"Product\" = 1\n",
  )
  |> should.equal(12)
}

pub fn reads_a_misspelled_key_as_no_idle_time_test() {
  macos.parse_idle_seconds("      \"HIDIdleTypo\" = 12624548166\n")
  |> should.equal(0)
}

pub fn reads_an_empty_report_as_no_idle_time_test() {
  macos.parse_idle_seconds("") |> should.equal(0)
}

pub fn reads_an_unparsable_idle_time_as_no_idle_time_test() {
  macos.parse_idle_seconds("      \"HIDIdleTime\" = soon\n")
  |> should.equal(0)
}

/// Real `show State:/Users/ConsoleUser` output. The session UUID line ends in
/// `UID : ` too, so a plain split on that substring used to find two matches
/// and reject the whole output as malformed.
const scutil_output: String =
  "<dictionary> {\n"
  <> "  GID : 20\n"
  <> "  Name : jk\n"
  <> "  SessionInfo : <array> {\n"
  <> "    0 : <dictionary> {\n"
  <> "      CGSSessionUniqueSessionUUID : 3CC66676-A9B2-4F50-B909-EA4F54CD9AE7\n"
  <> "      kCGSSessionUserIDKey : 501\n"
  <> "      kCGSSessionUserNameKey : jk\n"
  <> "      kCGSessionLoginDoneKey : TRUE\n"
  <> "    }\n"
  <> "  }\n"
  <> "  UID : 501\n"
  <> "}\n"

pub fn reads_the_console_uid_from_scutil_output_test() {
  macos.parse_uid(scutil_output) |> should.equal(Ok(501))
}

pub fn reads_uid_zero_as_no_console_user_test() {
  macos.parse_uid("  UID : 0\n}\n")
  |> should.equal(Error("no console user (UID is 0)"))
}

pub fn reads_output_without_a_uid_as_malformed_test() {
  macos.parse_uid("<dictionary> {\n  GID : 20\n}\n")
  |> should.equal(Error("no UID line in scutil output"))
}

/// Tonight's real Sleep line, verbatim. Written when the machine goes down,
/// so unlike a Wake line it is never missing when we go looking for it.
const real_sleep_line: String =
  "2026-10-19 00:53:02 +0800 Sleep               \tEntering Sleep state due to 'Software Sleep pid=660':TCPKeepAlive=active Using AC (Charge:79%) 359 secs  "

pub fn a_sleep_inside_the_wait_is_found_test() {
  // We began waiting at 00:52:50 and the machine went down twelve seconds
  // later. That is inside the window, so we slept.
  macos.slept_in(real_sleep_line, duration.seconds(52 * 60 + 50), 370)
  |> should.equal(True)
}

pub fn a_sleep_before_the_wait_began_is_not_ours_test() {
  // Same line, but we started waiting at 01:04:26 — after that sleep. This
  // is the case that rang at a user who never left the chair.
  macos.slept_in(real_sleep_line, duration.seconds(64 * 60 + 26), 94)
  |> should.equal(False)
}

pub fn a_sleep_just_after_the_wait_ended_is_not_ours_test() {
  // The sleep falls one second outside a window that closes just before it.
  macos.slept_in(real_sleep_line, duration.seconds(52 * 60 + 0), 11)
  |> should.equal(False)
}

pub fn a_log_with_no_sleep_at_all_is_not_ours_test() {
  macos.slept_in("", duration.seconds(0), 3600) |> should.equal(False)
}

pub fn a_wait_across_midnight_still_finds_its_sleep_test() {
  // Waiting from 23:55 into the small hours, with the machine going down at
  // 00:02. Subtracting those two clock readings would call it nearly a day.
  let line =
    "2026-10-19 00:02:10 +0800 Sleep               \tEntering Sleep state due to 'Software Sleep pid=660'"
  macos.slept_in(line, duration.seconds(23 * 3600 + 55 * 60), 900)
  |> should.equal(True)
}
