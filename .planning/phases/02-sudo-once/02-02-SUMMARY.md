---
phase: 02-sudo-once
plan: 02-02
status: complete-pending-gates
---

# 02-02 Summary: The install once, and the run that follows the contract

## What shipped

The install session (one password) and everything it installs: the renewal
daemon, the launch agent, and the contract-following run the agent starts.
The people-hours after the password are all unprivileged.

### Task 1: the bare run, and the schedule it follows

- `Command.runFromContract` (`Models.swift`): deliberately argumentless —
  "no schedule is said out loud, because the schedule lives in the contract".
  Empty args dispatch to it in `parseCLI` (receipted by a CLI pin test: bare
  input → `.runFromContract`, not an error). Root-ground bare runs translate
  to the old missing-app error, exit 2.
- `runFromTheSchedule()` (`Showup.swift`): reads the contract loudly — a
  missing file gets its own refusal ("there is no schedule contract at …",
  plus the line that says where one is written from, exit 1, via
  `CocoaError.fileReadNoSuchFile` — `fileNoSuchFileError` was the wrong case
  and was caught by a probe); any other read failure is said and refused.
- **The contract rules the schedule.** `run(config, effects:,
  scheduleRefresh:)` re-reads it at each loop top (nil → keep standing), and
  — the part a first wiring attempt missed — inside every wait: `step(…,
  scheduleChanged:)` compares each read against the schedule the *step*
  started with (not the adopted one — comparing against the adopted config
  hid the change the test knew why to hide). A true answer ends the
  attempt as the new `Step.withdrawn`: no alarm, no app, cursor = the
  machine's now, and the loop re-plans from the clock with the fresh
   contract. `sleepSeconds(…, checking:)` asks the hook after each ten-second
   step.
- **The fallback hold fell out of the wiring and a receipt proved it.** When
  the lead runs out (`ahead == 0`: a moment three minutes away against a
  five-minute night lead), a step skips its own hooked wait entirely, and the
  whole remaining wait ran inside `holdUntilTheTime` — which had no hook. A
  first live receipt aimed at the once-per-note claim failed instead: the
   change landed and Finder was surfaced anyway, because the only check had run
  before it. Fixed: the fallback call passes `scheduleChanged` and turns a
  change into `.withdrawn`; the holds that follow a real wake pass nothing
  (surface equity — the machine came up, somebody may be there; the fresh
  schedule is followed from the next moment). Pinned by three fake tests:
  the original mid-wait withdrawal, the leadless-hold withdrawal, and the
  boundary test that counts thirty-one asks (thirty ten-second steps plus
  the step's final check) and shows the post-wake hold asks none.
- **Once-per-condition notes** (`noteContractOnce`): with a hook firing every
  ten seconds, an unreadable contract would have written ~360 log lines an
  hour; each distinct note is now said once until a different note takes its
  place, and a contract returning to health is said too. The nonisolated
  static follows the two existing house patterns (`InstanceLock.heldDescriptor`,
  `signalSources`).
- `bootTheNight(config)` writes the contract **before** `InstanceLock.hold()`:
  a second full run (the natural "change the times" command) records its word
  even though it exits on the lock, so a stale survivor cannot lock out a
  schedule change.
- Renewal narration (`renewalSays`, stderr "showup: …"): the daemon's
  plist captures stderr+stdout into `~/Library/Logs/showup/renew.log` on the
  user's own ground — "one log, one story" — the 02-01 loud-note while a
  run holds a moment stays the run's own log. `renewFrom` was slimmed to:
  root refusal → a stderr build-signature line (`readBuildStamp()`'s raw
  "build <hash> <date>") → `exit(Int32(runRenewal(…)))`. The 02-01
  byte-for-byte receipt for root ground is untouched.

### Task 1 (scripts): what the password buys

- `Scripts/install-session.sh` (sudo, receipted step by step): binary+stamp
  to `/usr/local/bin`; the daemon plist (`com.showup.renew` in
  `/Library/LaunchDaemons`) running `/usr/local/bin/showup renew <explicit
  contract dir>` daily at 00:05 with `StandardErrorPath`/`StdOutPath` into
  the user's log dir (made and `chown`ed first); bootout-before-bootstrap,
  then the first renewal at install time, so the password pays for tonight's
  wake immediately; the seeding dry-run in the user's session (its previews
  are the same schedule the plan judges); the agent plist (`com.showup` in
  `~/Library/LaunchAgents` — bare program, `RunAtLoad true`,
  `StartCalendarInterval` array at each chosen time, 24:00 → hour 0,
  `$((10#$HOUR))` against octal, staged at `/tmp`, installed user-owned with
  `install -o uid -g gid`); agent bootstrap. User resolution:
  `SUDO_USER` → `stat /dev/console`; home via `dscl NFSHomeDirectory` with
  the `/Users/<user>` fallback. Rerun-safe (bootout first both sides,
  reseed, rewrite plists). Final receipt block quotes `README`.
