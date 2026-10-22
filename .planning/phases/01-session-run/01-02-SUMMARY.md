---
phase: 01-session-run
plan: 01-02
status: complete
---

# 01-02 Summary: Surface as self

## What shipped

`showApp` no longer forges an identity when the run doesn't need one.

- `Mac.surfaceCommand(asRoot:uid:app:)` — the one place that shapes the surfacing
  command. A run that is not root gets plain `/usr/bin/open -a <app>` — no uid
  resolution, no console-user probe. Root gets `launchctl asuser <uid> /usr/bin/open`,
  unchanged from legacy.
- `Mac.showApp` now asks `consoleUID()` only on the root path (`Ground.isRoot`);
  the `isRunning` pre-check stays on both paths, unchanged, because it is an app
  question, not an identity question.
- `Session.consoleUID()` doc notes its one remaining caller.
- `SurfaceCommandTests` (new suite in PlatformTests.swift, 2 tests) pin both shapes.

## Compile check receipts

- `make test`: **160 tests / 22 suites pass** (158/21 before this plan; the +2 are
  `aRunThatIsNotRootSurfacesAsItself` and `theRootRunBorrowsTheConsoleSession`).
- Rebuild also re-linked `.build/debug/showup`; the run below confirms the binary
  has the new path.

## Smoke receipt (user mode, real machine)

Run: `.build/debug/showup -a Finder -t <minute-boundary+2> -q`, as uid 501,
with a `ps` watcher polling every 50ms across the whole run.

Log trace — same timing and adjectives as before the plan:

    22:50:05  holding the window for 115s until the required time
    22:52:00  about to show Finder
    22:52:01  brought Finder to the foreground

Watcher output at that exact moment — exactly one exec, of the plain shape:

    22:52:00  ... /usr/bin/open -a Finder
    22:52:01  ... /usr/bin/open -a Finder   (same pid, seen on 3 polls)

`asuser` sightings across the whole monitored run: **0** (grep -c on the watcher
log). No console-user probe can show up in `ps`, but the code path is one
`/usr/bin/open` exec; the watcher output above is its shape.

Done criterion met: the user-mode trace contains no `asuser` — beyond "contains
no", the exec that happened is the one `SurfaceCommandTests` pinned.

## Root path

No sudo password in this session (as recorded in 01-01), so the root path is
pinned by `theRootRunBorrowsTheConsoleSession` (`/bin/launchctl asuser <uid>
/usr/bin/open -a <app>`) rather than exercised live. Still owed for the phase:
a real root run's near-moment surfacing, absorbed into 01-01's existing root
gate when the user supplies the password.

## Notes for the next plan

- `-n` is `--dry-run` (prints the schedule and exits); `-q` is `--no-ring`. A
  smoke attempt initially used `-n` and "ran" without running.
- The target time must clear the minute boundary by more than the time between
  computing `-v+2M` and showup parsing argv: when the parse crossed 22:48:00 the
  schedule rolled the first wake to tomorrow ("in 23h 59m 53s"), so nothing
  surfaced in that attempt. Taking the target at a minute boundary plus two
  whole minutes keeps the margin.
- Killing the background wrapper's subshell pid does not stop showup; signal the
  showup pid itself.
- The schedule/time cross-midnight behaviour seen above is pre-existing and
  owned by the settled scheduler work, not by this plan.
