# showup

`showup` is a macOS command line tool that brings an application to the
foreground at the times you choose, so you can switch to it without hunting
for it among your windows. If the application is not running yet, it is
launched for you.

```sh
showup -a Safari -t 8:00,12:00,16:00,20:00
```

`showup` works out when the next of your times is, sleeps until then, brings
the application to the front, and rings if nobody is actually at the machine. It
then does the same again for the next day, and the next, until you stop it with
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
  -q, --no-ring         Never make a sound, even when nobody is there.
  -h, --help            Show the full message.
```

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

## Waking you up

Bringing a window to the front does nothing to someone who is asleep at the
keyboard, so by default each wake also rings: it plays the sound macOS makes
when a FaceTime call arrives, then repeats it every five seconds until the
keyboard or mouse is touched, giving up after six rings.

It only makes that noise if nobody has touched anything for two minutes, since
someone already sitting there does not need waking. Whether they are there is
read from `ioreg`, which reports how long the keyboard and mouse have been idle;
a locked screen counts as idle, because it produces no input either. `--no-ring`
turns the sound off.

`afplay` cannot play mp3, so a sound of your own would need to be a wav, aiff,
caf or m4a rather than an mp3.

## While the Mac is asleep

`showup` handles Mac sleep correctly. The design is: **let the Mac sleep
naturally, start a brief power assertion right before surfacing, then let
the Mac sleep again**. This section explains why this works and what the
limits are.

### What happens when the Mac sleeps

Erlang's `process.sleep(N)` — which is what `showup` uses — is a pure CPU
blocking call. When macOS enters idle sleep every user-space process is
suspended, so the sleep timer ticks no faster than wall clock does. A wake
time that falls while the Mac is asleep does not fire at the scheduled
second.

But when macOS wakes the machine — whether from a user interaction, a
network packet, or its own Power Nap schedule — the Erlang VM resumes
execution from where it was suspended. `process.sleep` measures against
wall clock, so it immediately returns if enough real time has passed. The
scheduler then surfaces the app and continues the loop.

### Why the idle timer gives us a safe window

macOS maintains an idle timer that starts from the last keyboard, mouse,
or network input. A typical laptop is set to sleep after 25–30 minutes of
idle. The moment the Mac wakes — for any reason at all — that timer is
reset. So there is roughly half an hour of guaranteed awake time for the
`open -a`, `lsappinfo`, ringing loop, and the next `process.sleep` to be
scheduled before the Mac could possibly nod off again.

### Why we still call `caffeinate`

Even with the 30-minute idle window, a brief power assertion is cheap
insurance. If the Mac was woken for a Power Nap maintenance window that
lasts only 10–30 seconds, and the scheduler runs right at the tail end of
that window, the assertion ensures `open -a` and the alarm finish before
the Mac goes back to sleep. The assertion is started immediately after
the long sleep returns and held for 90 seconds — enough for all real
work to complete, after which it exits by itself. The Mac can fall back
to sleep then.

The call is `caffeinate -i -t 90 &` launched through `/bin/sh` — the `&`
makes it fire-and-forget so the Gleam caller does not block waiting for
it to finish, and `-t 90` means it exits cleanly after 90 seconds with
no PID tracking or manual kill needed.

### When the assertion is useful versus when it is redundant

| Scenario                     | caffeinate needed? | Reason                                              |
| ---------------------------- | ------------------ | --------------------------------------------------- |
| Deep idle sleep → user wakes | No (30 min headroom) | Idle timer reset on wake                            |
| Deep idle sleep → Power Nap  | **Yes**            | Wake window may be short; assertion bridges the gap |
| Already awake, normal timing | No                 | `open -a` takes milliseconds                        |
| Wake while on battery        | No difference      | Same mechanism either way                           |

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

2. **Do not hold a power assertion for the entire cycle.** The 30-minute
   idle window after each wake is already the natural buffer. Holding
   `caffeinate -i` continuously would defeat the whole point of letting
   the Mac sleep and costs battery, heat, and wear.

3. **`caffeinate -i -t N &` through `/bin/sh` is the correct pattern.**
   `caffeinate -i -w <pid>` ties the assertion to a specific process and
   requires correct ownership; `caffeinate -i -t N` + `&` in a shell is
   simpler — the timeout is a hard stop, and orphaned caffeinate processes
   from a crashed parent will exit after the same timeout anyway.

4. **The `Effects` type is the boundary.** If you port `showup` to another
   runtime or another OS, `keep_awake` is the only hook you need. The
   scheduler core (and its tests) never call macOS APIs directly.

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
than home grown types, and sleeping is `gleam_erlang`'s `process.sleep`. The
one hand written Erlang module is down to the three things no core library
does: run a program and capture its output, read the command line arguments,
and exit with a status code.

| Module                   | Role                                                       |
| ------------------------ | ---------------------------------------------------------- |
| `showup/cli.gleam`       | Reading and validating the command line                    |
| `showup/schedule.gleam`  | Times of day, and when the next wake is due                |
| `showup/scheduler.gleam` | The loop, taking its clock and platform calls as arguments |
| `showup/alarm.gleam`     | Ringing until the user is awake                            |
| `showup/macos.gleam`     | `open -a`, `lsappinfo`, `ioreg`, `afplay`, and `caffeinate`|
| `src/showup_erl.erl`     | Run programs, read args, exit with a status code           |

`scheduler.live` is the only place the real system clock and macOS are wired in,
so the rest of the program is pure and the loop is exercised in the tests with a
fake clock and a fake machine.