- `Scripts/uninstall-session.sh` (sudo): bootout the daemon + remove its
  plist; the wake sweep — parse `pmset -g sched` for `wake at MM/DD/YYYY
  HH:MM:SS` + `com\.showup\.wake` and `pmset schedule cancel wake "$WHEN"`
  per entry (cancelall never; no other program's alarms touched); bootout
  the agent + remove its plist; remove binary+stamp, contract+lock
  (including the legacy `/var/db/showup.lock`); logs kept for their week.
- `Makefile`: `install-session APP= TIMES=` (builds release first, refuses
  without both, hands over via env to the script which asks sudo itself) and
  `uninstall-session`.

### Task 2: the README

- The Usage block documents the two scheduleless forms (`showup` bare;
  `showup renew <dir>`).
- The install/occupancy story in *Where the design is going*: what one
  password buys (the six acts), what happens nightly (a bare run per moment
  via launchd, contract-driven; the start runs keep writing the contract and
  the standing run follows changes without a restart), how to change times
  (any of the usual runs — dry-run or full — no password), how to leave
  (`make uninstall-session`), and the two honest costs stated with the
  promise: at most one stale kernel wake between a change and the 00:05
  sweep (cost: one unexplained wake-up that serves nothing), and the honest
  "the shape is built and receipted but no machine has lived under it yet"
  marking, because the install itself waits for its password.

## Deviations, scoped

- **Launch labels are mine** (`com.showup.renew`, `com.showup`): the plan's
  sketch had `com.<label>.showup-renew`; the shorter pair reads the same way
  the existing kernel-tag `com.showup.wake` does.
- **A bare contract mode exists now, and the agent runs it.** The 02-01
  summary left this as 02-02's decision; it is made: the bare run is the
  agent's program, empty args say the contract governs, and the user-side
  CLI gains no third way to answer.
- **The renew log goes to the user's ground via launchd only** — the renew
  process itself still takes no log ground (`Ground` stays user-shaped);
  by-hand `sudo showup renew` narrates to the terminal. This is the
  decision the 02-01 notes asked for, and the installer makes the dir.
- **`refreshSchedule` is the run's own state**, not Config: the note-once
  state rides the entry layer, untested by the suite (it is stderr-adjacent
  plumbing above the tested core) — receipted live instead.

## Test receipts

- `make test`: **187 tests / 24 suites pass** (was 185 at session start;
  +1 CLI bare pin, +2 withdrawal tests, -1 folded: the CLI pin replaced a
  count). The boundary count test's `31` was measured live in a scratch
  print, not guessed.

## Live receipts (debug build, user mode)

1. **Once-per-note (receipt A)**: contract for [+4 min] seeded; the bare run
   entered the fallback hold; the contract file was deleted at ~8 s in;
   ~120 s of ten-second reads later the log holds exactly **one** "the
   schedule contract is gone from …; keeping the standing schedule" line.
   (Before the fix the same trial produced zero notes — and exposed the
   fallback hole instead, which is how receipts earn their keeping.)
2. **Fallback withdrawal (receipt B2)**: [Finder +3 min] seeded; the boot
   log shows the lead-less fallback ("waking at 02:30 …, in 2m 32s" → "the
   Mac was awake throughout … over 0s" → "holding the window for 153s");
   the contract changed to [Preview T1−105 s] at T1−88 s; at +5 s past the
   change the run says "the schedule changed while holding the wake; this
   moment is not served", **Finder is never surfaced (0 hits)**, and the run
   re-plans from the machine's clock: "waking at 02:28 (pmset 10/24/2026
   02:22:59), in 23h 58m 52s" — the fresh schedule's next moment read
   forward to tomorrow and armed.
3. **Script receipts**: `shellcheck` 0.11.0 clean on both scripts after the
   SC2015 fix and the if/else bootout rewrite; explicit root gates refuse
   rootless runs with the password-shaped line (receipted, exit 1 both);
   `bash -n` clean; the SC2015 pass happened because a plain-as-installed
   uninstaller run (no sudo) all but wrote binary paths — the gate is now
   the first act.
4. **Ground left clean**: the contract dir, logs, survivor processes —
   none. No sudo used anywhere this session.

## Owed to the human gates (not this session's)

- `make install-session APP=<app> TIMES=<times>` with the password; the
  receipt block; the nightly story confirmed for real.
- Two nights: 01:00/24:00-style dense schedules, the 00:05 sweep receipts,
  a schedule change landing inside a real hold, and the DST-night re-checks
  absorbed from phase 1 and 02-01.
- `make uninstall-session`'s four acts receipted live (the wake sweep and
  the `pmset cancel` lines among them).
- Forensic thread carried: the "waking at <moment> (pmset <one second
  earlier>)" display quirk — arm instants read one second before the lead
  point the docs say; harmless if display-only, wrong if the arm is early
  by a second; settle it at the install session against `pmset -g sched`
  when root can read its own receipts.
- `watch2.sh`'s ps-watcher pattern quoting bug (exec sightings unusable) —
  fix before any future process watcher receipt.

## Where the next step is

Phase 2's sandbox-verifiable work is done; what remains is the password and
the two nights. `.continue-here.md` describes the handoff exactly.
