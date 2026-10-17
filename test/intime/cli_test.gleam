import gleam/int
import gleam/list
import gleam/string
import gleam/time/calendar.{type TimeOfDay}
import gleeunit
import gleeunit/should
import intime/cli
import intime/schedule

pub fn main() -> Nil {
  gleeunit.main()
}

fn at(hours: Int, minutes: Int) -> TimeOfDay {
  let assert Ok(parsed) =
    schedule.parse(int.to_string(hours) <> ":" <> int.to_string(minutes))
  parsed
}

fn show(config: cli.Config) -> cli.Command {
  cli.Show(config: config)
}

fn parse(argv: List(String)) -> Result(cli.Command, cli.Error) {
  cli.parse(argv)
}

pub fn parses_the_documented_example_test() {
  parse(["-a", "Safari", "-t", "8:00,12:00,16:00,20:00"])
  |> should.equal(
    Ok(
      show(cli.Config(
        app: "Safari",
        times: [at(8, 0), at(12, 0), at(16, 0), at(20, 0)],
        dry_run: False,
      )),
    ),
  )
}

pub fn parses_long_flags_test() {
  parse(["--app", "Mail", "--times", "9:00"])
  |> should.equal(
    Ok(show(cli.Config(app: "Mail", times: [at(9, 0)], dry_run: False))),
  )
}

pub fn parses_flags_with_equals_test() {
  parse(["--app=Slack", "--times=9,17"])
  |> should.equal(
    Ok(
      show(cli.Config(
        app: "Slack",
        times: [at(9, 0), at(17, 0)],
        dry_run: False,
      )),
    ),
  )
}

pub fn parses_the_dry_run_flag_test() {
  parse(["-a", "Mail", "-t", "9", "-n"])
  |> should.equal(
    Ok(
      cli.ShowSchedule(config: cli.Config(
        app: "Mail",
        times: [at(9, 0)],
        dry_run: True,
      )),
    ),
  )
}

pub fn collects_repeated_time_flags_test() {
  parse(["-a", "Mail", "-t", "9", "--times", "17"])
  |> should.equal(
    Ok(
      show(cli.Config(app: "Mail", times: [at(9, 0), at(17, 0)], dry_run: False)),
    ),
  )
}

pub fn sorts_and_deduplicates_times_test() {
  parse(["-a", "Mail", "-t", "17:00,9:00,17:00"])
  |> should.equal(
    Ok(
      show(cli.Config(app: "Mail", times: [at(9, 0), at(17, 0)], dry_run: False)),
    ),
  )
}

pub fn accepts_an_app_name_with_spaces_test() {
  parse(["-a", "  System Settings  ", "-t", "9"])
  |> should.equal(
    Ok(
      show(cli.Config(app: "System Settings", times: [at(9, 0)], dry_run: False)),
    ),
  )
}

pub fn parses_help_test() {
  parse(["--help"]) |> should.equal(Ok(cli.Help))
}

pub fn parses_help_among_other_flags_test() {
  parse(["-a", "Mail", "-h"]) |> should.equal(Ok(cli.Help))
}

pub fn reports_a_missing_app_test() {
  parse(["-t", "9:00"]) |> should.equal(Error(cli.MissingApp))
}

pub fn reports_a_missing_time_list_test() {
  parse(["-a", "Mail"]) |> should.equal(Error(cli.NoTimesGiven))
}

pub fn reports_an_empty_app_name_test() {
  parse(["-a", "   ", "-t", "9:00"]) |> should.equal(Error(cli.EmptyApp))
}

pub fn reports_an_app_name_that_cannot_be_used_test() {
  parse(["-a", "Ma\"il", "-t", "9:00"])
  |> should.equal(Error(cli.InvalidAppName("Ma\"il")))
}

pub fn reports_an_unparsable_time_test() {
  parse(["-a", "Mail", "-t", "half past nine"])
  |> should.equal(Error(cli.InvalidTime(schedule.Malformed("half past nine"))))
}

pub fn reports_a_flag_without_a_value_test() {
  parse(["-a", "Mail", "-t"]) |> should.equal(Error(cli.MissingValue("-t")))
}

pub fn reports_an_unknown_argument_test() {
  parse(["--lunch", "12:00"])
  |> should.equal(Error(cli.UnknownArgument("--lunch")))
}

pub fn usage_mentions_every_flag_test() {
  let usage = cli.usage()
  list.all(["-a, --app", "-t, --times", "--dry-run", "--help"], fn(flag) {
    string.contains(usage, flag)
  })
  |> should.be_true
}

pub fn describes_every_error_test() {
  let errors = [
    cli.MissingApp,
    cli.EmptyApp,
    cli.InvalidAppName("Ma\"il"),
    cli.NoTimesGiven,
    cli.InvalidTime(schedule.Malformed("noon")),
    cli.MissingValue("-t"),
    cli.UnknownArgument("--lunch"),
  ]
  errors
  |> list.map(cli.error_message)
  |> list.all(fn(message) { string.length(message) > 0 })
  |> should.be_true
}
