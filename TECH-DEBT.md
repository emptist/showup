# Technical debt

Complexity in `showup` that has no measured reason behind it. Written during a
review of the tree; **nothing here has been changed**. Line numbers are from
the working tree at the time of writing.

Each item says what the code is, why it looks artificial, and what removing it
would touch.

Line numbers were re-verified on 2026-10-21, after a pass that fixed I1, I2, O1,
O2 and O3 (see the last section). Item 10 — the clock model — was fixed the
next day, the fix was then measured failing on real hardware, and item 11 was
found in the same log. Items 1–9 below are still open.

## Created by the ring-cap removal

### 1. `IdleWindowReport.warnings` can no longer be non-empty

`Sources/ShowupCore/PowerSettings.swift:154` is `let warnings: [String] = []`.
The cap that used to be reported against the machine's idle window was the only
thing that put anything in it.

Takes out: the `warnings` field on `IdleWindowReport` (`PowerSettings.swift:128`),
the loop at `Sources/ShowupCore/Scheduler.swift:223`, and `IdleWindowAuditTests`.
The one surviving non-empty case is the unreadable-settings branch at
`PowerSettings.swift:140`, which would fit as a plain string rather than a list.

## Guards for states the program cannot reach

### 2. `Step.idle`

`Sources/ShowupCore/Scheduler.swift:41`. `Sources/ShowupCore/CLI.swift:41`
throws `.noTimesGiven` when the time list is empty, so `nextWake` can never
return nil from `step`.

Reached only by `Tests/ShowupTests/SchedulerTests.swift:711`, which hand-builds
`Config(app:"Safari", times:[], ...)` to get past the check the CLI already
enforces.

### 3. `SleepEvidence.unreadable`

`Sources/ShowupCore/SleepDetection.swift:16` and `:51`. Requires two consecutive
nil readings. `Mac.idleSeconds()` returns nil only for a non-finite, negative,
or ≥ 86400 value, so this needs a full day without input, twice in a row.

It resolves to `wokeTheUser == true` (`SleepDetection.swift:21`), so the
unreachable case is the one that rings.

Takes out: the case, its report string (`SleepDetection.swift:39`), and the two
tests that pin it (`SleepDetectionTests.swift:23`, `:39`).

### 4. `PowerNotifications.deinit`

`Sources/ShowupMac/PowerNotifications.swift:79`. `shared` is a `static let`
(line 42), so the instance lives for the life of the process and `deinit` never
runs. `ScheduledWake.swift:20` has the same shape and no deinit at all.

## A process per wake, per app

### 5. `isRunning`, and `.launched` vs `.surfaced`

`Sources/ShowupMac/Mac.swift:70`. Spawns `lsappinfo` on every surface, and every
`showApp` call, so that one log line can say "launched" rather than "surfaced"
(`Mac.swift:78`, `:87`).

A process per wake, per app, to choose an adjective. README says so outright:
only the wording of that log line is affected, never what `showup` does.

## Payload nobody reads

### 6. `Step.surfaced(wake:showed:)`

`Sources/ShowupCore/Scheduler.swift:39`. Both payloads are built at the return
sites (`:113`, `:116`, `:120`, `:125`, `:130`) and dropped by the only caller,
`run`, which now matches the case without binding anything
(`Scheduler.swift:10`). They are read by exactly one test assertion
(`Tests/ShowupTests/SchedulerTests.swift:27`).

The doc comment on the case already says there is nothing truthful left to
record. The payloads are kept because they are what makes `step` a function
whose whole result a test can inspect; that is the only reason left.

## Speculative numbers

### 7. `defaultPlayFailures = 40`

`Sources/ShowupCore/Alarm.swift:41`. Three minutes and twenty seconds of
retrying `afplay` before returning `.silent`. The direction is justified by a
real thing — an audio device still coming up after a wake — but 40 is not
measured, and with the alarm now stopping on a key press this only governs how
long a sound that never plays is retried.

### 8. `wakeEvidenceWindowSeconds = 90`

`Sources/ShowupCore/WakeKind.swift:20`. How stale a power-log entry may be and
still count as this wake. Plausible, unmeasured.

## The large one, which is a judgement call

### 9. The whole power-log wake path

`Sources/ShowupCore/WakeKind.swift` in full — 86 lines: the log parser
(`wakeEvent`, `latestWakeEvent`), `wakeEvidenceWindowSeconds`,
`rtcWakeToleranceSeconds`, the `requestedAt` DarkWake correction
(`WakeKind.swift:44`) — plus `Mac.currentWakeKind` and its
`sh -c "pmset -g log | grep -E ... | tail -1"` shell-out
(`Sources/ShowupMac/Mac.swift:113`).

