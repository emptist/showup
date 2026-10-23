# Run-model audit before further work (2026-10-23)

Mandate: the user asked for a git-log audit comparing the hand-run version
against the current one, before any more code — after accusing (correctly)
that the last stretch of changes was made in single-turn cycles with no
planning or documenting. This file is that audit. It stands on receipts.

## The graph (git log order, oldest at the bottom)

0404c92  Alarm when the schedule has run out of lead
2339220  Sign the logs, seat one showup, and let the old logs go   ← seat born here
91b135a  Write the direction down before the coworkers arrive     ← boundary
06f6a33  Note the probe script's reading order too (docs only)
5db4423  Run the night as a session, and pay root once at install ← the pivot
3747527  Show what to look at after the install, not only what the install does
b06ac9f  Stop the old showup at install, and let the hold answer nothing
e02452b  Stop the right showup: launchd returns its own, nothing kills first
5c84bdb  Arm at the window's mouth, ring at the wake, drop the no-ring option
c68bc95  Only the window's own wake rings, and typing stops the ring
d6c4a13  End the alarm short of the sleep, receipt the Calendar absence
02fadb3  Give the failed turn's records twenty seconds, not ten
6742e2f  Give the tap test a budget the twenty-second slack allows
a3eb535  Receipt the machine's own foreign-wake producers

Eleven commits after the boundary, one of them docs-only (06f6a33).

## Correction to the same-day chat audit

The chat audit placed `2339220` inside the arc. It is not: `2339220`
precedes `91b135a`. The seat — one showup on the machine, the second run
stopping with "another showup is running" — already existed at the hand-run
boundary. What the arc added on top of it is a launchd-*owned* seat and the
contract, which is the same rule biting a params-over-CLI habit much
harder, but not a new rule.

## The boundary version (`91b135a`)

- You run `showup -a X -t …` by hand in a terminal; that run is the product.
- Params live in the command line. No contract file, no renewal, no plists,
  no install script.
- The seat already exists (one showup; extra runs stop). Logs are signed
  with build stamps; retention prunes old logs.

## What the arc built (stat receipts per commit)

1. **`5db4423` — the only structural commit.** New files:
   `Scripts/install-session.sh` (197 changed), `Scripts/uninstall-session.sh`
   (102), `ScheduleContract.swift` (115), `Renewal.swift` (67),
   `RenewalMac.swift` (121), `Ground.swift` (44),
   `LogRetentionTests.swift` (26). Changed: `Showup.swift` +277,
   `Scheduler.swift` +123, `InstanceLock.swift` +26, `CLI.swift` +14,
   `Makefile` +18, README 107. Effect: params parked on disk (the contract,
   seeded once by the same `-a/-t` at install); root paid once at install
   instead of at run time (the renewal owns the kernel mouths, sweep at
   00:05); launchd agent/daemon plists; the hand-run still seeds and runs
   (that is what the 12:04 manual run did).
2. **`3747527`, `b06ac9f`, `e02452b`** — install's stop mechanics: what to
   look at after install; bootout the predecessor cleanly; launchd returns
   its own. No run-model change.
3. **`5c84bdb` → `a3eb535`** — window behavior, all inside one moment:
   kernel wakes moved to the mouths (moment − lead); the alarm's answer
   anchored on the wake (`keyAnswerToleranceSeconds = 5`); foreign wakes
   slept through and retired (`mouthSlackSeconds = 60`); a failed turn ends
   `stopBeforeSleepSeconds = 20` short of the idle window so its records
   are written awake; EventKit receipts in the README.

## What did not change

The core run of a single moment — hold, wake judgment, surfacing, alarm
budget, `open -a` — is untouched in spirit since `7fbe2ae` split it into
the pure core. The arc changed who starts the run and where the params
live; it did not change what a run does.

## The settled split (correction accepted 2026-10-23)

- **The user's stuff, sudo-free:** the contract. The seated session
  re-reads it every step; hand edits and param runs change the routine
  live ("the schedule changed while holding the wake" is a test-pinned
  mechanic). Born `5db4423`.
- **Root's stuff:** the kernel mouths and the agent's fire times. Only the
  install sequence (sudo) touches them immediately; the 00:05 sweep
  catches contract changes up overnight.
- The chat muddle of the same day stated these as one thing. They are two,
  and the codebase has drawn the line since the day install arrived.

## Process review (the user's criticism, accepted)

Made in single-turn idea→edit→test→commit cycles with no `.planning/` plan
before code: `d6c4a13`, `02fadb3`, `6742e2f`, `a3eb535` — and
`c68bc95`/`5c84bdb`, though driven by the user's receipts, were planned
only in conversation. The fork-test fix `6742e2f` existing at all is
evidence of thinking while editing.

**Rule from now on:** no behavioural commit without a phase plan first —
problem, receipts, decision, tests, rollback — committed before the code
it licenses. The user's word starts every arc; ideas accumulate in the
backlog, not in the working tree.

## The open fork (the user's call, nothing else coded until they speak)

1. **Keep as it stands** — do nothing.
2. **Roll to the installed era** — the build the machine runs today:
   `git checkout -b installed-era 5c84bdb`.
3. **Roll to the hand-run era** — the last version before the arc:
   `git checkout -b hand-run 91b135a`. Two honest notes: the seat already
   exists there; and the machine's installed plists would keep firing
   until uninstalled.

Nothing outside this file moves until the user says which.
