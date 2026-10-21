# Technical debt

Complexity in `showup` that has no measured reason behind it. Written during a
review of the tree; **nothing here has been changed**. Line numbers are from
the working tree at the time of writing.

Each item says what the code is, why it looks artificial, and what removing it
would touch.

Line numbers were re-verified on 2026-10-21, after a pass that fixed I1, I2, O1,
O2 and O3 (see the last section). Item 10 — the clock model — was fixed the
next day and now lives in the resolved table; items 1–9 below are still open.

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

## Found on 2026-10-21, while fixing the wait — resolved the same week

### 10. The clock is a time of day, and a time of day is not monotonic

Every wait in this program was counted in seconds since local midnight, and the
counting assumed the clock only moves forward. Twice a year it does not:

- **Spring forward.** The clock jumps from 02:00 to 03:00, so two adjacent
  readings are an hour apart with no time having passed. `holdUntilTheTime`
  read that as an hour of elapsed wait and brought the window up an hour
  **early** — the one thing this program is not allowed to do.
- **Fall back.** The clock jumps from 02:00 back to 01:00, so the reading went
  backwards and the wrap correction added the whole day. A window held across
  it waited twenty-three hours.

**Resolved by separating the two kinds of second.** A requirement is a moment,
and the calendar says when it is: the wait is now the distance to that moment,
computed with `Calendar.date(bySettingHour:)` (`nextWakeAbsolute`,
`Schedule.swift:47`), which knows which of the two 02:30s is next and that
02:30 does not exist in spring. A duration is counted on the monotonic clock
(`Effects.monotonicNow`, `mach_absolute_time`), which is the same length on
both sides of a clock change and never wraps, so the hold no longer corrects
for midnight at all. Evidence keeps the wall clock, deliberately: the
monotonic clock stops while the Mac is suspended, and the seconds a sleep cost
are exactly what the idle counter is asked about.

Four tests, each of which fails without the change: two against New York's
spring and autumn, where the wait is checked against the hours that actually
pass, and two where the wall clock jumps inside a running hold
(`clockJumpsOnSleep` on the test double) and the wait is checked against the
seconds that really went by.

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
| The clock is a time of day, and a time of day is not monotonic: a hold spanning a clock change read the hour as an hour of wait, or as twenty-three of them | `Scheduler.swift` (the old `holdUntilTheTime`), `Time.swift:44` | Item 10, above: the wait is the distance to a calendar moment, the hold counts on the monotonic clock, and evidence keeps the wall clock. Four tests, two per direction |

Still open from the same review: the documentation items (the `sudo` list, the
`slept_during` hook that no longer exists, three stale "runs on its own queue"
comments, the `ioreg` wording on `.unreadable`, DST, `24:00`, "no waiting", and
the two meanings of "early") — all fixed in `4e06879` — and items 1–9 above.