All of it exists for `PowerNotifications.shared == nil`
(`Sources/ShowupMac/PowerNotifications.swift:42`), which happens only when
`IORegisterForSystemPower` refuses to register. On macOS as root it registers.

So there are two complete mechanisms answering "could a person hear this wake":
the kernel's own notifications, and a parser for a log another process writes
asynchronously and may not have written yet. Commit `f4acf04` set out to replace
the second with the first and kept the second as a fallback.

Flagged because it is by far the most code, not because keeping it is clearly
wrong. It is the one item here where the fallback may be worth its price on a
machine that has not been observed to register.

## Found on 2026-10-21, while fixing the wait — resolved, then reopened and resolved again

### 10. The clock is a time of day, and a time of day is not monotonic

Every wait in this program was counted in seconds since local midnight, and the
counting assumed the clock only moves forward. In a zone that observes daylight
saving, twice a year it does not:

- **Spring forward.** The clock jumps from 02:00 to 03:00, so two adjacent
  readings are an hour apart with no time having passed. `holdUntilTheTime`
  read that as an hour of elapsed wait and brought the window up an hour
  **early** — the one thing this program is not allowed to do.
- **Fall back.** The clock jumps from 02:00 back to 01:00, so the reading went
  backwards and the wrap correction added the whole day. A window held across
  it waited twenty-three hours.

**First fix: separate the two kinds of second.** A requirement became a moment,
and the calendar said when it was: the wait is the distance to that moment,
computed with `Calendar.date(bySettingHour:)` (`nextWakeAbsolute`), which knows
which of the two 02:30s is next and that 02:30 does not exist in spring. A
*duration* was counted on `mach_absolute_time`, and evidence kept the wall
clock.

**That fix was wrong, and a real run proved it within hours.** Measured on
2026-10-22 with `-t 04:00,08:00`:

```
04:16:38  waking at 08:00 (pmset 10/22/2026 07:58:59), in 3h 43m 21s
07:58:59  input arrived during the wait (idle 175s -> 0s over 13341s)
07:58:59  holding the window for 6114s until the required time
09:40:53  about to show Binance
```

The 08:00 window went up **one hour and forty minutes late**, and 07:58:59 plus
6114 seconds is 09:40:53 to the second. A 04:00 window in the same run went up
at 04:16:38.

**The mistake.** `mach_absolute_time` stops while the Mac is suspended — the
same property that makes it immune to a clock change makes it blind to a sleep.
A wait that crosses a sleep is not an edge case here; it is what the program is
for. So the duration clock owed itself every second the Mac was down, and the
window waited them out again. The fix for a two-nights-a-year problem cost a
one-hour-every-night one, and no test caught it: the fake machine's duration
clock advanced with the wall clock, so the suite was asserting the arithmetic
of a clock that does not exist on the machine.

**Second fix: count nothing.** The hold asks the machine's wall clock how far
off the moment is, and nothing is accumulated — so there is no clock for a
suspension or a clock change to go wrong on. `Effects.monotonicNow` and
`Monotonic.swift` are gone. A requirement is still a moment settled by the
calendar, which is what keeps the *target* right across a clock change; only the
counting changed.

`RealRunTimelineTests` reproduces both windows to the second from the log above,
and the six-window run they came from, with the machine going down inside each
wait. It fails if the test double's clock is given back the property that
started this — a clock that stops while the Mac is suspended — which is the
check that would have caught the first fix being wrong.

The zone is the system's, read through `Calendar.autoupdatingCurrent` so a
change of setting is followed while the daemon runs. A zone without the changes
— mainland China since 1991 — is tested against the same two nights, where the
wait is the plain distance the wall clock says, and the same night is asserted
to read differently in New York: the system's timezone is what says when a
requirement is, and the answer belongs to the zone it was asked in.

### 11. The same wait asked the kernel to wake the Mac for a moment already past

Found in the same log, at 03:58:20: `waking at 04:00 (pmset 10/22/2026
03:58:20)`. The required time was 99 seconds away and the lead is five minutes,
so `ahead` clamped to zero and `pmset` was asked for a wake in the past — and
the loop then served the same 04:00 a second time, because the cursor was left
on the machine's clock rather than moved past the wake's own moment.

Both are now one thing: the loop steps past a served wake by its moment, so a
rouse that reached nobody spends the wake instead of re-serving it, and an alarm
is never armed for an instant that has gone by.
`aRouseThatReachedNobodySpendsTheWake` fails without the first half.

**The first fix for the alarm was wrong, and it hid a five-hour failure.** It
read "the required time is nearer than the lead" as *there is nothing to wake
for*, and armed nothing at all — on the reasoning that "the machine is up,
because it is running this program". That premise is false: the machine is up
*now*, and its own idle timer is free to take it down during the wait, with
nothing in the program left to bring it back. Reproduced: a step beginning at
03:58:20 for a 04:00 window armed no alarm, the Mac dozed off inside the hold,
and the window went up at **08:58:30**.

