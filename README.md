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

Every wait asks macOS to wake the machine for the next time, with
`pmset schedule wake`, so a time that comes round while it is asleep still
happens: the machine wakes itself, `showup` surfaces the app, and rings if you
are still away.

`pmset` has to run as root, and `showup` never asks for a password. Until you
allow it, times that arrive while the Mac is asleep are skipped, and `showup`
says so at each wake. Times work as normal whenever the Mac is awake.

To allow it:

1. Find your username:

   ```sh
   whoami
   ```

2. Write one line in a file of its own under `/etc/sudoers.d`, with your own
   username where `<you>` is:

   ```
   <you> ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake
   ```

3. Install that file through `visudo`, so a typo cannot lock you out of `sudo`:

   ```sh
   sudo visudo -f /etc/sudoers.d/showup
   ```

That grants `showup` one passwordless root command and nothing else. To take it
away again, delete that file.

Two things it will not do. It never cancels the schedule, because
`pmset schedule cancel` would also clear the wake times the Clock app has
armed. And a wake will not happen with the lid shut on a MacBook Air, so an
overnight alarm needs the lid open.

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
