import gleam/time/duration
import gleeunit
import gleeunit/should
import showup/alarm

pub fn main() -> Nil {
  gleeunit.main()
}

fn options(give_up_after: Int) -> alarm.Options {
  alarm.Options(
    idle_after: duration.minutes(2),
    between: duration.seconds(10),
    give_up_after: give_up_after,
  )
}

/// A machine whose keyboard and mouse have been untouched for `idle_seconds`.
fn idle_for(idle_seconds: Int) -> alarm.Effects {
  alarm.Effects(
    idle_seconds: fn() { idle_seconds },
    play: fn(_) { Ok(Nil) },
    sleep: fn(_) { Nil },
  )
}

pub fn stays_quiet_when_the_user_is_at_the_machine_test() {
  alarm.ring(options(6), idle_for(5)) |> should.equal(alarm.Awake)
}

pub fn stays_quiet_just_under_the_threshold_test() {
  alarm.ring(options(6), idle_for(119)) |> should.equal(alarm.Awake)
}

pub fn rings_when_the_threshold_is_reached_test() {
  alarm.ring(options(1), idle_for(120)) |> should.equal(alarm.Rung(rings: 1))
}

pub fn gives_up_after_the_configured_number_of_rings_test() {
  alarm.ring(options(6), idle_for(600)) |> should.equal(alarm.Rung(rings: 6))
}

pub fn rings_only_once_when_asked_to_test() {
  alarm.ring(options(1), idle_for(600)) |> should.equal(alarm.Rung(rings: 1))
}

pub fn reports_a_sound_it_could_not_play_test() {
  let silent =
    alarm.Effects(
      idle_seconds: fn() { 600 },
      play: fn(_) { Error("no such file") },
      sleep: fn(_) { Nil },
    )
  alarm.ring(options(6), silent)
  |> should.equal(alarm.Silent(reason: "no such file"))
}

pub fn does_not_play_anything_when_the_user_is_there_test() {
  // A play that would fail proves the point: if it is never reached, the alarm
  // was quiet because the user was awake rather than because it worked.
  let watched =
    alarm.Effects(
      idle_seconds: fn() { 0 },
      play: fn(_) { Error("should not be played") },
      sleep: fn(_) { Nil },
    )
  alarm.ring(options(6), watched) |> should.equal(alarm.Awake)
}

pub fn rings_the_sound_an_incoming_facetime_call_makes_test() {
  // A full path rather than a friendly name, because showup plays whatever it
  // is given.
  alarm.ringback_tone
  |> should.equal(
    "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/facetime/multiway_invitation.caf",
  )
}

pub fn stays_quiet_when_ringing_was_switched_off_test() {
  // The silent alarm is what --no-ring installs, and it must never make a
  // sound whatever the machine looks like.
  alarm.silent()() |> should.equal(alarm.Awake)
}