**What the alarm is for.** Not to give the machine room — the hold does that —
but to make the required moment *reachable*. So the lead is still taken off the
front of the wait, and when that leaves nothing the alarm moves to the required
moment itself, which is still in the future and so is not TECH-DEBT 11's alarm
in the past. Arming it costs nothing when the machine stays up: the alarm never
fires. `aWakeInsideTheLeadStillAsksTheKernelForTheMomentItself` and
`theShortWaitSurvivesTheIdleTimerBecauseTheAlarmIsArmed` fail without it.

**The general lesson, which is the same one item 10 ends on.** The first fix was
a plausible reading of the log line rather than a question about what the code
was for, and it was accepted because every test still passed — the existing test
asserted *no alarm was requested*, which is exactly what the wrong fix produced.
A green suite pinned the defect as much as the behaviour. The assertion was
about an absence (nothing armed) where the property that mattered was a presence
(the moment must be reachable), and only the second one catches a Mac going
down.

## Not artificial

Checked and left alone, each with a measured incident behind it: the stepped
sleep (`Effects.swift:81`, `:88`), `O_NOFOLLOW` logging to `/var/log`
(`Log.swift:30`), `takeTheWakeBackOnExit` (`Showup.swift:57`), `checkAudible`
and `quietVolume` (`Scheduler.swift:315`, `Schedule.swift:11`), the `requestedAt`
DarkWake correction, and `armedWakes` at startup.

## Resolved on 2026-10-21

Recorded so the next reader does not go looking for them. Each was removed or
fixed, and each fix has a test that fails without it.

| What | Where it was | What replaced it |
| --- | --- | --- |
| `leadSplit` — dead, and semantically opposite to the live formula when the wait is shorter than the lead | `Schedule.swift:19` | Deleted, with its three tests. The scheduler inlines `max(0, wait - leadFor(hour:))`, which is the behaviour the README's lead table describes |
| `checkAudible` ran before the `--no-ring` branch, so a quiet speaker was warned about under `-q`, where nothing plays | `Scheduler.swift:265` | Moved inside `if config.ring`; `noRingDoesNotWarnAboutASpeakerItWillNotUse` and `noRingNeverTouchesTheSpeaker` both fail without it |
| The wait was clamped to `secondsPerDay - 1`, so a time whose moment had arrived exactly went up one second early | `Scheduler.swift:63` | The clamp is gone and the drift correction counts forward round the clock: `max(0, wake.delay - secondsBetween(now, started))`. `aTimeWhoseMomentIsExactlyNowWaitsTheWholeDay` fails without it |
| The same line's `now - started` was a bare difference, so two readings either side of midnight read as most of a day apart | `Scheduler.swift:63` | `secondsBetween`. `aWaitThatStraddlesMidnightIsNotAWholeDay` fails without it |
| `waitForAlarm` and its semaphore — built for when the alarm ran on its own queue, which it no longer does | `TestDoubles.swift:67`, `:181` | Deleted, with all ten call sites. Six of those tests assert that no alarm rang, so the semaphore was never signalled and each blocked for its five second timeout; they ran in parallel, so the suite's test phase took 5.0 seconds, essentially all of it that wait. It now takes 0.35 |
| Dead members on the test double: `desktopPolls`, `loginSeconds`, `touchKeyboard()` | `TestDoubles.swift:40`, `:43`, `:172` | Deleted |
| The clock is a time of day, and a time of day is not monotonic: a hold spanning a clock change read the hour as an hour of wait, or as twenty-three of them | `Scheduler.swift` (the old `holdUntilTheTime`), `Time.swift:44` | Item 10, above. Its first fix — counting durations on `mach_absolute_time` — was measured failing on real hardware and is recorded there rather than quietly replaced, because the reason it looked right is the reason it was wrong |
| A duration counted on `mach_absolute_time`, which stops while the Mac is suspended, so every wait that crossed a sleep owed itself the sleep again — the 08:00 window went up at 09:40:53 | `Effects.monotonicNow`, `ShowupMac/Monotonic.swift`, the old `holdUntilTheTime` | Deleted. The hold asks the wall clock how far off the moment is and accumulates nothing. `RealRunTimelineTests` reproduces both windows from the log to the second |

Still open from the same review: the documentation items (the `sudo` list, the
`slept_during` hook that no longer exists, three stale "runs on its own queue"
comments, the `ioreg` wording on `.unreadable`, DST, `24:00`, "no waiting", and
the two meanings of "early") — all fixed in `4e06879` — and items 1–9 above.
