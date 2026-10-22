# 01-01 Summary — the log and lock grounds follow the runner

Executed per `.planning/phases/01-session-run/01-01-PLAN.md` on 2026-10-22,
after a handoff-led reading (HANDOFF → README direction section → BRIEF →
ROADMAP → the plan), with the baseline suite green before any edit.

## What changed

One new notion, one place: **`Ground`** (`Sources/ShowupMac/Ground.swift`)
is the single decision of where a run's artifacts live. It reads the
runner's identity (`geteuid()`) and answers:

- root → `/var/log/showup<epoch>.log`, `/var/log/showup.lock` — byte for
  byte today's paths;
- not root → `~/Library/Logs/showup/showup<epoch>.log`,
  `~/Library/Application Support/showup/showup.lock`, with the directories
  created by the process's own permissions (`Ground.ensureDirectories()`).

`Ground.logPath(now:directory:)` and `Ground.lockPath(directory:)` are the
pure derivations a test can pin by name; `Ground.logDirectory` /
`.lockDirectory` are the one `isRoot` branch each. `Log.logPath`, `Log.path`,
`Log.pruneOldRuns`'s scan directory, and `InstanceLock.path` all read the
ground now; nothing outside `Ground` hardcodes a log or lock path.

Failure paths are split by the same identity. On root's ground, a log that
cannot be written and a lock that cannot be placed keep today's degraded
lines ("cannot write … the log stays in the terminal", "cannot place the
instance lock (running without sudo); this run is not locked") and the run
carries on. On a user run's own ground neither degraded state exists: an
unwritable log ground or an unplaceable lock is a hard stop with a clear
line — home is the run's own ground, silence there would be lying.
`announceLog()` now returns whether the run may carry on; `hold()` returns
`false` on an unplaceable user-ground lock, which the entry point exits on.

Dry runs create no ground at all: `Ground.ensureDirectories()` is called
only on the `.show` path, before the lock.

## Receipts

- Baseline before edits: `make test` — 155 tests / 20 suites, all pass
  (matching the handoff's claim for `2339220`).
- After edits: `make test` — **158 tests / 21 suites, all pass**. The new
  `GroundTests` (in `Tests/ShowupTests/LogRetentionTests.swift`) pin both
  grounds by name: root's paths byte-identical
  (`/var/log/showup1000000000.log`, `/var/log/showup.lock`), the user's log
  one file per run under its own logs directory and its lock under its own
  support directory, and the two grounds are not the same ground.
- User-mode smoke (uid 501, this machine, 22:21 +0800):
  `.build/debug/showup -a Finder -t 22:23` printed
  `logging to /Users/jk/Library/Logs/showup/showup1792678900.log`, wrote
  that file `0644` on the user's own ground, placed and held the lock at
  `~/Library/Application Support/showup/showup.lock`, opened with the
  stamp line `build 06f6a33 2026-10-22 22:21 +0800`, and contains no
  "cannot write" and no "not locked" line. SIGINT stopped it cleanly.
- Dry-run smoke (`-t <future> --dry-run`): printed the plan, created no
  ground (no log, no lock).
- Root mode: not exercised live here (the session holds no sudo password);
  the root ground's byte-for-byte paths are pinned by
  `GroundTests.theRootGroundKeepsTodaysPaths` instead.

## Deliberately untouched

`prunableLog`, `logRetentionSeconds` (7 days), the `0644` file mode,
`O_NOFOLLOW`, the stamp line, the per-line `write(2)` — all identity-blind
already. `~/Library/Caches` was considered and rejected (the prune would
evict). No scheduler-logic edits: `Scheduler.swift` untouched, and the
wake-costing "did you run with sudo?" warning stands as is — re-homing the
wake act is 01-03's scope, where it becomes the designed handoff line.

## For the next plans

01-02 and 01-03 may assume "the run has its own ground": a user-mode run
logs and locks on ground it owns before any surfacing or wake question is
asked.
