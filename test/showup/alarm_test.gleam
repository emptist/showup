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

pub fn baseline_is_read_before_the_first_ring_test() {
  // Baseline is 5 and idle stays 5. A ring can only stop when idle drops
  // BELOW the baseline, so an unchanged reading never stops it — which is
  // what stops the wake itself, or a sudo password typed earlier, from
  // being mistaken for the user answering.
  quiet(6, idle_for(5)) |> should.equal(alarm.Rung(rings: 6))
}

pub fn a_baseline_of_zero_is_never_beaten_by_a_still_zero_test() {
  // 0 < 0 is false, so a Mac that has just woken — where the idle reading
  // starts at zero — rings all the way to the cap.
  let just_woken =
    alarm.Effects(
      idle_seconds: fn() { 0 },
      play: fn(_) { Ok(Nil) },
      sleep: fn(_) { Nil },
    )
  quiet(3, just_woken) |> should.equal(alarm.Rung(rings: 3))
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
