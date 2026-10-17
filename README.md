# showup

`showup` is a macOS command line tool that brings an application to the
foreground at the times you choose, so you can switch to it without hunting
for it among your windows. If the application is not running yet, it is
launched for you.

```sh
showup -a Safari -t 8:00,12:00,16:00,20:00
```

Every minute, `showup` decides whether the next scheduled time is due. When it
is, the application is activated and, if nobody is actually at the machine, a
phone rings until they are. Times that have already passed today wait for
tomorrow, so the command is safe to leave running.

## Building

The project is written in [Gleam](https://gleam.run) and targets Erlang.

```sh
gleam export escript   # writes a self contained escript named `showup`
```

The resulting `showup` file is self contained, so copying it to somewhere on
your `PATH` is enough to install it.

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

Every wait arms a macOS wake with `pmset schedule wake`, so a time that comes
round while the Mac is asleep still happens: the machine wakes itself, `showup`
surfaces the app, and rings if you are still away.

`pmset` has to run as root for that, and `showup` runs it through
`sudo -n` so an unattended run fails fast rather than hanging on a password
prompt. Until the permission is granted it says so once per wake and carries on
— times still work whenever the Mac is awake, and the times that arrive while
it sleeps are skipped.

To allow it, add one line for your user to a file in `/etc/sudoers.d`:

```
your-user ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake
```

Write it with `sudo visudo -f /etc/sudoers.d/showup`, so a typo cannot lock you
out of `sudo`.

Two things this does not do: it never cancels the schedule, because
`pmset schedule cancel` would also clear the wake times the Clock app has
armed, and a wake will not happen with the lid shut on a MacBook Air.

## How it works

Surfacing an application is one command that ships with macOS: `open -a <app>`.
It launches the app if it is not running, and if it is, macOS activates it
through LaunchServices, which brings its windows to the front and gives it
focus. No permission needs to be granted for this, in Terminal or anywhere
else.

`showup` also asks `lsappinfo` whether the app was already running, purely so it
can report `surfaced` or `launched` accurately. If the app name is not an
exact match for the app's own name, such as `Finder` or `System Settings`, the
answer will be wrong, but only the wording of the log line is affected.

## Development

```sh
gleam run -- -a Safari -t 9:00 --dry-run              # run
gleam test                                           # test
gleam format src test                                # format
```

Times of day and delays are `gleam_time`'s `TimeOfDay` and `Duration` rather
than home grown types, and sleeping is `gleam_erlang`'s `process.sleep`. The
one hand written Erlang module is down to the three things no core library
does: run a program and capture its output, read the command line arguments,
and exit with a status code.

| Module                   | Role                                                  |
| ------------------------ | ----------------------------------------------------- |
| `showup/cli.gleam`       | Reading and validating the command line               |
| `showup/schedule.gleam`  | Times of day, and when the next wake is due           |
| `showup/scheduler.gleam` | The loop, taking its clock and platform calls as arguments |
| `showup/alarm.gleam`     | Ringing until the user is awake                       |
| `showup/power.gleam`     | Arming a macOS wake for the next time                 |
| `showup/macos.gleam`     | Talking to `open`, `lsappinfo`, `ioreg` and `afplay`   |
| `src/showup_erl.erl`     | The three operations no core library offers         |

`scheduler.live_with_alarm` is the only place the real system clock and macOS
are wired in, so the rest of the program is pure and the loop is exercised in
the tests with a fake clock and a fake machine.

Further documentation can be found at <https://showup.hexdocs.pm/>.
