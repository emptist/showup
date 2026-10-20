# Technical debt

Complexity in `showup` that has no measured reason behind it. Written during a
review of the tree; **nothing here has been changed**. Line numbers are from
the working tree at the time of writing.

Each item says what the code is, why it looks artificial, and what removing it
would touch.

## Created by the ring-cap removal

### 1. `IdleWindowReport.warnings` can no longer be non-empty

`Sources/ShowupCore/PowerSettings.swift:154` is `let warnings: [String] = []`.
The cap that used to be reported against the machine's idle window was the only
thing that put anything in it.

Takes out: the `warnings` field on `IdleWindowReport` (`PowerSettings.swift:128`),
the loop at `Sources/ShowupCore/Scheduler.swift:90`, and `IdleWindowAuditTests`.
The one surviving non-empty case is the unreadable-settings branch at
`PowerSettings.swift:140`, which would fit as a plain string rather than a list.

## Guards for states the program cannot reach

### 2. `Step.idle`

`Sources/ShowupCore/Scheduler.swift:36`. `Sources/ShowupCore/CLI.swift:41`
throws `.noTimesGiven` when the time list is empty, so `nextWake` can never
return nil from `step`.

Reached only by `Tests/ShowupTests/SchedulerTests.swift:404`, which hand-builds
`Config(app:"Safari", times:[], ...)` to get past the check the CLI already
enforces.

### 3. `SleepEvidence.unreadable`

`Sources/ShowupCore/SleepDetection.swift:16` and `:51`. Requires two consecutive
nil readings. `Mac.idleSeconds()` returns nil only for a non-finite, negative,
or ≥ 86400 value, so this needs a full day without input, twice in a row.

It resolves to `wokeTheUser == true` (`SleepDetection.swift:22`), so the
unreachable case is the one that rings.

Takes out: the case, its report string (`SleepDetection.swift:38`), and the two
tests that pin it (`SleepDetectionTests.swift:29`, `:43`).

### 4. `PowerNotifications.deinit`

`Sources/ShowupMac/PowerNotifications.swift:79`. `shared` is a `static let`
(line 42), so the instance lives for the life of the process and `deinit` never
runs. `ScheduledWake.swift:20` has the same shape and no deinit at all.

### 5. `isRunning`, and `.launched` vs `.surfaced`

`Sources/ShowupMac/Mac.swift:54`. Spawns `lsappinfo` on every surface, and every
`showApp` call, so that one log line can say "launched" rather than "surfaced"
(`Mac.swift:71`).

A process per wake, per app, to choose an adjective.

## Payload nobody reads

### 6. `Step.surfaced(wake:showed:)`

`Sources/ShowupCore/Scheduler.swift:34`. `showed` is built at both return sites
(`Scheduler.swift:76`, `:80`) and dropped by the only caller, `run`, which reads
`wake`. Read by exactly one test assertion
(`Tests/ShowupTests/SchedulerTests.swift:27`).

The doc comment on the case already says there is nothing truthful left to
record.

## Speculative numbers

### 7. `defaultPlayFailures = 40`

`Sources/ShowupCore/Alarm.swift:30`. Three minutes and twenty seconds of
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
(`Sources/ShowupMac/Mac.swift:97`).

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

## Not artificial

Checked and left alone, each with a measured incident behind it: the stepped
sleep (`Effects.swift:72`), `O_NOFOLLOW` logging to `/var/log` (`Log.swift:30`),
`takeTheWakeBackOnExit` (`Showup.swift:57`), `checkAudible` and `quietVolume`
(`Scheduler.swift:155`), the `requestedAt` DarkWake correction, and
`armedWakes` at startup.
