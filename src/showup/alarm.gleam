import gleam/erlang/process
import gleam/time/duration.{type Duration}
import showup/macos

/// The sound macOS plays when a FaceTime call arrives. It is only 2.2 seconds,
/// so it is heard four times as often for the same alarm length as a phone
/// ringback tone would be.
pub const ringback_tone: String =
  "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/facetime/multiway_invitation.caf"

/// How hard `showup` tries to wake someone up.
pub type Options {
  Options(
    /// Ring only if the keyboard and mouse have been untouched for at least
    /// this long.
    idle_after: Duration,
    /// How long to wait after each ring before starting the next one.
    between: Duration,
    /// How many rings to play before giving up on this wake.
    give_up_after: Int,
  )
}

/// What the alarm did.
pub type Outcome {
  /// Someone was at the machine, so the window coming forward was enough.
  Awake
  /// The ringback tone was played until someone touched the keyboard or mouse,
  /// or until the rings ran out.
  Rung(rings: Int)
  /// The sound could not be played, most likely because it is missing.
  Silent(reason: String)
}

/// Everything the alarm needs from the outside world, so the loop can be driven
/// by a fake machine in the tests.
pub type Effects {
  Effects(
    idle_seconds: fn() -> Int,
    play: fn(String) -> Result(Nil, String),
    sleep: fn(Duration) -> Nil,
  )
}

/// The alarm as this machine experiences it.
pub fn live() -> Effects {
  Effects(idle_seconds: macos.idle_seconds, play: macos.play, sleep: sleep)
}

pub fn default_options() -> Options {
  Options(
    idle_after: duration.minutes(2),
    between: duration.seconds(5),
    give_up_after: 6,
  )
}

/// Rings until the keyboard or mouse is touched, or until patience runs out.
///
/// Returns what happened so the caller can say so, rather than logging from
/// here.
pub fn ring(options: Options, effects: Effects) -> Outcome {
  case effects.idle_seconds() >= whole_seconds(options.idle_after) {
    False -> Awake
    True -> keep_ringing(options, effects, 1)
  }
}

fn keep_ringing(options: Options, effects: Effects, rings: Int) -> Outcome {
  // A sound that will not play is worth saying so rather than repeating a
  // failure six times.
  case effects.play(ringback_tone) {
    Error(reason) -> Silent(reason: reason)
    Ok(Nil) -> {
      effects.sleep(options.between)
      let answered = effects.idle_seconds() < 1
      let out_of_patience = rings >= options.give_up_after
      case answered || out_of_patience {
        True -> Rung(rings: rings)
        False -> keep_ringing(options, effects, rings + 1)
      }
    }
  }
}

fn sleep(delay: Duration) -> Nil {
  process.sleep(duration.to_milliseconds(delay))
}

fn whole_seconds(period: Duration) -> Int {
  let #(seconds, _nanoseconds) = duration.to_seconds_and_nanoseconds(period)
  seconds
}
