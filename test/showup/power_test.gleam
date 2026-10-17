import gleam/time/timestamp
import gleeunit
import gleeunit/should
import showup/power

pub fn main() -> Nil {
  gleeunit.main()
}

/// 2026-10-18 07:05:09 local time, which is what an armed wake for tomorrow
/// morning has to look like.
fn tomorrow_morning() -> timestamp.Timestamp {
  timestamp.from_unix_seconds(1_792_278_309)
}

pub fn writes_the_time_the_way_pmset_wants_it_test() {
  power.wake_argument(tomorrow_morning())
  |> should.equal("10/18/26 07:05:09")
}

pub fn pads_every_part_to_two_digits_test() {
  power.wake_argument(timestamp.from_unix_seconds(1_262_365_260))
  |> should.equal("01/02/10 01:01:00")
}

pub fn explains_a_missing_permission_test() {
  power.advice("pmset: This operation must be run as root")
  |> should.equal(
    "pmset needs to run as root to arm a wake, so times that come while the "
    <> "Mac is asleep are being skipped. To allow it, add "
    <> "\"your-user ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake\""
    <> " to a file under /etc/sudoers.d.",
  )
}

pub fn explains_a_missing_password_test() {
  power.advice("sudo: a password is required")
  |> should.equal(
    "pmset needs to run as root to arm a wake, so times that come while the "
    <> "Mac is asleep are being skipped. To allow it, add "
    <> "\"your-user ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake\""
    <> " to a file under /etc/sudoers.d.",
  )
}

pub fn explains_anything_else_it_is_told_test() {
  power.advice("pmset: Badly formatted date")
  |> should.equal("pmset: Badly formatted date")
}
