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
