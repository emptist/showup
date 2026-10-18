import gleam/erlang/process
import gleam/option
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
    /// How long to wait after each ring before starting the next one.
    between: Duration,
    /// A cap on the number of rings, or `option.None` to ring until a hand reaches
    /// the keyboard. Production uses `option.None`; the cap exists so the loop can
    /// be exercised by tests without one of them ringing forever.
    give_up_after: option.Option(Int),
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

/// Rings until the keyboard or mouse is touched.
///
/// option.None gives up on its own. The whole point is to reach someone who is
/// asleep, and a person who has not moved for the first six rings has not
/// been reached yet — a ring that stops is a ring that failed. It runs in
/// its own process, so nothing else waits on it, and the only thing that
/// stops it is a hand on the keyboard.
pub fn ringing() -> fn() -> Outcome {
  fn() { ring(default_options(), live()) }
}

/// The alarm for someone who has asked for silence.
pub fn silent() -> fn() -> Outcome {
  fn() { Awake }
}

/// The alarm as this machine experiences it.
pub fn live() -> Effects {
  Effects(idle_seconds: macos.idle_seconds, play: macos.play, sleep: sleep)
}

pub fn default_options() -> Options {
  Options(between: duration.seconds(5), give_up_after: option.None)
}

/// Rings until the keyboard or mouse is touched.
///
/// Always plays the ringback tone — we do not skip ringing even if the system
/// appears to be active, because the whole point is to make sure the user
/// notices the app surfacing. Stops as soon as any keyboard or mouse activity
/// is detected (`idle_seconds < 1`).
///
/// Returns what happened so the caller can say so, rather than logging from
/// here.
pub fn ring(options: Options, effects: Effects) -> Outcome {
  // Capture the idle baseline at the moment we start ringing. Any activity
  // that happened BEFORE the ring (sudo password entry, pmset wake itself...)
  // must not short-circuit us. We only stop when idle drops below this
  // baseline — meaning NEW keyboard or mouse input arrived while we rang.
  let baseline = effects.idle_seconds()
  keep_ringing(options, effects, 1, baseline)
}

/// Whether the ringing has done its job.
///
/// Either a hand reached the keyboard, or a cap was set and has been reached.
/// `option.None` is the production answer: a ring that stops on its own is a ring
/// that failed to wake anyone.
fn answered(
  idle_now: Int,
  baseline: Int,
  rings: Int,
  options: Options,
) -> Bool {
  let touched = idle_now < baseline
  let capped = case options.give_up_after {
    option.None -> False
    option.Some(limit) -> rings >= limit
  }
  touched || capped
}

fn keep_ringing(
  options: Options,
  effects: Effects,
  rings: Int,
  baseline: Int,
) -> Outcome {
  case effects.play(ringback_tone) {
    Error(reason) -> Silent(reason: reason)
    Ok(Nil) -> {
      effects.sleep(options.between)
      let idle_now = effects.idle_seconds()
      case answered(idle_now, baseline, rings, options) {
        True -> Rung(rings: rings)
        False -> keep_ringing(options, effects, rings + 1, baseline)
      }
    }
  }
}

fn sleep(delay: Duration) -> Nil {
  process.sleep(duration.to_milliseconds(delay))
}
