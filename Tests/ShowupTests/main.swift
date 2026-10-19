import Foundation
import ShowupCore

var failures = 0

func check<T: Equatable>(_ actual: T, _ expected: T, _ name: String, file: String = #file, line: Int = #line) {
    if actual != expected {
        failures += 1
        print("FAIL \(name): \(actual) != \(expected)  (\(file):\(line))")
    } else {
        print("ok   \(name)")
    }
}

// MARK: - Test doubles

final class TestAlarmEffects: AlarmEffects {
    let idle: Int
    let playResult: Result<Void, String>
    var playCount = 0
    var sleepCount = 0

    init(idle: Int, playResult: Result<Void, String>) {
        self.idle = idle
        self.playResult = playResult
    }

    var idleSeconds: () -> Int { { self.idle } }
    var play: (String) -> Result<Void, String> { { _ in self.playCount += 1; return self.playResult } }
    var sleep: (Int) -> Void { { _ in self.sleepCount += 1 } }
}

// MARK: - Time parsing

check(try parseTime("8").get(), TimeOfDay(hour: 8, minute: 0), "parses a bare hour")
check(try parseTime("08").get(), TimeOfDay(hour: 8, minute: 0), "parses a padded hour")
check(try parseTime("08:30").get(), TimeOfDay(hour: 8, minute: 30), "parses a full time")
check(try parseTime("8:05").get(), TimeOfDay(hour: 8, minute: 5), "parses single-digit minute")
check(try parseTime("0:00").get(), TimeOfDay(hour: 0, minute: 0), "parses midnight")
check(try parseTime("24:00").get(), TimeOfDay(hour: 0, minute: 0), "reads end of day as midnight")

if case .failure("hourOutOfRange") = parseTime("24:30") { print("ok   rejects hour past end of day") } else { failures += 1; print("FAIL rejects hour past end of day") }
if case .failure("hourOutOfRange") = parseTime("25:00") { print("ok   rejects hour too large") } else { failures += 1; print("FAIL rejects hour too large") }
if case .failure("minuteOutOfRange") = parseTime("8:60") { print("ok   rejects minutes too large") } else { failures += 1; print("FAIL rejects minutes too large") }
if case .failure("malformed") = parseTime("noon") { print("ok   rejects text") } else { failures += 1; print("FAIL rejects text") }
if case .failure("malformed") = parseTime("") { print("ok   rejects empty") } else { failures += 1; print("FAIL rejects empty") }
if case .failure("malformed") = parseTime("8:00:00") { print("ok   rejects extra colons") } else { failures += 1; print("FAIL rejects extra colons") }

// MARK: - Time list parsing

check(try parseTimeList("8:00,12:00,20:00").get(),
      [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 12, minute: 0), TimeOfDay(hour: 20, minute: 0)],
      "parses a list of times")

check(try parseTimeList(" 8:00 , 12:00 ").get(),
      [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 12, minute: 0)],
      "ignores spaces around times")

if case .failure("noTimesGiven") = parseTimeList("   ") { print("ok   rejects empty list") } else { failures += 1; print("FAIL rejects empty list") }
if case .failure("malformed") = parseTimeList("8:00,") { print("ok   rejects empty item") } else { failures += 1; print("FAIL rejects empty item") }

// MARK: - Normalise

let input = [
    TimeOfDay(hour: 20, minute: 0),
    TimeOfDay(hour: 8, minute: 0),
    TimeOfDay(hour: 20, minute: 0),
    TimeOfDay(hour: 12, minute: 0),
]
check(normalise(input).map { $0.rendered() }, ["08:00", "12:00", "20:00"], "sorts times and removes repeats")

// MARK: - Next wake

let noon = TimeOfDay(hour: 12, minute: 0)
let nine = TimeOfDay(hour: 9, minute: 0)
let eight = TimeOfDay(hour: 8, minute: 0)
let seven = TimeOfDay(hour: 7, minute: 0)
let twenty = TimeOfDay(hour: 20, minute: 0)

check(
    nextWake([twenty, eight, noon], from: nine.secondsSinceMidnight),
    Wake(at: noon, delay: 3 * 3600),
    "picks the soonest time today"
)

check(
    nextWake([eight], from: nine.secondsSinceMidnight),
    Wake(at: eight, delay: 23 * 3600),
    "wraps to tomorrow when the time has passed"
)

check(
    nextWake([noon], from: noon.secondsSinceMidnight),
    Wake(at: noon, delay: 86_400),
    "waits a whole day when the time is now"
)

check(
    nextWake([TimeOfDay(hour: 0, minute: 0)], from: TimeOfDay(hour: 23, minute: 0).secondsSinceMidnight),
    Wake(at: TimeOfDay(hour: 0, minute: 0), delay: 3600),
    "treats midnight as later today"
)

