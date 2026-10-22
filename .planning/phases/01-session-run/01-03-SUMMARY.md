---
phase: 01-session-run
plan: 01-03
status: complete
---

# 01-03 Summary: The wake stops being the run's job

## What shipped

A refusal where the wake act belongs to root is a designed state now, not a
failure to nag about.

- `ShowError.wakeIsNotOurs(announced:)` — the new error case. Its description is
  the handoff line in full; the `announced` flag marks the one refusal per run
  that gets to speak it.
- `ScheduledWake.schedule(in:)` — on `kIOReturnNotPrivileged` (refusal by
  privilege) returns the handoff case instead of `.failed(command: …)`. The
  once-per-run bookkeeping (`handoffSaid`) lives here, which is where the fact
  lives.
- `ScheduledWake.wakeHandoffLine()` — the once-per-run ask for outside sites:
  the first site to ask gets the line, every later ask gets nil.
- `ScheduledWake.takeBackLeftovers()` — skips honestly on a run without the
  cancel right (no `IOPMCancelScheduledPowerEvent` attempts at all); the root
  sweep is unchanged.
- `Showup.leaveNothingArmed()` — on user ground: skips the sweep, says the
  standing handoff (if not said earlier), and still reads and reports the
  kernel list. Root: byte-identical sweep-then-list.
- `Showup` exit handler — user ground logs "stopping; the wake was never ours
  to take back" (nothing this run could have armed is armed); root logs
  "stopping; taking the wake back with it" exactly as today.
- `Scheduler.step`'s failure site (line 99) — routing only, no scheduling logic:
  `.wakeIsNotOurs` announced through `effects.log` (once), later refusals
  silent by design, every other failure keeps `effects.warn("did you run with
  sudo?")`. Root's bad-input refusal would still warn.
- FakeMachine grew `scheduleWakeIsARootlessHandoff` and the new test pins
  handoff-once / no-sudo-nag / loop-continues (`aWakeTheKernelRefusesTheUserIsAHandoffLineSaidOnce`).

## Deviation, scoped and user-approved

The plan's file list omits `Sources/ShowupCore/Scheduler.swift`, but the nag it
wants gone is produced there (warn site, line 99). Two routes were put to the
user: **A** — error carries the handoff line, site routes by case (chosen); **B**
— downgrade inside `LiveEffects.warn` (rejected: hides the routing in a layer
tests can't pin, keeps the nag at the site). The edit touches four added case
labels and the warn branch — no scheduling logic, no `holdUntilTheTime` changes.

## Compile check receipts

- `make test`: **161 tests / 22 suites pass** (was 160/22 after 01-02; the +1 is
  the handoff test above). The previously-pinned
  `aFailedWakeScheduleIsWarnedAboutButDoesNotStopTheRun` stands unchanged — root
  failures still warn.

## Smoke receipt (user mode, real machine, no sudo)

Run: `.build/debug/showup -a Finder -t <minute-boundary+2> -q`, killed by SIGINT
after the surface (`-t 00:07`, started 00:05:46). Full trace, abridged:

    00:05:47  listening for the kernel's own sleep and wake notifications
    00:05:47  the wake is the renewal side's to arm; this run does not own the kernel list
    00:05:47  the kernel already has 2 wakes armed:
    00:05:47  this Mac sleeps on its own after 20m without input on AC power (displaysleep 20m, sleep 25m)
    00:05:47  waking at 00:07 (pmset 10/23/2026 00:06:59), in 1m 12s
    00:05:47  the Mac was awake throughout (idle 0s -> 0s over 0s), nothing to wake
    00:05:47  holding the window for 73s until the required time
    00:07:00  about to show Finder
    00:07:00  brought Finder to the foreground
    00:07:00  waking at 00:07 (pmset 10/24/2026 00:01:59), in 23h 59m 59s
    00:08:01  stopping; the wake was never ours to take back

- Handoff line count: **1** (grep -c "renewal side"), said at startup by the
  take-back skip; both later schedule refusals (00:05:47 pre-hold, 00:07:00
  post-surface) are silent by the standing-fact design.
- "did you run with sudo?" count: **0**. Any WARNING count: **0**.
- The kernel list is still narrated (both Apple wakes listed) — a user run
  describes the list, it does not own its writes.
- The exit-take-back line is the user-mode wording above; root behavior is
  pinned by unchanged code paths + the existing test, live root exercise still
  owed with the user's password (absorbed into the 01-01/01-02 root gates).

## Notes for the next plan

- Night smoke used `00:07` as target: the run began 14s before it, so the
  minute-boundary margin rule from 01-02 (`-v+2M`) was applied and worked.
- The cross-midnight schedule roll seen post-surface ("in 23h 59m 59s") is the
  settled scheduler's own behavior, unchanged by this plan.
- Phase 1 is now complete per the plan set: the run is a complete session
  citizen, and Phase 2's installer can be built on it.
