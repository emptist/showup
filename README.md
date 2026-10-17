# showup

`showup` is a macOS command line tool that brings an application to the
foreground at the times you choose, so you can switch to it without hunting
for it among your windows. If the application is not running yet, it is
launched for you.

```sh
showup -a Safari -t 8:00,12:00,16:00,20:00
```

Every minute, `showup` decides whether the next scheduled time is due. When it
is, the application is activated and raised. Times that have already passed
today wait for tomorrow, so the command is safe to leave running.

## Building

The project is written in [Gleam](https://gleam.run) and targets Erlang.

```sh
gleam export escript   # writes a self contained escript named `showup`
```

The resulting `showup` file is self contained, so copying it to somewhere on
your `PATH` is enough to install it.

## Usage

```text
showup -a <app> -t <times> [-n]

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

```sh
showup --app="Slack" --times="9,17"   # 09:00 and 17:00 every day
showup -a Mail -t 24:00               # midnight
showup -a Mail -t 9:00 --dry-run      # show the plan without waiting
showup -a Mail -t 9:00 --no-ring      # never make a sound
```

## Waking you up

Bringing a window to the front does nothing to someone who is asleep at the
keyboard, so by default each wake also rings: it plays the ringback tone macOS
uses when a phone rings, then repeats it every ten seconds until the keyboard or
mouse is touched, giving up after six rings.

It only makes that noise if nobody has touched anything for two minutes, since
someone already sitting there does not need waking. Whether they are there is
read from `ioreg`, which reports how long the keyboard and mouse have been idle;
a locked screen counts as idle, because it produces no input either. `--no-ring`
turns the sound off.

`afplay` cannot play mp3, so a sound of your own would need to be a wav, aiff,
caf or m4a rather than an mp3.

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
than home grown types.

| Module                   | Role                                                  |
| ------------------------ | ----------------------------------------------------- |
| `showup/cli.gleam`       | Reading and validating the command line               |
| `showup/schedule.gleam`  | Times of day, and when the next wake is due           |
| `showup/scheduler.gleam` | The loop, taking its clock and platform calls as arguments |
| `showup/macos.gleam`     | Talking to `open` and `lsappinfo`                     |
| `src/showup_erl.erl`     | The few operations that need Erlang                  |

`scheduler.live` is the only place the real system clock and macOS are wired
in, so the rest of the program is pure and the loop is exercised in the tests
with a fake clock.

Further documentation can be found at <https://showup.hexdocs.pm/>.