check(nextWake([], from: nine.secondsSinceMidnight) == nil, true, "has no next time without times")

// MARK: - Upcoming

let times1 = [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 12, minute: 0), TimeOfDay(hour: 20, minute: 0)]
let wakes1 = upcoming(times1, from: seven.secondsSinceMidnight, count: 4)
check(wakes1.map { $0.at.rendered() }, ["08:00", "12:00", "20:00", "08:00"], "lists the next wakes in order")

let times2 = [TimeOfDay(hour: 12, minute: 0), TimeOfDay(hour: 20, minute: 0)]
let wakes2 = upcoming(times2, from: nine.secondsSinceMidnight, count: 4)
let rendered2 = wakes2.map { $0.at.rendered() }
let delays2 = wakes2.map { $0.delay }
check(rendered2, ["12:00", "20:00", "12:00", "20:00"], "keeps repeating over several days (times)")
check(delays2, [3 * 3600, 8 * 3600, 16 * 3600, 8 * 3600], "keeps repeating over several days (delays)")

check(upcoming([TimeOfDay(hour: 8, minute: 0)], from: 0, count: 0) == [], true, "lists nothing when asked for nothing")

// MARK: - Lead window

let ls1 = leadSplit(delaySeconds: 3 * 3600, leadSeconds: 300)
check(ls1.ahead, 3 * 3600 - 300, "asks kernel to wake two minutes early (ahead)")
check(ls1.remaining, 300, "asks kernel to wake two minutes early (remaining)")
let ls2 = leadSplit(delaySeconds: 40, leadSeconds: 300)
check(ls2.ahead, 40, "leaves a wake with no lead window whole (ahead)")
check(ls2.remaining, 0, "leaves a wake with no lead window whole (remaining)")
let ls3 = leadSplit(delaySeconds: 300, leadSeconds: 300)
check(ls3.ahead, 0, "an exact lead length wake is all lead (ahead)")
check(ls3.remaining, 300, "an exact lead length wake is all lead (remaining)")

check(leadFor(hour: 9), 60, "a morning wake gets a minute's lead")
check(leadFor(hour: 16), 60, "an afternoon wake gets a minute's lead")
check(leadFor(hour: 22), 300, "an evening wake gets five minutes")
check(leadFor(hour: 2), 300, "a small hours wake gets five minutes")
check(leadFor(hour: 7), 60, "a seven o'clock wake is treated as day")
check(leadFor(hour: 0), 300, "a ten past midnight wake gets five minutes")

// MARK: - Seconds between

check(secondsBetween(23 * 3600 + 55 * 60, 2 * 60), 7 * 60, "seconds between round the clock")

// MARK: - Next instant / resync

let planned = noon.secondsSinceMidnight
check(nextInstant(planned: planned, delay: 86_400, now: planned + 2), planned + 86_400, "keeps the planned instant after a slow wake")

let target = noon.secondsSinceMidnight + 86_400
let now = target + 90 * 60
check(nextInstant(planned: planned, delay: 86_400, now: now), now, "gives up on the plan after missing a wake")

// MARK: - Sleep detection

let sleepLine = "2026-10-19 00:53:02 +0800 Sleep               \tEntering Sleep state due to 'Software Sleep pid=660' 359 secs  "

check(sleptIn(sleepLine, started: TimeOfDay(hour: 0, minute: 52).secondsSinceMidnight, elapsed: 370), true, "a sleep inside the wait is found")
check(sleptIn(sleepLine, started: TimeOfDay(hour: 1, minute: 4).secondsSinceMidnight, elapsed: 94), false, "a sleep before the wait began is not ours")
check(sleptIn(sleepLine, started: TimeOfDay(hour: 0, minute: 52).secondsSinceMidnight, elapsed: 11), false, "a sleep just after the wait ended is not ours")
check(sleptIn("", started: 0, elapsed: 3600), false, "a log with no sleep at all is not ours")

let midnightLine = "2026-10-19 00:02:10 +0800 Sleep               \tEntering Sleep state due to 'Software Sleep pid=660'"
check(sleptIn(midnightLine, started: TimeOfDay(hour: 23, minute: 55).secondsSinceMidnight, elapsed: 900), true, "a wait across midnight still finds its sleep")

// MARK: - Clock & delay rendering

check(clock(3 * 3600 + 5 * 60 + 7), "03:05:07", "clock renders HH:MM:SS")
check(describeDelay(0), "0s", "describe delay 0s")
check(describeDelay(9), "9s", "describe delay seconds")
check(describeDelay(5 * 60 + 3), "5m 3s", "describe delay minutes and seconds")
check(describeDelay(3600 + 5 * 60), "1h 5m", "describe delay hours and minutes")
check(describeDelay(3 * 3600), "3h", "describe delay hours only")

// MARK: - CLI parsing

