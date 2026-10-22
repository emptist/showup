# showup

`showup` is a macOS command line tool that brings an application to the
foreground at the times you choose, so you can switch to it without hunting
for it among your windows. If the application is not running yet, it is
launched for you.

```sh
# The shipped binary runs as root today; under the planned redesign this is
# the same command without `sudo`. See "Where the design is going" below.
sudo showup -a Safari -t 8:00,12:00,16:00,20:00
```

The `sudo` is needed for two things, and both of them are root's alone: asking
the power-management system to wake the Mac out of sleep, and creating the log
file under `/var/log`. Everything else is done as your normal user — the sleep
evidence is read from APIs that answer the same either way, the alarm plays at
the speaker, and the app is surfaced by `launchctl asuser` into the console
user's session rather than into root's. (This describes the shipped binary —
the transit, not the destination; see *Where the design is going* below.)

`showup` works out when the next of your times is, asks the kernel to wake the
Mac a little before it, and then brings the application to the front. If the
Mac was asleep it rings first, until you answer. It then does the same again for
the next day, and the next, until you stop it with Ctrl-C. A time that has
already passed today waits for tomorrow, so it is safe to leave running.

Start it after you log in and stop it before you log out. It is built for a
session that is always there behind the login window: when the Mac wakes with
the screen locked, your session is still alive, the app is launched into it, and
it is waiting for you the moment you type your password.

## Where the design is going (decided 2026-10-22)

Everything below the install section describes how the **installed binary
behaves today** — its `sudo`, its `/var/log` log, its `launchctl asuser`
surfacing. None of it has changed, and it is written as the present tense
because it is still true tonight. The root shape is kept: running it with
sudo, exactly as documented, keeps working unchanged for as long as anyone
wants it.

The decided direction changes exactly one thing in kind: **where the
password lives.** The nightly run stops executing as root; the one
privileged act — arming the kernel's wake — moves behind a single password
paid once at install time. The reason is not aesthetics: most of what the
root run does after its password is identity work — proving who is the
console user, whose wake is whose kernel entry, which pid holds which lock —
and a run in its own skin stops needing any of it. The receipts for why this
is the only shape are in `.planning/BRIEF.md` (Apple's own "Must be called
as root" documentation for both wake scheduling commands, the one-slot cap
and renewal bookkeeping of `pmset repeat`, launchd's documented
wake-coalescing semantics, six open-source alarm projects audited — none of
which found a user-mode door for the wake itself), and the work order is
`.planning/ROADMAP.md` with one executable plan per step.

### The install (one password, then never again)

```sh
make install-session APP=Safari TIMES=04:00,08:00
```

`make` builds the release binary and asks for the password once. The install
session then does seven things, saying each as it goes:

1. installs the binary and its build stamp to `/usr/local/bin`;
2. returns the previous night run to launchd (`bootout`) and stops any
   `showup` not in launchd's keeping — the run the last install's agent
   stood up is what's usually running, so it is launchd's to stop first;
   a run somebody started by hand is asked politely and killed if it
   refuses. The instance lock follows the process, so the new run starts
   clean;
3. installs the renewal daemon (`com.showup.renew` in `/Library/LaunchDaemons`),
   which runs `showup renew` daily at 00:05 — its narration lands in
   `~/Library/Logs/showup/renew.log` on your own ground, made and owned by you;
4. loads the daemon and runs the first renewal right then, so the password
   pays for tonight's wake immediately;
5. seeds the schedule contract with a dry-run in your session — the same
   preview a normal run prints, written to
   `~/Library/Application Support/showup/schedule.txt`;
6. installs the launch agent (`com.showup` in `~/Library/LaunchAgents`), a
   bare `showup` with an interval at each of the chosen times;
7. loads the agent, which starts the first full run immediately.

