import gleam/io
import gleam/list
import gleam/time/duration.{type Duration}
import showup/cli
import showup/schedule
import showup/scheduler

/// How many wake times `--dry-run` prints.
const preview_count: Int = 5

/// Exit status used when the command line could not be understood.
const usage_status: Int = 2

@external(erlang, "showup_erl", "arguments")
fn arguments() -> List(String)

@external(erlang, "showup_erl", "halt")
fn halt(status: Int) -> Nil

pub fn main() -> Nil {
  case cli.parse(arguments()) {
    Error(error) -> {
      io.println_error("showup: " <> cli.error_message(error))
      io.println_error("")
      io.println_error(cli.usage())
      halt(usage_status)
    }
    Ok(cli.Help) -> io.println(cli.usage())
    Ok(cli.ShowSchedule(config: config)) -> print_schedule(config)
    Ok(cli.Show(config: cli.Config(app: app, times: times, dry_run: _))) ->
      scheduler.run(app, times, scheduler.live())
  }
}

fn print_schedule(config: cli.Config) -> Nil {
  io.println("showup will surface " <> config.app <> " at:")
  // Only the first delay is measured from now, the rest are measured from the
  // wake before them, so saying so avoids reading "20:00 4h later" as four
  // hours from the moment the command was run.
  case schedule.upcoming(config.times, from: now(), count: preview_count) {
    [] -> Nil
    [first, ..rest] -> {
      io.println("  " <> at(first) <> "  in " <> delay(first))
      list.each(rest, fn(wake) {
        io.println("  " <> at(wake) <> "  " <> delay(wake) <> " later")
      })
    }
  }
}

fn at(wake: schedule.Wake) -> String {
  schedule.to_string(wake.at)
}

fn delay(wake: schedule.Wake) -> String {
  scheduler.describe_delay(wake.delay)
}

fn now() -> Duration {
  let effects = scheduler.live()
  effects.now()
}