check(
    parseCLI(["-a", "Safari", "-t", "8:00,12:00,16:00,20:00"]),
    .success(.show(Config(
        app: "Safari",
        times: [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 12, minute: 0), TimeOfDay(hour: 16, minute: 0), TimeOfDay(hour: 20, minute: 0)],
        ring: true, dryRun: false
    ))),
    "parses the documented example"
)

check(
    parseCLI(["--app", "Mail", "--times", "9:00"]),
    .success(.show(Config(app: "Mail", times: [TimeOfDay(hour: 9, minute: 0)], ring: true, dryRun: false))),
    "parses long flags"
)

check(
    parseCLI(["--app=Slack", "--times=9,17"]),
    .success(.show(Config(app: "Slack", times: [TimeOfDay(hour: 9, minute: 0), TimeOfDay(hour: 17, minute: 0)], ring: true, dryRun: false))),
    "parses flags with equals"
)

check(
    parseCLI(["-a", "Mail", "-t", "9", "-n"]),
    .success(.showSchedule(Config(app: "Mail", times: [TimeOfDay(hour: 9, minute: 0)], ring: true, dryRun: true))),
    "parses the dry run flag"
)

check(
    parseCLI(["-a", "Mail", "-t", "9", "--times", "17"]),
    .success(.show(Config(app: "Mail", times: [TimeOfDay(hour: 9, minute: 0), TimeOfDay(hour: 17, minute: 0)], ring: true, dryRun: false))),
    "collects repeated time flags"
)

check(
    parseCLI(["-a", "  System Settings  ", "-t", "9"]),
    .success(.show(Config(app: "System Settings", times: [TimeOfDay(hour: 9, minute: 0)], ring: true, dryRun: false))),
    "accepts an app name with spaces"
)

check(
    parseCLI(["-a", "Mail", "-t", "9", "--no-ring"]),
    .success(.show(Config(app: "Mail", times: [TimeOfDay(hour: 9, minute: 0)], ring: false, dryRun: false))),
    "stays silent when asked to"
)

check(parseCLI(["--help"]), .success(.help), "parses help")
check(parseCLI(["-t", "9:00"]), .failure(.missingApp), "reports a missing app")
check(parseCLI(["-a", "Mail"]), .failure(.noTimesGiven), "reports a missing time list")
check(parseCLI(["-a", "   ", "-t", "9:00"]), .failure(.emptyApp), "reports an empty app name")
check(parseCLI(["-a", "Safari", "-t", "8:00,"]), .failure(.timesSplitBySpaces("8:00,")), "explains a split list")
check(
    parseCLI(["-a", "Safari", "-t", "8:00, 12:00, 16:00"]),
    .success(.show(Config(app: "Safari", times: [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 12, minute: 0), TimeOfDay(hour: 16, minute: 0)], ring: true, dryRun: false))),
    "accepts a quoted list with spaces after commas"
)
check(parseCLI(["-a", "Mail", "-t", "half past nine"]), .failure(.invalidTime("half past nine")), "reports an unparsable time")
check(parseCLI(["-a", "Mail", "-t"]), .failure(.missingValue("-t")), "reports a flag without a value")
check(parseCLI(["--lunch", "12:00"]), .failure(.unknownArgument("--lunch")), "reports an unknown argument")

// MARK: - Alarm

let defaultOptions = AlarmOptions(between: 10, giveUpAfter: 6, playFailures: 3)
check(alarmRing(defaultOptions, TestAlarmEffects(idle: 600, playResult: .success(()))), .rung(rings: 6), "stops at the cap when nothing else happens")

check(
    alarmRing(AlarmOptions(between: 10, giveUpAfter: 1, playFailures: 3), TestAlarmEffects(idle: 600, playResult: .success(()))),
    .rung(rings: 1),
    "rings once when asked to"
)

check(
    alarmRing(AlarmOptions(between: 10, giveUpAfter: 6, playFailures: 3), TestAlarmEffects(idle: 600, playResult: .failure("no such file"))),
    .silent(reason: "no such file"),
    "reports a sound it could not play"
)

check(
    alarmRing(AlarmOptions(between: 10, giveUpAfter: 99, playFailures: 3), TestAlarmEffects(idle: 0, playResult: .success(()))),
    .rung(rings: 2),
    "a baseline of zero no longer makes the alarm unstoppable"
)

check(
    alarmRing(AlarmOptions(between: 10, giveUpAfter: 99, playFailures: 3), TestAlarmEffects(idle: 1, playResult: .success(()))),
    .rung(rings: 2),
    "input during ringing stops it"
)

check(defaultPlayFailures, 40, "waits out an audio device still coming up")

// MARK: - Summary

print("")
if failures == 0 {
    print("All tests passed.")
    exit(0)
} else {
    print("\(failures) test(s) failed.")
    exit(1)
}
