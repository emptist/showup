import gleam/io
import gleam/list
import gleam/time/duration.{type Duration}
import intime/cli
import intime/schedule
import intime/scheduler

/// How many wake times `--dry-run` prints.
const preview_count: Int = 5

/// Exit status used when the command line could not be understood.
const usage_status: Int = 2

@external(erlang, "intime_erl", "arguments")
fn arguments() -> List(String)

@external(erlang, "intime_erl", "halt")
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
  config.times
  |> schedule.upcoming(from: now(), count: preview_count)
  |> list.each(fn(wake) {
    io.println(
      "  "
      <> schedule.to_string(wake.at)
      <> "  in "
      <> scheduler.describe_delay(wake.delay),
    )
  })
}

fn now() -> Duration {
  let effects = scheduler.live()
  effects.now()
}
