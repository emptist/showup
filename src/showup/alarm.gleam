import gleam/erlang/process
import gleam/option
import gleam/time/duration.{type Duration}
import showup/macos

/// The sound macOS plays when a FaceTime call arrives. It is only 2.2 seconds,
/// so it is heard four times as often for the same alarm length as a phone
/// ringback tone would be.
pub const ringback_tone: String =
  "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/facetime/multiway_invitation.caf"

/// How many refused playbacks are waited out before the sound is declared
/// unplayable.
///
/// This was 3, and it is why a real 04:00 wake produced no sound at all:
/// `afplay` was refused with `AudioQueueStart failed (-66681)` while the
/// audio device was still coming up, three tries over fifteen seconds were
/// not enough, and the alarm gave up for good. The device is the slow part
/// of a wake, not the sound file, so this has to outlast it.
///
/// Sized to cover the whole overnight lead window, so the alarm is still
/// trying right up to the moment the window is due. An alarm that has run
/// out of patience has nothing left to give, and the one thing this program
/// exists to do is make a noise.
const default_play_failures: Int = 40

/// How hard `showup` tries to wake someone up.
pub type Options {
  Options(
    /// How long to wait after each ring before starting the next one.
    between: Duration,
    /// A cap on the number of rings, or `option.None` to ring until a hand reaches
    /// the keyboard. Production uses `option.None`; the cap exists so the loop can
    /// be exercised by tests without one of them ringing forever.
    give_up_after: option.Option(Int),
    /// Consecutive refused playbacks to put up with before declaring the
    /// sound unplayable.
    ///
    /// A machine that has just woken from deep sleep may not have its audio
    /// stack up yet, so the first `afplay` can be refused for a reason that
    /// has nothing to do with the sound file. Giving up on the first refusal
    /// is how the alarm ends up silent on the one wake that needed it, so we
    /// wait and try again. It still gives up eventually, or a genuinely
    /// missing file would ring at nobody until showup is stopped.
    play_failures: Int,
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
/// The only thing that stops it is a hand on the keyboard. It runs in its
/// own process, so nothing else waits on it.
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
  Options(
    between: duration.seconds(5),
    give_up_after: option.None,
    play_failures: default_play_failures,
  )
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
  keep_ringing(options, effects, 1, 0)
}

/// Whether the ringing has done its job.
///
/// This used to compare each reading against a baseline taken before the
/// first ring, so that a `sudo` password or the wake itself could not be
/// mistaken for the user answering. But the baseline is read from
/// `HIDIdleTime`, and a wake registers as HID activity — so on a real wake
/// the baseline is often **zero**, and `idle_now < 0` is never true. The
/// alarm could not be stopped by anything at all, not even a hand on the
/// keyboard, and with no ring cap it would run until showup was killed.
///
/// An absolute reading cannot get stuck like that. Input within the last
/// second means someone is there. The only thing it needs guarding is the
/// wake's own activity, so the first ring is never allowed to answer
/// itself: nobody gets out of bed, decides they are awake, and silences the
/// alarm before it has properly started.
fn answered(idle_now: Int, rings: Int, options: Options) -> Bool {
  let touched = rings >= 2 && idle_now <= 1
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
  failures: Int,
) -> Outcome {
  case effects.play(ringback_tone) {
    Ok(Nil) -> {
      effects.sleep(options.between)
      let idle_now = effects.idle_seconds()
      case answered(idle_now, rings, options) {
        True -> Rung(rings: rings)
        False -> keep_ringing(options, effects, rings + 1, 0)
      }
    }
    Error(reason) ->
      case failures + 1 >= options.play_failures {
        True -> Silent(reason: reason)
        False -> {
          effects.sleep(options.between)
          keep_ringing(options, effects, rings, failures + 1)
        }
      }
  }
}

fn sleep(delay: Duration) -> Nil {
  process.sleep(duration.to_milliseconds(delay))
}
