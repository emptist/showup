# showup

`showup` is a macOS command line tool that brings an application to the
foreground at the times you choose, so you can switch to it without hunting
for it among your windows. If the application is not running yet, it is
launched for you.

```sh
sudo showup -a Safari -t 8:00,12:00,16:00,20:00
```

The `sudo` is needed for exactly one thing: asking the power-management system
to wake the Mac out of sleep, which only root may do. Everything else — reading
the sleep evidence, ringing, surfacing the app — works as your normal user.

`showup` works out when the next of your times is, asks the kernel to wake the
Mac a little before it, and then brings the application to the front. If the
Mac was asleep it rings first, until you answer. It then does the same again for
the next day, and the next, until you stop it with Ctrl-C. A time that has
already passed today waits for tomorrow, so it is safe to leave running.

Start it after you log in and stop it before you log out. It is built for a
session that is always there behind the login window: when the Mac wakes with
the screen locked, your session is still alive, the app is launched into it, and
it is waiting for you the moment you type your password.

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

## Usage

```text
showup -a <app> -t <times> [-n] [-q]

  -a, --app <name>      The application to surface, for example "Safari".
  -t, --times <times>   Comma separated times of day, such as
                        8:00,12:00,16:00,20:00,24:00. A bare hour such as
                        8 means 8:00.
  -n, --dry-run         Print the next few wake times and exit.
  -q, --no-ring         Never make a sound.
  -h, --help            Show the full message.
```

`--no-ring` is worth understanding before you use it. By default `showup`
only ever rings when it had to wake a sleeping Mac — never when the machine was
already up, where you are assumed to be present and looking.

Both `--flag value` and `--flag=value` are accepted, repeated `-t` flags are
combined, and times are sorted and deduplicated.

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
likely sitting at it. Raise the window, and stop. No sound, no waiting, no
ceremony. This is the whole job, and it is the job most wakes want.

**Program 2 — rouse.** The Mac was asleep and this is the wake we asked for.
Ring, until a hand reaches the keyboard and the login window goes away. The
app is launched into the session behind it, so it is in front of you by the
time the password is in.

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

So showup does not trust the label on its own. It knows the instant it asked the
kernel to wake the machine, and a DarkWake *at that instant* is its own wake
whatever powerd chose to call it. The label only suppresses the ring for a
DarkWake that is nowhere near the request — one of the machine's own. Phase one,
surfacing the app, happens either way.

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

Whatever is left of the window after the rousing is slept out, so the window
itself still goes up on the time. On this Mac a 09:00 wake asked the kernel for
08:59, the alarm rang for 17 seconds, and TextEdit came up at 10:35:02 against
a 10:35:00 target: two seconds, inside one ten second step.

## Waking you up

When program 2 runs it rings: it plays the sound macOS makes when a FaceTime
call arrives, and repeats it every five seconds **until the keyboard or mouse
is touched**. It does not give up on its own, because a ring that stops is a
ring that failed to wake anyone. It runs in its own process, so nothing else
waits on it and the only thing that ends it is a hand on the keyboard.

The idle reading is captured *before* the first ring rather than after, so
that the wake itself, or a `sudo` password typed earlier, cannot be mistaken
for the user answering. A ring stops when idle drops *below* that baseline,
meaning new input arrived while the ring was going.

Whether input has been idle at all is read from `ioreg`. A locked screen
counts as idle, because it produces no input either. `--no-ring` turns the
sound off completely.

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

The alarm is the only part of the program that can still do something while
the display is dark, and this number is how long it has. So when it rings,
showup says how long the alarm has to be answered:

```
showup: it has 20m before it sleeps again, so the alarm has to be answered before then
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
alarm is what closes that gap, and it is unbounded: it rings until a hand
reaches the keyboard, so the window keeps opening the lead window back up
for as long as the user needs.

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
   runtime or another OS, the two hooks you need are `slept_during`, which
   reports what the machine was doing while we waited, and `show`, which puts
   the window up. The scheduler core (and its tests) never call macOS APIs
   directly.

## How it works

Surfacing an application is one command that ships with macOS: `open -a <app>`.
It launches the app if it is not running, and if it is, macOS activates it
through LaunchServices, which brings its windows to the front and gives it
focus. No permission needs to be granted for this, in Terminal or anywhere
else.

`pmset -g custom` and `pmset -g ps` are read once at startup for the idle
timers; `lsappinfo` is asked whether the app was already running, purely so
it can report `surfaced` or `launched` accurately rather than always claiming
to have launched it. That lookup matches the name exactly, so an app macOS
calls something else, such as System Settings on a version before macOS 13,
would be reported as launched rather than surfaced. Only the wording of that log
line is affected, never what `showup` does.

## Development

```sh
make build                           # swift build
make test                            # swift test
make release install                 # optimised build, installed to /usr/local/bin
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

All interaction with the outside world goes through Swift's `Foundation`
`Process`, which spawns `open -a`, `lsappinfo`, `ioreg`, `afplay`, `pmset`,
`scutil`, and `osascript`. There are no external dependencies beyond the Swift
toolchain that ships with Xcode / the Command Line Tools.

| Module                     | Role                                                       |
| -------------------------- | ---------------------------------------------------------- |
| `Sources/ShowupCore/`      | Pure logic: times, scheduling, lead windows, sleep detection, the alarm, the scheduler loop, and the `Effects` port it talks through, plus the machine's measured idle timers |
| `Sources/ShowupMac/`       | The platform boundary: every command that is run, every parser for its output, and the `Effects.live` that joins them to the core |
| `Sources/showup/`          | The entry point: argument handling, the schedule preview, the help text |
| `Tests/ShowupTests/`       | The whole suite, including the scheduler loop against a fake clock and a fake Mac |

Anything that parses real command output lives in `ShowupMac` rather than in
the executable, so it can be tested against verbatim captured output, padding
and nesting included. That is not theoretical: `parseUID` once searched for the
substring `UID : ` in `scutil` output, which also matches the tail of
`CGSSessionUniqueSessionUUID : ...`, so it failed on every real input and the
app was never surfaced at all — while all the tests passed, because every one
of them supplied a fake. Both that output and a real `ioreg` report are now
fixtures in `Tests/ShowupTests/ParserTests.swift`.

### The log

`/var/log/showup<timestamp>.log`, and nowhere else. One file per run, named for
when it started:

```
showup: logging to /var/log/showup1758290000.log
```

so a single run can be read on its own, nothing grows without bound, and the
directory sorts into the order the runs happened in. Each line carries the time
of day it was written, and each wake records the numbers it was decided from —
which idle counter reading, how long the wait was — so a wake that rang when it
should not have can be worked out after the fact rather than guessed at.

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
`powerSettings`, `log` and `warn`. The scheduler core (and its tests) never call macOS APIs
directly.
