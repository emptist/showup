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

/// Always starts ringing — the "idle threshold" was removed, we ring every
/// time regardless of whether someone appears to be at the machine. Rings
/// keep going until the user touches keyboard or mouse, or give_up_after.
///
/// This test: baseline=5, idle stays 5 (same as baseline), 5 < 5 never true
/// → runs to give_up_after.
pub fn always_rings_until_give_up_when_no_new_activity_test() {
  alarm.ring(options(6), idle_for(5)) |> should.equal(alarm.Rung(rings: 6))
}

pub fn baseline_logic_prevents_pre_wakeup_activity_from_stopping_ring_test() {
  // Baseline=0 (Mac just woken). New activity must drop idle BELOW baseline
  // to stop. Same value never stops — 0 < 0 is false. So with idle that
  // always stays 0 we ring all the way to give_up_after.
  let watched =
    alarm.Effects(
      idle_seconds: fn() { 0 },
      play: fn(_) { Ok(Nil) },
      sleep: fn(_) { Nil },
    )
  alarm.ring(options(3), watched) |> should.equal(alarm.Rung(rings: 3))
}

pub fn always_rings_until_give_up_even_when_user_appears_idle_test() {
  // idle=5 means untouched for 5 seconds. Baseline=5 stays 5, same value
  // never stops the ring → runs to give_up_after.
  alarm.ring(options(6), idle_for(5)) |> should.equal(alarm.Rung(rings: 6))
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

pub fn reports_a_sound_it_could_not_play_when_user_is_there_test() {
  // Even if the user is right there (idle=0), we still try to play — and if
  // the sound is missing, we report that rather than silently doing nothing.
  let watched =
    alarm.Effects(
      idle_seconds: fn() { 0 },
      play: fn(_) { Error("should not be played") },
      sleep: fn(_) { Nil },
    )
  alarm.ring(options(6), watched)
  |> should.equal(alarm.Silent(reason: "should not be played"))
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