It prints a receipt of everything it touched, and the same lines are what
`README.md` documents. `make uninstall-session` is the same in reverse: one
password — any `showup` still running is stopped first (a polite stop lets
it take its own kernel wake back on the way out), everything installed is
removed, the kernel wakes it armed are taken back one by one (`pmset
schedule cancel`, not `cancelall` — nobody else's alarms are touched), and
the logs kept for their week.

### What to look at afterwards

Changing the schedule is the fourth nightly act and it is yours, in your own
session, without a password:

```sh
showup -a Safari -t 05:00,13:00 -n     # a dry-run; the standing run follows the change
```

The two nights are observations, not commands — let the machine sit, then
read what it wrote:

```sh
pmset -g sched                                  # wakes read `by com.showup.wake` at your times
tail -20 ~/Library/Logs/showup/showup*.log      # the run's own receipts
tail -20 ~/Library/Logs/showup/renew.log        # the daemon's 00:05 sweep
```

### After the install (the nightly story)

At each chosen time, launchd starts a bare `showup` in your session. It reads
the contract for the schedule, arms for today's remaining times, surfaces the
app — and stays. Your own runs keep writing the contract and the standing run
follows the changes without a restart: a time removed mid-hold is withdrawn
(no alarm, no app), a time added is served. The 00:05 daemon keeps the
kernel's one-shot wakes matched to the contract, so a change is picked up at
the next sweep even with no user act along the way.

Two honest costs, stated with the promise rather than after it:

- A schedule change can leave at most one stale kernel wake armed, until
  00:05's sweep takes it back. Its cost is one unexplained wake-up: the
  machine wakes, the agent's interval coalesces or the fresh run reads the
  contract, nothing happens that the old schedule asked for.
- The installs land on a real machine only when its password is given. The
  scripts are shellcheck-clean and every step is receipted, but the
  two-night verification (24:00-overnight renewals, DST nights, the
  reinstall and uninstall receipts) is still owed — this section describes
  the built shape, not a machine that has lived under it yet.

Sections below that hinge on the root run — the opening `sudo` paragraph,
the `launchctl asuser` row, *The log*, the design-implications list — carry
their own pointers now, so lines read out of a meeting cannot mistake the
transit for the destination.

## Building

The project is written in [Swift](https://swift.org) and targets macOS. It uses
swift-tools-version 6.2 and needs a Swift 6.4 toolchain. No external
dependencies are required beyond the toolchain that ships with Xcode / the
Command Line Tools.

```sh
swift build                    # builds a debug binary
swift build -c release         # builds an optimized binary
```

That writes a `showup` binary in `.build/debug/` (or `.build/release/`), which
is self contained. Putting it somewhere on your `PATH` installs it:

```sh
install -m 0755 .build/debug/showup /usr/local/bin/showup
```

A copy installed by hand is stampless: `make` writes the identity stamp
(`.build/debug/showup.stamp`) beside the binary, and a run that finds no stamp
next to itself says so rather than assuming anything. `make install` installs
both.

## Usage

```text
showup -a <app> -t <times> [-n] [-q]
showup                                 # serve the schedule the contract carries
showup renew <contract-directory>

  -a, --app <name>      The application to surface, for example "Safari".
  -t, --times <times>   Comma separated times of day, such as
                        8:00,12:00,16:00,20:00,24:00. A bare hour such as
                        8 means 8:00.
  -n, --dry-run         Print the next few wake times and exit.
  -q, --no-ring         Never make a sound.
  -h, --help            Show the full message.
```

The forms saying no schedule (`showup` bare) are the installed run's: they
read the schedule contract the user's own runs write (`schedule.txt`) and
serve it, re-reading it between moments, so a changed schedule is followed by
the run standing in the session without a restart. Bare with no contract in
place is refused with the line that says where one is written from. `renew`
is the renewal side's act and belongs to root; see *Where the design is
going*.

`--no-ring` is worth understanding before you use it. By default `showup`
only ever rings when it had to wake a sleeping Mac — never when the machine was
already up, where you are assumed to be present and looking.

Both `--flag value` and `--flag=value` are accepted, repeated `-t` flags are
combined, and times are sorted and deduplicated.

`24:00` is the end of the day, which is the same moment as `0:00`, the start of
the next one. They are two spellings of one time: `-t 24:00` and `-t 0:00` mean
the same thing, and `-t 24:00,0:00` is one entry rather than two, because both
are parsed to midnight before the list is deduplicated.

The list of times has to be one argument, because the shell splits a list with
spaces after the commas into several of them:

```sh
showup -a Safari -t 8:00,12:00,16:00      # right
showup -a Safari -t 8:00, 12:00, 16:00    # wrong, the shell splits this
showup -a Safari -t "8:00, 12:00, 16:00"  # right, quoted as one argument
```

```sh
showup --app="Slack" --times="9,17"   # 09:00 and 17:00 every day
showup -a Mail -t 24:00               # midnight
showup -a Mail -t 9:00 --dry-run      # show the plan without waiting
showup -a Mail -t 9:00 --no-ring      # never make a sound
```

## The two programs inside showup

A scheduled wake does one of two completely different jobs, and which one it
is depends on something the clock cannot tell you: whether the Mac spent the
wait asleep. So `showup` asks the power log, and branches.

**Program 1 — surface.** The machine was up the whole time. Someone is very
likely sitting at it. Bring the app to the front, and stop. No sound, no login
wait, no ceremony. This is the whole job, and it is the job most wakes want.
(The clock is still held to the required time. That is the time itself rather
than a wait for anybody.)

**Program 2 — rouse.** The Mac was asleep and this is the wake we asked for.
Ring, until a hand reaches the keyboard. Then bring the app up.

In that order, and the order is the point. An earlier version launched the app
at the target time and rang alongside it, which sounds right and does not
work: `open` reported success into a session whose screen was locked, and
nothing was in front afterwards. The activation does not survive the screen
coming back. So the ringing is not a courtesy before the work — it is what
tells us there is somebody there, and the app goes up the moment there is.

And when there is nobody, the app does not go up at all. It is for the user to
see, so bringing it up for nobody is never useful: the window goes up into
the session behind the login window, where it is lost. A wake nobody answered
ends the run, and the loop goes on to arm the next one.

One thing the ringing does not do: it does not bring the app up *early*. If
the alarm is answered before the required time, the window waits for the time
to arrive. The alarm says somebody is there; the clock says when the window
belongs to them.

There is no public API for "is the screen locked": `CGSessionCopyCurrentDictionary`
has no lock key and returns nothing at all for a process without a window
server session, and showup runs as root without one. The keyboard counter is
the signal, and it is already answering exactly this question for the alarm.

There is a second question, though, and the alarm cannot answer it. The alarm
stops at the *first* key press, and that key press may be the first letter of
a password typed at the login window. Bringing the app up then loses it: `open`
reported success into a session whose screen was still locked, and nothing was
in front after the unlock, because the activation does not survive the screen
coming back.

So after the alarm is answered, showup waits for the login to finish, and only
then for the required time. The two waits are different waits and the order
matters: the window cannot be brought up before the screen comes back, and it
does not want to wait for the time before the screen comes back either.

The signal is `kCGSessionLoginDoneKey` in the console user's session record.
`CGSessionCopyCurrentDictionary` returns that record, but only for a process
with a window server session, so it is read through `scutil` instead, which
answers as root as well as as the user. `Scripts/login-state-probe.sh` records
what the machine says over time, in the three states that have to be told
apart, and `Scripts/lock-state-probe.sh` samples the same signals every two
seconds for the narrower question of which of them moves when the screen locks
— the distinction between locked and logged in, which is the one this wait
turns on.

A `DarkWake` — the machine coming up for network and mail maintenance with
the screen still off — is deliberately *not* program 2. Nobody can see or hear
anything during one, and your Mac does it several hundred times a night. It is
this Mac's normal state while showup is waiting:

```
10:32:34  DarkWake   DarkWake from Deep Idle [CDNP] ... 10 secs
10:33:11  DarkWake   DarkWake from Deep Idle [CDNP] ... 10 secs
10:33:48  DarkWake   DarkWake from Deep Idle [CDNP] ... 10 secs
10:34:00  DarkWake   DarkWake from Deep Idle [CDNP] ... 0 secs
10:34:00  Wake       DarkWake to FullWake from Deep Idle [CDNVA] : due to HID Activity
```

Four of them in two minutes, from the sleep test that produced this section.
A manual sleep does not stay asleep: it goes down for 27 seconds, up for 10,
down again, and only settles when the RTC alarm lands.

The last pair is what matters. The RTC alarm reaches the machine as a DarkWake
too, and is promoted to a FullWake only if something — usually a hand — wakes
the user. In that test the promotion was `due to HID Activity`, which was the
person typing their password. It is not guaranteed, and when it does not happen
a ring is a sound in an empty house.

### Asking the kernel, rather than reading a log

The paragraph above is what showup used to do, and reading it should make the
problem obvious: it was deciding whether a person was there by parsing a log
that another process writes asynchronously, on a single occasion, and hoping
the line had landed.

There is an API for this. `IORegisterForSystemPower` is documented to send:

- `kIOMessageSystemWillSleep` "at the point the system is initiating a
  **non-abortable** sleep"
- `kIOMessageSystemHasPoweredOn` "at **wakeup completion** time, after all
  device drivers and hardware have handled the wakeup event"

A DarkWake is abortable and never completes a wake, so it produces neither.
That is the kernel making the distinction directly, and it cannot lose a race
with powerd because it is not powerd. `kIOMessageSystemWillSleep` has to be
acknowledged with `IOAllowPowerChange` — without it the sleep stalls for thirty
seconds, which Apple says outright — and the wake messages must not be.

The notifications arrive on a dispatch queue, because showup blocks in
`Thread.sleep` and nothing is ever going to service a run loop.

So the order is: the kernel decides, and the power log is only consulted if
the kernel would not register at all. showup says which path it took at
startup. Phase one, surfacing the app, happens either way.

Along the way this killed a plausible idea. `kIOPMSleepWakeUUIDKey` is
documented as being removed "at the completion of a system wakeup", which
would have been a registry-property answer with no callback at all. Read
directly on this Mac it is present on a machine that is plainly awake, so it
is not that signal, and it was not used.

### How it knows the difference

The clock cannot say, because a sleeping and a running Mac report the same
time. Neither can the power log, as it turns out — see below.

What answers it is the keyboard idle counter. It runs only while the machine
is up, so it **freezes across a sleep and resumes where it stopped**. Two
readings and the length of the wait settle it:

```
00:37:12  idle = 5.97s     just before the Mac went down
00:43:01  idle = 8.31s     the RTC alarm brought it back, 353s later
```

A machine awake for the whole of that wait would have reached 359. So: if the
idle counter advanced far less than the wall clock did, the machine slept.

The bias is toward ringing. A counter that went *backwards* means input
arrived, so the machine was up and someone was using it. A counter that barely
moved on a machine that never slept looks identical to a freeze, and costs one
ring that stops on the next reading — which is the right trade, because the
alternative is a wake that is theatre. A counter that cannot be read at all is
treated the same way, for the same reason.

`SleepEvidence` in `Sources/ShowupCore/SleepDetection.swift` is that decision,
and it is a pure function of three numbers, so all four cases are tested.

> **Why not `pmset -g log`, which does record every sleep and wake?** It was
> tried, and it fails on a race that cannot be won. The log is written by
> powerd, which has not necessarily recorded our wake by the time we ask — and
> asking is the only moment anyone asks. Reading it the instant the VM resumes
> finds a tail ending at the wake from twenty minutes earlier, with our sleep
> and our wake both missing, and concludes the machine never went down. Three
> nights of real tests produced three silent nights from three different
> causes. The idle counter has no such window.

### Waking early, so the window is punctual

Asking the kernel to wake the Mac *at* the scheduled time would make the app
late every single time: the display would come up, the person would have to be
woken and would have to type a password, and all of that would happen during
the very minute the app was supposed to appear.

So the kernel is asked for the wake **ahead of the time**, and the work is
done inside that window:

| Wake falls at | Lead | Why |
| --- | --- | --- |
| 07:00 – 21:59 | 1 minute | The machine has usually been up for hours, and whoever owns it is at it |
| 22:00 – 06:59 | 5 minutes | The machine is likely asleep, and a person has to be woken and type a password |

On a machine that never went down, whatever is left of the window after the
alarm is slept out, so the window still goes up on the time — a measured run put
TextEdit in front at 10:35:02 against a 10:35:00 target, two seconds, inside
one ten second step.

A wake that is *already* inside its lead — a window starting at 04:00 whose
step began at 03:58:20, say — has no lead left to wake early for. The alarm
moves to the required moment itself rather than being dropped. The lead is a
comfort; being there at all is not. This was measured: with no alarm armed, the
Mac's own idle timer took it down during the wait, nothing in the program could
bring it back, and a 04:00 window went up at 08:58:30.

The window never goes up **before** the required time, whichever program ran —
and that is the only thing in this program which must not be early. The wake
itself is early on purpose: the lead window exists so that the display coming
up, the person waking and the password are all finished before the minute the
app belongs in. An alarm answered at 20:59:30 for a 21:00 window waits the
remaining half minute; a machine that was up the whole time waits out the whole
lead. Late is possible, early is not.

The wait is counted on the machine's own clock, and the loop carries that clock
forward rather than the scheduled time. It matters: a window served a minute
early used to put every later window a minute early too, because the next wait
was measured from the time the window was *aimed* at rather than from where the
machine actually was. A real run put the app up at 20:59:00, 21:59:00,
22:59:00 and 23:54:02 against 21:00, 22:00, 23:00 and 00:00 — four windows,
four minutes early, one after another.

Which timezone this is, is the system's: every moment in this program is read
through `Calendar` on the machine's own setting, followed live, so a Mac that
is carried to another zone is read in that zone from then on. In a zone that
observes daylight saving — mainland China has not observed it since 1991, and
neither do most of the world's zones — the clock is not a clock twice a year:
on the night it ends, 02:00 happens twice; on the night it starts, 02:00 does
not happen at all. Where there is no change, the calendar is a plain calendar
and there is nothing to be right about.

The one thing this program needs from a clock is an answer to "has the required
moment arrived yet", and the machine's own wall clock answers that. Nothing is
accumulated, so there is nothing for midnight or a clock change to get wrong:
the moment is one instant, the calendar said which one it was when the wake was
chosen, and the hold asks the clock how far off it is now.

That form is also the only one that survives the machine going down, which is
the ordinary case rather than an edge. A wait counted in seconds adds the sleep
to itself: the seconds a suspended Mac costs are exactly the seconds the wait
did not get. Measured on this Mac, against `-t 04:00,08:00`:

```
04:16:38  holding the window for 6114s until the required time
09:40:53  about to show Binance
```

The 08:00 window went up one hour and forty minutes late, because the counter
on which that 6114 was measured had stopped for the two hours the Mac was down.
A monotonic clock (`mach_absolute_time`) is the usual answer to "a duration
that does not move when the clock does", and it is the wrong one here for
exactly that reason: it also stops while the Mac is suspended. A wait that
crosses a sleep is the normal case for a program whose purpose is to wake a
sleeping machine. Measured the same way, a 04:00 window went up at 04:16:38 —
late by the tail of a sleep, which is allowed, rather than late by the sleep
and the tail, which is what the count produced.

Both directions of the clock change are tested anyway: two against a timezone
that has the changes (New York, spring and autumn), and two where the wall
clock jumps inside a running hold. Two more run against a zone with no changes
at all (Shanghai, on the same two nights), where the wait is the plain distance
the wall clock says — which is what keeps a later change from quietly assuming
a zone. The `--dry-run` delays are counted the same way, to the instant rather
than between two times of day, for the same reason.

When the Mac had been asleep the app goes up when the ringing stops, which is
later than the target if you are away from the machine and exactly when you
want it if you are not.

## Waking you up

When program 2 runs it rings: it plays the sound macOS makes when a FaceTime
call arrives, and repeats it every five seconds **until a key is pressed on the
keyboard**. That is the only thing that stops it. A ring that stops on its own
is a ring that failed to wake anyone.

The counter is keys only — `CGEventSource.secondsSinceLastEventType` narrowed to
`.keyDown` — because a hand on the keyboard is what answers the alarm, and a
trackpad twitch while nobody is there is not.

The first reading is captured *before* the first ring rather than after, so
that the wake itself, or a `sudo` password typed earlier, cannot be mistaken
for the user answering. (Today's root run; the planned user run has no such
password — see *Where the design is going*.) After that each reading is measured against the one
before it, not against that first one. The counter is back at zero the instant
a key lands and climbs again from there, so a tap sampled a few seconds late
reads as a small number rather than as a fall — and measured against the
original baseline it would have been missed entirely whenever the user had been
recently at the keyboard, which is the case that matters most.

Whether a key has been pressed at all is read from `CGEventSource`. A locked
screen counts as idle, because it produces no key presses either — and the
password being typed at the login window is itself the answer. `--no-ring` turns
the sound off completely.

The speaker is raised before the alarm plays, and only upward: a Mac left
quiet overnight otherwise rings into silence, and the volume somebody chose is
not showup's to lower. Anything at or above 20 is left alone; below it, the
speaker is set to 20. The warning about an inaudible alarm still says what it
says independently, at its own threshold of 30.

There is no ring count. What ends the ringing without a key is this wake
running out of value, on the machine's own evidence:

- **The Mac is due to sleep again.** showup reads the idle timers with
  `pmset -g custom` and gives the alarm that window as its budget — 20 minutes
  on the machine this was written on. A wake is worth what its window is worth:
  by the time the machine is going back down, a wake that has not reached
  anybody has failed, and ringing past that point is ringing at a closed door.
- **The Mac went back to sleep mid-ring.** `Thread.sleep` counts uptime and does
  not advance while the system is suspended, so a five second wait returns far
  later than five seconds in wall clock terms if the machine went down. The
  alarm stops there rather than resuming a stale ring whenever the Mac next
  comes up.

Both hand back to the loop, which goes on to arm the next wake. Neither exists
to be a safety belt; without them the loop would sit parked inside a ring it can
never finish, and tomorrow's wake would never be asked for.

`afplay` cannot play mp3, so a sound of your own would need to be a wav, aiff,
caf or m4a rather than an mp3.

## While the Mac is asleep

`showup` handles Mac sleep correctly. The design is: **let the Mac sleep
naturally, ask the kernel to wake it a little before the time, bring the
machine and its owner back, then let it sleep again**. This section explains
why this works and what the limits are.

### What happens when the Mac sleeps

`showup` times its waits against a **wall clock**, because on macOS a
monotonic clock stops while the system is suspended. A sleep asked for N
seconds therefore returns after N seconds of *uptime* — every second the Mac
spent asleep is added to the wait.

This is not a small effect, and it was the last real bug in the program.
Measured on a genuine overnight wake:

```
01:30:24  sleeping until 01:37:00          396 second sleep
01:31:34  the Mac goes down
01:37:01  the kernel's alarm brings it back — one second before the deadline
01:43:02  the sleep finally returns          five minutes later
```

And measured directly, with the machine asleep for a known interval:

```
  monotonic 150000        what the timer counted
  system    256000        what actually happened
         ^^^^^^ 106 seconds the machine was asleep, and the timer
                 never saw them
```

The machine was awake and running for the last five of those minutes. It
was waiting for a clock that could not see the time it had already lost.

So `showup` never sleeps for long. It sleeps in ten second steps against
the **wall** clock and checks the deadline each time, which bounds the
overshoot to one step — ten seconds — whether the machine slept the whole
way, woke for a moment, or never slept at all.

### The idle window, measured rather than assumed

macOS maintains idle timers that start from the last keyboard, mouse, or
network input, and the moment the Mac wakes — for any reason at all — they are
reset. That reset is what makes a wake work at all, because it buys a window
of awake time for the `open -a`, the `lsappinfo`, the ringing loop, and the
scheduling of the next wake.

How long that window is depends on the machine, and it used to be a guess
here: "a typical laptop is set to sleep after 25–30 minutes". That is right
often enough to be believed and wrong often enough to matter. So `showup` asks
the machine, once at startup:

```
$ pmset -g ps
Now drawing from 'AC Power'
$ pmset -g custom
AC Power:
 displaysleep         20
 sleep                25
 ...
```

The two halves of `pmset -g custom` disagree, and `pmset -g ps` says which one
applies — the same Mac above is set to 10 minutes on battery. The display
timer is the one that matters, because it is the smaller: it is the window in
which anything `showup` does can be seen or heard. So `showup` logs:

```
showup: this Mac sleeps on its own after 20m without input on AC power (displaysleep 20m, sleep 25m)
```

This is the one number that says whether a wake can be completed at all, so
it is read rather than guessed. `PowerSettings` in
`Sources/ShowupCore/PowerSettings.swift` is the parsing, and it is tested
against verbatim `pmset` output from both power sources.

### No power assertion

There is no `caffeinate` call. It was there for a long time and was removed
because nothing demonstrated that it did anything on this machine: the
display state that `-u` is supposed to fix cannot be read back on Apple
Silicon, so the claim it was making was never checkable.

What is left is unprotected, and honestly so. The Mac is woken by `pmset`
and immediately begins work that takes seconds, not minutes. If a short
Power Nap window closes underneath it, that work is suspended and resumes
on the next wake — the loop carries on unchanged, which the sleep evidence
below shows happening for two hours.

The cost is a window that is dark until the user touches something. The
alarm is what closes that gap: it rings until a key is pressed, or until the
window this wake was worth has run out, so the window keeps opening the lead
window back up for as long as the user needs.

### Experimental evidence

A 10-round test was run on macOS 15.1. Each round was: `caffeinate -i -t 30`
(hold 30s, simulate work) followed by a 5-minute sleep with no power
assertion so the Mac could go to sleep. Logged to `/tmp/showup_sleep_test.log`
on 2026-10-18.

**Normal rounds — Mac awake, timer precise:**

```
05:25:45  caffeinate released (held 30s, OK)
05:25:45  going to sleep 5min with NO assertion (Mac CAN sleep)...
05:30:45  woke up from 5min sleep                 ← +5:00.0s exactly
05:30:45  --- ROUND 2/10 START ---
...
05:52:51  going to sleep 5min...
05:52:51  --- ROUND 6/10 START ---
```

**Round 6 → 7 — Mac actually slept:**

```
05:53:22  going to sleep 5min...                  ← expected wake: 05:58:22
07:59:21  woke up from 5min sleep                 ← actual wake: +2h 6min!
07:59:21  --- ROUND 7/10 START ---                ← loop continued seamlessly
```

Sleep log (`pmset -g log`) confirms:

```
2026-10-18 07:43:57  Entering Sleep state due to 'Maintenance Sleep'
                      TCPKeepAlive=active Using Batt (Charge:100%) 914 secs
2026-10-18 07:59:11  Wake from Deep Idle [CDNVA]
                      wake reason: trackpadkeyboard SMC
```

The sleep had been suspended for roughly 126 minutes of real time. When the
Mac woke from user input the sleep returned immediately, the next round fired,
and the program kept running without crash, without restart, without loss of
schedule state.

The final 30-minute idle-sleep + wake-again gap in `showup`'s own design
replaces the 5-minute gap of the test; the mechanism is the same.

### Design implications for future developers

1. **Do not try to catch the exact wall-clock moment inside a sleep.**
   Sleep suspension happens at the kernel level; the timer cannot tick
   during sleep. Treat sleep as "wait at least N seconds, or until the
   system wakes me." Read the clock again after sleep returns — the
   scheduler already does this via `next_instant`.

2. **Do not add a power assertion without a way to check it worked.** One was
   here for most of this program's life, documented at length, and it was
   impossible to verify on this hardware — the property that would show it
   working cannot be read back on Apple Silicon. An assertion you cannot
   check is a claim, and this project has already shipped several.

3. **The `Effects` type is the boundary.** If you port `showup` to another
   runtime or another OS, the two questions you have to answer are what the
   machine was doing while we waited — `idleSeconds`, read twice and decided by
   `sleepEvidence`, with `powerCycle` and `wakeKind` as the other two witnesses
   — and putting the window up, which is `show`. The scheduler core (and its
   tests) never call macOS APIs directly.

4. **The root run is the transit, not the destination.** The nightly run
   currently executes as root, and nearly everything it does past the
   password is identity work: `launchctl asuser` into the console session,
   ownership tags on kernel wakes, a lock and logs on root's ground, an
   `isRunning` check across an identity boundary. The decided redesign
   (`.planning/BRIEF.md` and `.planning/ROADMAP.md`) moves the run to the
   plain user and the wake act to an install-time root renewal daemon —
   retiring that identity layer, not extending it. New work should build on
   that shape rather than deepen the root-run one; window discipline, sleep
   forensics, and the hold-to-moment loop are untouched by it.

## How it works

Surfacing an application is one command that ships with macOS: `open -a <app>`.
It launches the app if it is not running, and if it is, macOS activates it
through LaunchServices, which brings its windows to the front and gives it
focus. No permission needs to be granted for this, in Terminal or anywhere
else.

"To the front" is the whole of what it does. This activates the application;
which of its windows ends up frontmost is the application's own business,
decided the same way it would be if you clicked its icon in the Dock. Choosing
one particular window among several would need the Accessibility API and a
permission grant, and nothing here needs that.

`pmset -g custom` and `pmset -g ps` are read once at startup for the idle
timers; `lsappinfo` is asked whether the app was already running, purely so
it can report `surfaced` or `launched` accurately rather than always claiming
to have launched it. That lookup matches the name exactly, so an app macOS
calls something else, such as System Settings on a version before macOS 13,
would be reported as launched rather than surfaced. Only the wording of that log
line is affected, never what `showup` does.

## Development

```sh
make build                           # swift build, stamped
make test                            # swift test
make release install                 # optimised build, installed to /usr/local/bin with its stamp
swift run showup -a Safari -t 9:00 --dry-run   # run without installing
```

`swift test` runs the suite on [swift-testing](https://github.com/swiftlang/swift-testing),
which is the framework for this toolchain; there is no XCTest anywhere in this
project. One note for running it by hand: this SwiftPM does not load the
swift-testing macro plugin on its own, so `make test` passes the plugin path
explicitly. Under Xcode, or on a toolchain that wires the plugin up, plain
`swift test` is enough.

Changes to the source only reach an installed `showup` by rebuilding and
installing again.

Times of day and delays are Swift's `Int` seconds rather than home grown types,
and sleeping is `Thread.sleep(forTimeInterval:)` stepped in ten second
wall-clock increments.

## What talks to macOS, and how

Almost nothing shells out. Anything with a documented API uses it, because the
API answers and a log parser infers:

| Question | Answered by |
| --- | --- |
| Did the Mac sleep, and did the wake complete? | `IORegisterForSystemPower` |
| Is this wake one somebody can hear? | the same, or the power log if it would not register |
| Who is at the console? | `SCDynamicStoreCopyConsoleUser` |
| Has the login finished? | `scutil show State:/Users/ConsoleUser` |
| How long since anyone touched anything? | `CGEventSource.secondsSinceLastEventType` |
| How long since a key was pressed? | the same, narrowed to `.keyDown` |
| How loud is the speaker? | CoreAudio `kAudioDevicePropertyVolumeScalar`, read and written |
| Wake the Mac at a time | `IOPMSchedulePowerEvent`, taken back with `IOPMCancelScheduledPowerEvent` |

Five things still spawn a process, and each for a stated reason:

- **`pmset -g custom`** — the configured idle timers.
  `IOPSCopyPowerSettingsInfo` and `IOPMCopyCustomPowerProfiles` are not in the
  SDK, so there is no documented way to read them.
- **`scutil show State:/Users/ConsoleUser`** — whether the login has finished.
  The same record `CGSessionCopyCurrentDictionary` returns, read through a
  shell tool because that API needs a window server session and showup runs as
  root without one.
- **`launchctl asuser` + `open -a`** — surfacing an app. `NSWorkspace` and
  `NSRunningApplication` are bound to a window server session, and showup runs
  as root in none. This exists only because the run is root; in the planned
  user-mode path it is dropped in favor of a plain `open -a` (see *Where the
  design is going*), and both paths are kept until then.
- **`lsappinfo info`** — whether an app is already running, for the same reason.
- **`afplay`** — playing a `.caf` file. `AudioServicesPlaySystemSound` takes a
  `SystemSoundID` rather than a path, which is a different thing.

There are no external dependencies beyond the Swift toolchain.

| Module                     | Role                                                       |
| -------------------------- | ---------------------------------------------------------- |
| `Sources/ShowupCore/`      | Pure logic: times, scheduling, lead windows, sleep detection, the alarm, the scheduler loop, and the `Effects` port it talks through, plus the machine's measured idle timers |
| `Sources/ShowupMac/`       | The platform boundary: every command that is run, every parser for its output, and the `Effects.live` that joins them to the core |
| `Sources/showup/`          | The entry point: argument handling, the schedule preview, the help text |
| `Tests/ShowupTests/`       | The whole suite, including the scheduler loop against a fake clock and a fake Mac |

Anything that parses real command output lives in `ShowupMac` rather than in
the executable, so it can be tested against verbatim captured output. That was
not theoretical: `parseUID` once searched for the substring `UID : ` in
`scutil` output, which also matches the tail of
`CGSSessionUniqueSessionUUID : ...`, so it failed on every real input and the
app was never surfaced at all — while all the tests passed, because every one
of them supplied a fake.

Those parsers are now gone, which is the better outcome. `scutil` and `ioreg`
output is no longer read at all, so there is no text left to disagree with
reality. What replaced them is listed above, and `Scripts/root-api-probe.sh`
checks each one as root and as a user, because showup runs as root and an API
that only answers in one of the two is not usable here.

### The log

Today's ground is root's `/var/log`, and this section describes it. Under the
decided redesign (see *Where the design is going*), a user-mode run's ground
becomes `~/Library/Logs/showup` with the same one-per-run naming, the same
`0644`, and the same week rule; the root ground below stays for runs launched
with sudo. Until that lands, it is exactly this:

`/var/log/showup<timestamp>.log`, and nowhere else. One file per run, named for
when it started:

```
showup: logging to /var/log/showup1758290000.log
```
so a single run can be read on its own, nothing grows without bound, and the
directory sorts into the order the runs happened in.

The file is root owned and world readable (`0644`): the log is for whoever has
to read it later, often without root's help, and it is not writable by anybody
but its owner. Each one is kept for a week; the next run deletes anything older,
which it says so in its own log.

Each line carries the time of day it was written, and each wake records the
numbers it was decided from — which idle counter reading, how long the wait was —
so a wake that rang when it should not have can be worked out after the fact
rather than guessed at.

The first line of a run answers the question every post-mortem starts with:
which binary produced it.

```
build 0404c92 2026-10-22 13:53 +0800
```

The line comes from a stamp `make` writes next to the binary, refreshed on every
build, and `make install` installs it beside the binary. A binary not built by
make has no stamp and says so plainly, rather than borrowing the identity of
nothing. Three different binaries wrote logs to this directory in one day, and
defects that the code had already fixed kept being rediscovered in runs made by
code that carried the fix; the stamp is what stops that.

Only one instance runs at a time, and that is decided by the kernel rather than
by attention: `flock` on `/var/log/showup.lock`, held for the life of the
process, released on exit and on death, so a crash leaves no lock behind. A
second run stops and names the first one's pid. Without sudo the lock cannot be
made, which is warned about the same way scheduling cannot be done.

A run killed outright — `kill -9`, or a crash — cannot run its stop handler, so
its RTC wake would stay armed until it fired for nobody. So each run, at
startup and under the lock, takes back every wake still armed under its own
identifier `com.showup.wake` before listing what the kernel holds: a leftover
can only be its own previous life, and the list that follows is the truth after
the clean-up.
The directory is `/var/log` and not `/tmp`, and that is not a style choice.
`showup` runs as root and `/tmp` is world writable, so a file there is a way for
an unprivileged user to decide where a root process writes. `/var/log` is root
owned and the file is opened `O_NOFOLLOW`, so there is nothing there to aim at.

Run without sudo and the file cannot be created; `showup` says so at startup and
carries on writing to the terminal.

There is no setting to move it. A log that is somewhere different on the night
somebody needs to read it is not much of a log.

The `Effects` type is the boundary. If you port `showup` to another runtime or
another OS, the hooks you need are `now`, `currentDate`, `sleep`,
`scheduleWake`, `idleSeconds`, `show`, `alarm`, `outputVolume`,
`setOutputVolume`, `powerSettings`, `wakeKind`, `powerCycle`, `loginFinished`,
`log` and `warn`. The scheduler core (and its tests) never call macOS APIs
directly.
