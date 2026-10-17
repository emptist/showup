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
  -h, --help            Show the full message.
```

Both `--flag value` and `--flag=value` are accepted, repeated `-t` flags are
combined, and times are sorted and deduplicated.

```sh
showup --app="Slack" --times="9,17"   # 09:00 and 17:00 every day
showup -a Mail -t 24:00               # midnight
showup -a Mail -t 9:00 --dry-run      # show the plan without waiting
```

## How it works

Surfacing an application is done with two tools that ship with macOS:

- `open -a <app>` launches the application if it is not running and activates
  it if it is.
- An AppleScript that asks System Events to set the application's process to
  the frontmost one, which raises its window above the others.

The first step always works. The second needs the program running `showup` to
be allowed to control your computer, so if it does not work, grant
Accessibility permission to it in
*System Settings > Privacy & Security > Accessibility*. When the permission is
missing, `showup` still activates the application and warns you once per wake
time rather than failing silently.

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
| `showup/macos.gleam`     | Talking to `open` and AppleScript                     |
| `src/showup_erl.erl`     | The few operations that need Erlang                  |

`scheduler.live` is the only place the real system clock and macOS are wired
in, so the rest of the program is pure and the loop is exercised in the tests
with a fake clock.

Further documentation can be found at <https://showup.hexdocs.pm/>.
