import gleam/option
import gleam/time/duration
import gleeunit
import gleeunit/should
import showup/alarm

pub fn main() -> Nil {
  gleeunit.main()
}

/// A capped alarm, so the loop can be exercised by a test that would
/// otherwise ring forever. The alarm the program actually installs is
/// `ringing()`, which sets no cap — see `never_gives_up_on_its_own_test`.
fn capped_after(give_up_after: Int) -> alarm.Options {
  alarm.Options(
    between: duration.seconds(10),
    give_up_after: option.Some(give_up_after),
    play_failures: 3,
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

fn quiet(give_up_after: Int, effects: alarm.Effects) -> alarm.Outcome {
  alarm.ring(capped_after(give_up_after), effects)
}

/// The alarm the program installs rings until someone touches something.
/// This is the statement that a ring which stops on its own has failed.
pub fn never_gives_up_on_its_own_test() {
  alarm.default_options().give_up_after |> should.equal(option.None)
}

pub fn stops_at_the_cap_when_nothing_else_happens_test() {
  // Nothing changes, and the only thing that ends the ringing is the cap.
  quiet(6, idle_for(5)) |> should.equal(alarm.Rung(rings: 6))
}

pub fn rings_once_when_asked_to_test() {
  quiet(1, idle_for(600)) |> should.equal(alarm.Rung(rings: 1))
}

pub fn reports_a_sound_it_could_not_play_test() {
  let silent =
    alarm.Effects(
      idle_seconds: fn() { 600 },
      play: fn(_) { Error("no such file") },
      sleep: fn(_) { Nil },
    )
  quiet(6, silent) |> should.equal(alarm.Silent(reason: "no such file"))
}

pub fn reports_a_sound_it_could_not_play_even_when_the_user_is_there_test() {
  // Even at idle 0 we still try to play, and if the sound is missing we say
  // so rather than silently doing nothing.
  let present =
    alarm.Effects(
      idle_seconds: fn() { 0 },
      play: fn(_) { Error("should not be played") },
      sleep: fn(_) { Nil },
    )
  quiet(6, present)
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

/// The alarm plays sound by shelling out to afplay, and a machine that has
/// just woken from deep sleep may refuse the first one or two while its
/// audio stack comes up. Giving up on the first refusal is how the alarm
/// ends up silent on the one wake that needed it.
/// A sound that never plays still ends the alarm, rather than ringing at
/// nobody until showup is stopped.
pub fn gives_up_on_a_sound_that_never_plays_test() {
  let silent =
    alarm.Effects(
      idle_seconds: fn() { 600 },
      play: fn(_) { Error("no such file") },
      sleep: fn(_) { Nil },
    )
  quiet(99, silent) |> should.equal(alarm.Silent(reason: "no such file"))
}

/// How many times the alarm tries before giving up is the production value,
/// not a test's, so that the wait is a real one.
/// A wake registers as HID activity, so the idle reading at the moment the
/// alarm starts is routinely zero. Under the old baseline comparison that
/// made `idle_now < 0` — never true — so nothing could ever stop the alarm,
/// not even a hand on the keyboard.
pub fn a_baseline_of_zero_no_longer_makes_the_alarm_unstoppable_test() {
  quiet(99, idle_for(0)) |> should.equal(alarm.Rung(rings: 2))
}

/// Input during the ringing stops it, whenever the alarm happened to start.
pub fn input_during_the_ringing_stops_it_test() {
  quiet(99, idle_for(1)) |> should.equal(alarm.Rung(rings: 2))
}

/// The device needs longer than fifteen seconds to come up on a real wake.
pub fn waits_out_an_audio_device_that_is_still_coming_up_test() {
  alarm.default_options().play_failures |> should.equal(40)
}
