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
