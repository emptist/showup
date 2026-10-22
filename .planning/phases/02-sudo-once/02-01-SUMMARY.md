---
phase: 02-sudo-once
plan: 02-01
status: complete
---

# 02-01 Summary: The contract and the planner

## What shipped

The boundary between the user side and the root side, as a file and a pure
function — the daemon (02-02) executes what these two already judge.

### Task 1: the schedule contract

- `Sources/ShowupCore/ScheduleContract.swift` (new): `ScheduleContract` —
  app, times, ring — with `render()`/`read(_:)` as the codec. The file lives
  at the user ground, `schedule.txt` next to `showup.lock`. Three named
  lines, in this order; values separated from names by one space, so an app
  name with spaces survives as one value. Missing, repeated, unknown, or
  unparseable fields are **errors that name themselves** (`ReaderError`),
  never warnings — the renewal refuses to guess, because a guessed schedule
  is a Mac that wakes for reasons nobody wrote.
- Every armable user run writes it (`Showup.keepTheContract`): the `.show`
  run writes it after the lock wins and the log is announced; the `.showSchedule`
  (dry-run) path writes it too, quietly. A legacy **root** run does not
  write it (its ground is not ground it shares with a renewal). A write
  failure is said out loud on stderr and the run carries on.
- `Tests/ShowupTests/ScheduleContractTests.swift` (new suite, 10 tests):
  round trip, spaces-in-name round trip, normalised times both ways, and one
  named-field pin per refusal shape (missing, unnamed, repeated, bad times,
  bad ring, empty times, empty contract).

### Task 2: the pure planner and its executor

- `Sources/ShowupCore/Renewal.swift` (new): `OwnedWake` (instants + owner,
  as read back), `renewalTag` = `com.showup.wake` (the existing identifier),
  and `planRenewal(requested:armed:now:)` — take back only wakes under the
  tag and not owed; arm every still-future owed moment the list does not
  hold; a request at `now` exactly, or past, is spent. Idempotent by
  construction: after the plan acts, the same contract re-read at a second
  now plans nothing. `requestedMoments(times:now:calendar:)` derives the
  owed instants the way the scheduler swaps: next occurrence per time of
  day, calendar-settled (`bySettingHour`, same call `nextWakeAbsolute` uses
  — semantics inherited, not reinvented).
- `Sources/ShowupMac/RenewalMac.swift` (new): `ScheduledWake.arm(at:)` —
  one one-shot kernel event, no cancels-first, no process note (the plan is
  the discipline); `ScheduledWake.cancel(wake:)` — cancels by the exact
  instant+owner pair and reports whether the kernel accepted it;
  `runRenewal(contractDirectory:)` — read contract → read kernel list →
  plan → act, narrating each take back/arm into the root ground's log, and
  refusing (exit 1) to act at all if the contract cannot be read.
- `showup renew <contract-directory>` — the subcommand, wired into
  `parseCLI` and the entry. Unprivileged invocation refuses with the 01-03
  standing handoff line, exit 1. The renewal takes neither the instance
  lock nor the exit take-back: its acts are planned whole and owned by the
  plan itself.
- `Tests/ShowupTests/RenewalTests.swift` (new suite, 11 tests): cancel-only-
  ours; no-op when owed == armed; arm-what's-owed; spent requests and their
  linger; request-at-now-exactly; a coincidental other program's wake at
  the owed instant does not stand in for one of ours; idempotence across
  two nows; moments past → tomorrow; arrival exactly at now → tomorrow;
  the spring-forward nonexistent hour (the calendar's own answer, 03:00);
  the autumn repeated hour (its earlier half).

## Deviations, scoped

- **`renew` requires the contract directory as a positional argument**
  (`showup renew <contract-directory>`; missing → `"renew" needs a value`,
  exit 2). The plan's verify suggested a bare `sudo showup renew`; the
  expectation relies on `~` resolving to the schedule's owner — but `sudo`
  resets `HOME` to root's own on macOS (env_reset), so a bare invocation
  would read `/var/root/Library/Application Support/showup/schedule.txt`.
  Passing the directory explicitly removes the guess; the 02-02 daemon
  plist holds the path in its `ProgramArguments`, so the daemon needs no
  `~` answer at all.
- **FakeMachine extension descoped**: the plan suggested extending the fake
  with the owned-wake list; `planRenewal` is judged with direct arrays and
  the contract codec with direct text, which covers the same ground —
  "tests judge plans without a kernel" — without a fake state the renew
  path never reads through Effects. Noted here so it is a decision, not an
  oversight.

## Compile check receipts

- `make test`: **182 tests / 24 suites pass** (was 161/22 after phase 1; the
  +21 are the two new suites).

## Smoke receipts (user mode; live root still owed)

1. **Dry-run writes the contract** — `.build/debug/showup -a Finder -t 4:00,8:00 -n`
   then `~/Library/Application Support/showup/schedule.txt` holds exactly
   `app Finder\ntimes 04:00,08:00\nring yes`. The plan's own verify line,
   satisfied running as uid 501.
2. **A changed schedule rewrites the contract** — a second dry-run
   (`-a "Adobe Photoshop 2024" -t 16:00 -q`) leaves
   `app Adobe Photoshop 2024\ntimes 16:00\nring no`: the contract is the
   schedule's record, updated by the same act that decides it.
3. **Unprivileged renew refuses with the handoff line** —
   `showup renew ~/Library/Application Support/showup` as uid 501 prints
   both refusal lines (the renewal's, then the standing handoff), exit 1;
   no kernel act, no log ground.
4. **A bare `renew` is a parse error** — `"renew" needs a value` plus usage,
   exit 2, before anything is touched.

## Owed to the phase gates (recorded, like phase 1's)

- `sudo showup renew <dir>` live-arming a plan and a second run being a
  no-op — the plan's task-2 verify — needs the install-time sudo; absorbed
  into 02-02's install session alongside phase 1's three root re-checks.

## Notes for 02-02

- The daemon plist's `ProgramArguments` must carry the contract directory
  explicitly: `/usr/local/bin/showup renew /Users/<user>/Library/Application Support/showup`
  (or set `HOME` in the plist; the explicit path is the one that survives).
- The 02-02 agent runs `showup` with no arguments in its sketch; **no
  argumentless mode exists yet** — `parseCLI` requires app+times. Either
  the agent plist passes the app/times at install, or a contract-reading
  run mode is designed then (02-02's to decide).
- The renew log ground is root's (`/var/log/showup`); 02-02's
  "one log, one story" — daemon logging into the user's ground — needs its
  own resolution (its installer receipt covers it, or the plist's
  `StandardErrorPath` reaches the user's dir and the renew's own Log stays
  on root's ground; both are readable paths, 02-02 decides).
