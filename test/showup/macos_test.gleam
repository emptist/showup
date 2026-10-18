import gleam/time/duration.{type Duration}
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

/// Verbatim `pmset -g log` lines, filtered the way `rest` filters them.
/// The column padding and the tab are exactly as pmset prints them.
const sleep_line: String =
  "2026-10-18 21:16:19 +0800 Sleep               \tEntering Sleep state due to 'Software Sleep pid=660':TCPKeepAlive=active Using Batt (Charge:72%) 101 secs  "

const wake_line: String =
  "2026-10-18 21:18:00 +0800 Wake                \tWake from Deep Idle [CDNVA] : due to NUB.SPMI0Sw3IRQ nub-spmi.0x02 rtc/UserActivity Assertion Using BATT (Charge:72%)           "

const dark_wake_line: String =
  "2026-10-18 19:18:10 +0800 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty/ Using BATT (Charge:91%) 6 secs    "

fn at_second_of_day(seconds: Int) -> Duration {
  duration.seconds(seconds)
}

pub fn a_wake_that_just_released_us_means_we_slept_test() {
  macos.parse_rest(wake_line <> "\n", at_second_of_day(21 * 3600 + 18 * 60 + 5))
  |> should.equal(macos.Slept)
}

pub fn a_wake_from_earlier_today_means_the_mac_stayed_up_test() {
  // The machine woke at 06:00 and has been up since. The timer expiring at
  // 09:00 says nothing about sleep, and the log must not pretend otherwise.
  macos.parse_rest(wake_line <> "\n", at_second_of_day(9 * 3600))
  |> should.equal(macos.Awake)
}

pub fn a_dark_wake_alone_says_nothing_about_whether_we_slept_test() {
  // A maintenance wake on its own carries no sleep information either way,
  // and a log holding nothing else is not enough to act on.
  macos.parse_rest(
    dark_wake_line <> "\n",
    at_second_of_day(19 * 3600 + 18 * 60 + 12),
  )
  |> should.equal(macos.Unknown)
}

/// Maintenance wakes do not count as our wake. Hours of Power Nap wakeups
/// sitting between our Sleep and the wake that has not been written yet are
/// exactly the case this has to get right, and they must not hide it.
pub fn dark_wakes_between_our_sleep_and_our_wake_do_not_hide_it_test() {
  let log =
    real_sleep_line <> "\n" <> dark_wake_line <> "\n" <> dark_wake_line <> "\n"
  macos.parse_rest(log, at_second_of_day(23 * 3600 + 45 * 60 + 1))
  |> should.equal(macos.Slept)
}

pub fn a_dark_wake_after_a_real_wake_means_the_machine_is_up_test() {
  // Woke for real six hours ago and has only done maintenance since. Nobody
  // needs ringing, and the app is all this wake wanted.
  let log =
    real_sleep_line <> "\n" <> real_wake_line <> "\n" <> dark_wake_line <> "\n"
  macos.parse_rest(log, at_second_of_day(9 * 3600))
  |> should.equal(macos.Awake)
}

pub fn a_wake_then_a_sleep_means_the_mac_is_down_again_test() {
  macos.parse_rest(
    wake_line <> "\n" <> sleep_line <> "\n",
    at_second_of_day(22 * 3600),
  )
  |> should.equal(macos.Awake)
}

pub fn an_empty_log_means_we_know_nothing_test() {
  macos.parse_rest("", at_second_of_day(9 * 3600))
  |> should.equal(macos.Unknown)
}

pub fn a_log_of_unrelated_lines_means_we_know_nothing_test() {
  macos.parse_rest(
    "2026-10-18 21:18:00 +0800 WakeTime\tWakeTime: 0.173 sec\n",
    at_second_of_day(9 * 3600),
  )
  |> should.equal(macos.Unknown)
}

pub fn a_real_log_ending_in_a_fresh_wake_reads_as_slept_test() {
  let log = sleep_line <> "\n" <> wake_line <> "\n"
  macos.parse_rest(log, at_second_of_day(21 * 3600 + 18 * 60 + 2))
  |> should.equal(macos.Slept)
}

const late_wake_line: String =
  "2026-10-18 23:59:50 +0800 Wake                \tWake from Deep Idle [CDNVA] : due to NUB.SPMI0Sw3IRQ rtc "

pub fn a_wake_across_midnight_counts_as_seconds_ago_test() {
  // Woken at 23:59:50, clock reads 00:00:10. Subtracting those two clock
  // readings would call it nearly a day, and the wake would look stale.
  macos.parse_rest(late_wake_line <> "\n", at_second_of_day(10))
  |> should.equal(macos.Slept)
}

/// Tonight's real sleep and RTC wake, verbatim. The Mac went down at 23:39:08
/// and the kernel's alarm brought it back at 23:45:01, on the second.
const real_sleep_line: String =
  "2026-10-18 23:39:08 +0800 Sleep               \tEntering Sleep state due to 'Software Sleep pid=660':TCPKeepAlive=active Using Batt (Charge:47%) 353 secs  "

const real_wake_line: String =
  "2026-10-18 23:45:01 +0800 Wake                \tWake from Deep Idle [CDNVA] : due to NUB.SPMI0Sw3IRQ nub-spmi.0x02 rtc/HID Activity Using BATT (Charge:47%)           "

fn at(hours: Int, minutes: Int, seconds: Int) -> Duration {
  duration.seconds(hours * 3600 + minutes * 60 + seconds)
}

/// The case that actually happened: a real sleep and a real RTC wake read as
/// having slept.
pub fn a_real_sleep_and_rtc_wake_reads_as_slept_test() {
  let log = real_sleep_line <> "\n" <> real_wake_line <> "\n"
  macos.parse_rest(log, at(23, 45, 3)) |> should.equal(macos.Slept)
}

/// showup asks the log the instant the VM resumes, which is before powerd has
/// written the Wake line — so on a real wake the log still ends at the Sleep.
/// Reading that as "the machine never went down" is the one wrong answer that
/// matters, because it is the only moment anyone asks.
pub fn a_log_that_has_not_caught_up_with_the_wake_still_reads_as_slept_test() {
  macos.parse_rest(real_sleep_line <> "\n", at(23, 45, 1))
  |> should.equal(macos.Slept)
}

pub fn a_sleep_with_no_wake_at_all_still_reads_as_slept_test() {
  macos.parse_rest(sleep_line <> "\n" <> real_sleep_line <> "\n", at(23, 45, 1))
  |> should.equal(macos.Slept)
}

/// A machine that went down six hours ago and has been up since has a Sleep
/// followed by a Wake, and is not something we slept through.
pub fn a_sleep_answered_by_an_older_wake_is_not_a_missed_nap_test() {
  let log = real_sleep_line <> "\n" <> real_wake_line <> "\n"
  macos.parse_rest(log, at(9, 0, 0)) |> should.equal(macos.Awake)
}
