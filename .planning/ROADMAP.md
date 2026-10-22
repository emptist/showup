# Roadmap: showup install-once redesign

## Overview

Three phases. First the night run learns to live without root in its own session (paths, surfacing, wake-act). Then the one password: a root renewal daemon installed at install time, plus the agent that triggers the run. Finally the bills the change itself brings — stamps for two aging artifacts, the migration story, and the honest docs of the new costs.

## Phases

- [ ] **Phase 1: run as a plain user** — the binary behaves correctly with no sudo, end to end.
- [ ] **Phase 2: the sudo-once** — renewal daemon + installer (one password) + agent trigger + rollback.
- [ ] **Phase 3: the bill of the change** — stamps for both artifacts, docs/migration, TECH-DEBT honesty.

## Phase Details

### Phase 1: run as a plain user
**Goal**: `showup -a App -t ...` run without sudo works as a complete session citizen: own log ground, own lock, direct surfacing, honest refusal of the kernel act.
**Depends on**: nothing (first phase).
**Plans**: 3.

Plans:
- [ ] 01-01: Move the run's home out of root (log dir + lock path by mode)
- [ ] 01-02: Surface as self — delete `asuser` on the user path
- [ ] 01-03: The wake stops being the run's job — feature-detect the IOPM act, re-home take-back

### Phase 2: the sudo-once
**Goal**: one password at install time sets up the root renewal daemon and the user LaunchAgent; nightly operation and schedule changes need no privilege.
**Depends on**: Phase 1.
**Plans**: 2.

Plans:
- [x] 02-01: The contract and the renewal planner (schedule file, pure renewal logic, `renew` subcommand, tests)
- [x] 02-02: Installer + daemon daemon-plist + agent plist + rollback, with a blocking real-overnight human verification (sandbox-verifiable work done — the password, the two nights, and the uninstall receipt remain)

### Phase 3: the bill of the change
**Goal**: the two-installable-artifact problem is stamped; docs say what changed, what to do when coming from root-mode, and what the new costs are.
**Depends on**: Phase 2.
**Plans**: 1.

Plans:
- [ ] 03-01: Stamp the daemon, rewrite the README's occupancy story, record TECH-DEBT and the migration/uninstall story

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. run as a plain user | 3/3 | Done | 2026-10-23 |
| 2. the sudo-once | 2/2 | awaiting human gates | - |
| 3. the bill of the change | 0/1 | Not started | - |

## Pre-decided (recorded with rationale, revisit-able at 02-01's checkpoint)

Renewal home = **root LaunchDaemon using one-shot events** (the mac-wake-scheduler shape). Chosen because: (a) it is the only design in which *schedule changes* also need no sudo — the daemon re-reads the contract file each cycle, so "sudo once" is literal; (b) one-shot events avoid `pmset repeat`'s one-slot cap for multi-window `-t` lists; (c) showup already owns the IOPM one-shot discipline (tagged cancels, never cancelall). Fallback on that checkpoint: a sudoers-granted `pmset` path (MacAlarm's shape) if the daemon turns out heavier than the win.
