# showup — install-once redesign (brownfield brief)

**One-liner**: move every `sudo` out of the nightly run and behind one password at install, by assigning the wake-act to a root renewal daemon and letting the night run be a plain user session.

## Current State (Updated: 2026-10-22)

**Shipped**: `2339220` "Sign the logs, seat one showup, and let the old logs go" (155 tests / 20 suites); installed `/usr/local/bin/showup`, stamp `build 0404c92 `.
**Status**: working, but the whole night run executes as root (`sudo showup -a App -t 4:00,8:00`).
**The problem being retired**: a root run is a stranger in its own machine. Everything after the password becomes identity work — borrowing the console session via `launchctl asuser`, tagging/canceling kernel wakes by owner, pairing two pids' logs with the lock's holder, checking "is the target app running" across an identity boundary. The program spent its code proving who is who; that layer is what this work deletes.

**Codebase**: Swift, SPM; `Sources/ShowupCore` (pure scheduling logic, clock-tested), `Sources/ShowupMac` (IOPM/launchctl/Log/lock/stamp), `Sources/showup` (CLI). No UI.

## vNext Goal

**Vision**: one password, once, when installing. After that the machine's nightly behavior is: a root renewal daemon (`launchd`, installed at install) re-arms tomorrow's one-shot wakes from a schedule file that the *user side* writes freely; the night run is an unprivileged session process that holds the moment, rings, waits for the person, and calls `open -a` on its own desktop.

**Why this shape** (the receipt chain):
- The kernel wake act is root-only by two independent doors: `IOPMSchedulePowerEvent` "Must be called as root" (Apple doc), `pmset repeat` needs sudo and allows only one daily pair (local manpage).
- No open-source project found a user-mode door either — 6 projects audited; MacAlarm's own words: "macOS won't let a user app wake a sleeping Mac — that needs the power manager."
- One-shot events expire, *someone* must renew; doing that from an unprivileged run is impossible, so renewal gets its own root home chosen at install.
- `pmset repeat`'s single-slot cap does not bind a daemon using one-shot events (many can coexist; expire when used).

**Scope**:
- Dual mode preserved: running as root still works exactly as today (legacy); the new path is the default *without* sudo.
- Session-side moves: logs → `~/Library/Logs/showup`, lock → user-writable path, `launchctl asuser` deleted on the user path, take-back-on-exit re-homed to the renewal sweep.
- Installer: one script, one sudo, no sudoers files, no SMJobBless/SMAppService ceremony.

**Success criteria**:
- [ ] After one sudo during install: 48 h of operation (including one schedule change) requires zero further passwords and zero privileged code on the run path.
- [ ] A user-mode night run surfaces the app with no `asuser`, logs to user-writable ground, and never touches the root-owned kernel list.
- [ ] The scheduled wake still lands at the requested moments with the existing window discipline (no early window, DST/nav behavior unchanged — no scheduler-logic edits in this work).
- [ ] Suite stays green with the new tests (renewal planning, dual-mode paths); a real overnight run is verified per `02-02`'s checklist.
- [ ] Uninstall leaves no residue in kernel schedule, /Library/LaunchDaemons, LaunchAgents, or logs.

**Out of scope**:
- SMAppService/app-bundle packaging (fixation: helpers stay plain); EventKit-based ringing; UI; changing window/hold/DST semantics; hardware truths (Apple Silicon lid-closed-on-battery, `hibernatemode 25`) — documented, not fought.
