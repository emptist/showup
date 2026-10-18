# showup

`showup` is a macOS command line tool that brings an application to the
foreground at the times you choose, so you can switch to it without hunting
for it among your windows. If the application is not running yet, it is
launched for you.

```sh
sudo showup -a Safari -t 8:00,12:00,16:00,20:00
```

The `sudo` is not optional. `showup` asks the power-management system to wake
the Mac out of sleep, and only root may do that.

`showup` works out when the next of your times is, asks the kernel to wake the
Mac a little before it, and then brings the application to the front. If the
Mac was asleep it also rings, and waits for you to log in if it has to. It then
does the same again for the next day, and the next, until you stop it with
Ctrl-C. A time that has already passed today waits for tomorrow, so it is safe
to leave running.

## Building

The project is written in [Gleam](https://gleam.run) and targets Erlang.

```sh
gleam export escript   # writes a self contained escript named `showup`
```

That writes a `showup` file in the project directory, which is not tracked by
git. It is self contained, so putting it somewhere on your `PATH` installs it:

```sh
install -m 0755 showup /usr/local/bin/showup
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
Take the display off sleep, ring, and wait for the login window if there is
one. Only then hand over to program 1.

A `DarkWake` — the machine coming up for network and mail maintenance with
the screen still off — is deliberately *not* program 2. Nobody can see or hear
anything during one, and your Mac does it several hundred times a night.

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
alternative is a wake that is theatre.

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
| 22:00 – 06:59 | 5 minutes | The machine is likely asleep, and a person has to be woken and may have to log in |

Whatever is left of the window after the rousing is slept out, so the window
itself still goes up on the time. The five minute lead has to cover the login
poll on its own — 120 seconds — before any ringing is counted at all.

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

Erlang times `process.sleep` against a **monotonic** clock, and on macOS
that clock stops while the system is suspended. A sleep of N seconds
therefore returns after N seconds of *uptime* — every second the Mac spent
asleep is added to the wait.

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
$ erl -noshell -eval 'A=erlang:monotonic_time(millisecond),
    B=erlang:system_time(millisecond), timer:sleep(150000), ...'

  monotonic 150000        what Erlang's timer counted
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

### Why the idle timer gives us a safe window

macOS maintains an idle timer that starts from the last keyboard, mouse,
or network input. A typical laptop is set to sleep after 25–30 minutes of
idle. The moment the Mac wakes — for any reason at all — that timer is
reset. So there is roughly half an hour of guaranteed awake time for the
`open -a`, `lsappinfo`, ringing loop, and the next `process.sleep` to be
scheduled before the Mac could possibly nod off again.

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
(hold 30s, simulate work) followed by `process.sleep(5min)` with no power
assertion so the Mac could go to sleep. Logged to `/tmp/gleam_sleep_test.log`
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

The process.sleep had been suspended for roughly 126 minutes of real
time. When the Mac woke from user input the sleep returned immediately,
the next round fired, and the Erlang VM kept running without crash,
without restart, without loss of schedule state.

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

`showup` also asks `lsappinfo` whether the app was already running, purely so
it can report `surfaced` or `launched` accurately rather than always claiming
to have launched it. That lookup matches the name exactly, so an app macOS
calls something else, such as System Settings on a version before macOS 13,
would be reported as launched rather than surfaced. Only the wording of that log
line is affected, never what `showup` does.

## Development

```sh
gleam run -- -a Safari -t 9:00 --dry-run              # run
gleam test                                           # test
gleam format src test                                # format
```

Changes to the source only reach an installed `showup` by exporting and
installing again, because `gleam test` and `gleam run` use the build in
`build/` and leave `/usr/local/bin/showup` alone:

```sh
gleam export escript && install -m 0755 showup /usr/local/bin/showup
```

Times of day and delays are `gleam_time`'s `TimeOfDay` and `Duration` rather
than home grown types, and sleeping is `gleam_erlang`'s `process.sleep`.

All interaction with the outside world goes through well-known Hex packages:

| Package          | Used for                                    |
| ---------------- | ------------------------------------------- |
| `argv`           | Reading command line arguments              |
| `child_process`  | Spawning `open -a`, `lsappinfo`, `ioreg`, `afplay`, `pmset`, `scutil` |
| `gleam_time`     | Time-of-day and duration types              |
| `gleam_erlang`   | `process.sleep`, Erlang VM bindings         |

There is **no handwritten Erlang** anywhere in this project. Everything the
program needs — reading args, spawning processes, reading clock time — is
provided by a community package. The only `@external` declaration is a one-line
call to Erlang's built-in `erlang:halt/1` for clean exit, which does not
require any `.erl` source file.

> Why use community packages instead of writing Erlang FFI? Gleam's standard
> library is deliberately small and excludes platform-specific functionality
> such as process spawning and command-line argument parsing. A common mistake
> when Gleam was newer was to hand-write a small Erlang module for these
> tasks; the ecosystem has now matured and the packages above are the
> recommended approach per the [Gleam official guide](https://gleam.run/writing-gleam/).
> Try `packages.gleam.run` before reaching for a custom `@external`.

| Module                   | Role                                                       |
| ------------------------ | ---------------------------------------------------------- |
| `showup/cli.gleam`       | Reading and validating the command line                    |
| `showup/schedule.gleam`  | Times of day, and when the next wake is due                |
| `showup/scheduler.gleam` | The loop, taking its clock and platform calls as arguments |
| `showup/alarm.gleam`     | Ringing until the user is awake                            |
| `showup/macos.gleam`     | `open -a`, `lsappinfo`, `ioreg`, `afplay`, `pmset`, `scutil`, and the log file |

The parsers in `macos.gleam` are the fragile part and the part that has actually
broken. `parse_uid` once searched for the substring `UID : ` in `scutil`
output, which also matches the tail of `CGSSessionUniqueSessionUUID : ...`, so it
failed on every real input and the app was never surfaced at all — while all 78
tests passed, because every one of them supplied a fake. Anything that parses
real command output here should be tested against verbatim real output, padding
and tabs included, not only through `Effects`.

`scheduler.live` is the only place the real system clock and macOS are wired in,
so the rest of the program is pure and the loop is exercised in the tests with a
fake clock and a fake machine.
