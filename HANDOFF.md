# Handoff — the install-once redesign

You just arrived. Read in this order; nothing below assumes you were in the room.

| # | Read | What it gives you | ~Time |
| --- | --- | --- | --- |
| 1 | `README.md` → intro + **"Where the design is going (decided 2026-10-22)"** | What showup is, what was decided, and the rule of the rest of that document: everything below the section describes *today's installed binary* — sudo, `/var/log`, `launchctl asuser` — transit, not destination | 5 min |
| 2 | `.planning/BRIEF.md` | Why: the receipt chain. Apple's own "Must be called as root" for both wake commands, `pmset repeat`'s single daily pair, launchd's documented wake-coalescing, EventKit's third-party limits, six open-source alarm projects audited | 15 min |
| 3 | `.planning/ROADMAP.md` | The order of work: 3 phases / 6 plans, and the one pre-made choice (renewal home = root LaunchDaemon on one-shot events) with its recorded rationale and fallback | 5 min |
| 4 | The plan for the phase you join | Each plan is self-executable as written: `<objective>`, `<context>` file refs, tasks with verify/done. Phase 1 starts at `01-session-run/01-01-PLAN.md` | 10 min |

**Open decision** (one question left to a human): `02-01`'s opening checkpoint —
daemon vs sudoers. The daemon is pre-picked; say "flip" there if you disagree.

**Human gates** (cannot be done by the implementing agent): one sudo password
at install, and one two-night real-machine verification (`02-02`, blocking).

**Not in git, working tree only**: `.workbuddy/memory/2026-10-22.md` — the
day's full argument in Chinese, including corrections made along the way.
Read it if the receipts above are not enough.

**House rules you will be held to**:
- Every claim ships with its receipt when written; a claim without one is
  marked as such or not made.
- Comments and logs describe the running binary; the README's direction
  section is the only place allowed to speak of the destination, clearly
  labeled.
- The scheduler core's logic (hold, DST, window discipline) is settled work
  with receipts; the redesign touches modes, paths, ownership, and renewal —
  not those.
