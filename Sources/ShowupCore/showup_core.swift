import Foundation

extension String: Error {}

// MARK: - Errors

public enum ShowError: Error, CustomStringConvertible, Equatable {
    case missingApp
    case emptyApp
    case noTimesGiven
    case invalidTime(String)
    case timesSplitBySpaces(String)
    case missingValue(String)
    case unknownArgument(String)
    case help

    public var description: String {
        switch self {
        case .missingApp: return "no app given, pass one with -a/--app"
        case .emptyApp: return "the app name given with -a/--app is empty"
        case .noTimesGiven: return "no times given, pass some with -t/--times"
        case .invalidTime(let input): return "expected a time like 8:00, but got \"\(input)\""
        case .timesSplitBySpaces(let value):
            return "the times \"\(value)\" end in a comma, so the shell split the list on the spaces after each one. Write them as a single argument, such as \"8:00,12:00,16:00\""
        case .missingValue(let flag): return "\"\(flag)\" needs a value"
        case .unknownArgument(let argument): return "unexpected argument \(argument)"
        case .help: return ""
        }
    }
}

// MARK: - Models

public enum Command: Equatable {
    case show(Config)
    case showSchedule(Config)
    case help
}

public struct Config: Equatable {
    public var app: String
    public var times: [TimeOfDay]
    public var ring: Bool
    public var dryRun: Bool

    public init(app: String, times: [TimeOfDay], ring: Bool, dryRun: Bool) {
        self.app = app
        self.times = times
        self.ring = ring
        self.dryRun = dryRun
    }
}

public struct TimeOfDay: Hashable, Comparable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public var secondsSinceMidnight: Int { hour * 3600 + minute * 60 }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.secondsSinceMidnight < rhs.secondsSinceMidnight
    }

    public func rendered() -> String {
        String(format: "%02d:%02d", hour, minute)
    }
}

public struct Wake: Equatable {
    public var at: TimeOfDay
    public var delay: Int // seconds

    public init(at: TimeOfDay, delay: Int) {
        self.at = at
        self.delay = delay
    }
}

public enum ShowOutcome {
    case launched
    case surfaced
    case failed(String)
}

public enum AlarmOutcome: Equatable {
    case awake
    case rung(rings: Int)
    case silent(reason: String)
}

public struct AlarmOptions {
    public var between: Int = ringBetweenSeconds
    public var giveUpAfter: Int? = nil
    public var playFailures: Int = defaultPlayFailures

    public init(between: Int = ringBetweenSeconds, giveUpAfter: Int? = nil, playFailures: Int = defaultPlayFailures) {
        self.between = between
        self.giveUpAfter = giveUpAfter
        self.playFailures = playFailures
    }
}

// MARK: - Alarm effects protocol (pure)

public protocol AlarmEffects {
    var idleSeconds: () -> Int { get }
    var play: (String) -> Result<Void, String> { get }
    var sleep: (Int) -> Void { get }
}

// MARK: - CLI parsing

public func parseCLI(_ argv: [String]) -> Result<Command, ShowError> {
    var app: String? = nil
    var times: [TimeOfDay] = []
    var ring = true
    var dryRun = false
    var i = 0

    func consumeValue(_ flag: String) throws -> String {
        if i + 1 < argv.count {
            i += 1
            return argv[i]
        }
        throw ShowError.missingValue(flag)
    }

    while i < argv.count {
        let flag = argv[i]
        switch flag {
        case "-h", "--help":
            return .success(.help)
        case "-n", "--dry-run":
            dryRun = true
        case "-q", "--no-ring":
            ring = false
        case "-a", "--app":
            do { app = try consumeValue(flag).trimmingCharacters(in: .whitespacesAndNewlines) } catch { return .failure(error as! ShowError) }
        case "-t", "--times":
            do {
                let value = try consumeValue(flag)
                if value.hasSuffix(",") {
                    return .failure(.timesSplitBySpaces(value))
                }
                let parsed = parseTimeList(value)
                switch parsed {
                case .success(let ts): times.append(contentsOf: ts)
                case .failure: return .failure(.invalidTime(value))
                }
            } catch { return .failure(error as! ShowError) }
        default:
            if flag.hasPrefix("--"), let eq = flag.firstIndex(of: "=") {
                let name = String(flag[flag.index(after: flag.startIndex)..<eq].drop(while: { $0 == "-" }))
                let value = String(flag[flag.index(after: eq)..<flag.endIndex])
                switch name {
                case "app":
                    app = value.trimmingCharacters(in: .whitespacesAndNewlines)
                case "times":
                    if value.hasSuffix(",") {
                        return .failure(.timesSplitBySpaces(value))
                    }
                    let parsed = parseTimeList(value)
                    switch parsed {
                    case .success(let ts): times.append(contentsOf: ts)
                    case .failure: return .failure(.invalidTime(value))
                    }
                default:
                    return .failure(.unknownArgument(flag))
                }
            } else {
                return .failure(.unknownArgument(flag))
            }
        }
        i += 1
    }

    guard let app else { return .failure(.missingApp) }
    if app.isEmpty { return .failure(.emptyApp) }
    if times.isEmpty { return .failure(.noTimesGiven) }

    let normalised = normalise(times)
    let config = Config(app: app, times: normalised, ring: ring, dryRun: dryRun)
    return .success(dryRun ? .showSchedule(config) : .show(config))
}

func splitTime(_ input: String) -> (String, String)? {
    let parts = input.split(separator: ":")
    if parts.count == 1 {
        return (String(parts[0]), "0")
    }
    if parts.count == 2 {
        return (String(parts[0]), String(parts[1]))
    }
    return nil
}

public func parseTime(_ input: String) -> Result<TimeOfDay, String> {
    guard let parts = splitTime(input) else {
        return .failure("malformed")
    }
    guard let hour = Int(parts.0), let minute = Int(parts.1) else {
        return .failure("malformed")
    }
    var h = hour
    if h == 24 && minute == 0 { h = 0 }
    if h < 0 || h > 23 {
        return .failure("hourOutOfRange")
    }
    if minute < 0 || minute > 59 {
        return .failure("minuteOutOfRange")
    }
    return .success(TimeOfDay(hour: h, minute: minute))
}

public func parseTimeList(_ input: String) -> Result<[TimeOfDay], String> {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .failure("noTimesGiven") }
    return trimmed
        .split(separator: ",", omittingEmptySubsequences: false)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .map(parseTime)
        .reduce(.success([])) { acc, result in
            switch (acc, result) {
            case (.success(var list), .success(let t)):
                list.append(t)
                return .success(list)
            case (.failure(let e), _):
                return .failure(e)
            case (_, .failure(let e)):
                return .failure(e)
            }
        }
}

public func normalise(_ times: [TimeOfDay]) -> [TimeOfDay] {
    Array(Set(times)).sorted()
}

public func nextWake(_ times: [TimeOfDay], from now: Int) -> Wake? {
    guard !times.isEmpty else { return nil }
    var best: Wake?
    for at in times {
        var until = at.secondsSinceMidnight - (now % 86_400)
        if until <= 0 { until += 86_400 }
        let wake = Wake(at: at, delay: until)
        if let b = best {
            if wake.delay < b.delay { best = wake }
        } else {
            best = wake
        }
    }
    return best
}

public func upcoming(_ times: [TimeOfDay], from now: Int, count: Int) -> [Wake] {
    guard count > 0 else { return [] }
    var result: [Wake] = []
    var cursor = now
    for _ in 0..<count {
        guard let wake = nextWake(times, from: cursor) else { break }
        result.append(wake)
        cursor = (cursor + wake.delay) % 86_400
    }
    return result
}

// MARK: - Scheduler constants & helpers

public let dayLeadSeconds = 60
public let nightLeadSeconds = 300
public let sleepStepSeconds = 10
public let resyncAfterSeconds = 60
public let loginTimeoutSeconds = 120
public let quietVolume = 30
public let ringSeconds = 7

public func leadFor(hour: Int) -> Int {
    isNight(hour) ? nightLeadSeconds : dayLeadSeconds
}

func isNight(_ hour: Int) -> Bool {
    hour >= 22 || hour < 7
}

public func leadSplit(delaySeconds: Int, leadSeconds: Int) -> (ahead: Int, remaining: Int) {
    if delaySeconds >= leadSeconds {
        return (delaySeconds - leadSeconds, leadSeconds)
    }
    return (delaySeconds, 0)
}

public func secondsBetween(_ from: Int, _ to: Int) -> Int {
    let difference = to - from
    return difference < 0 ? difference + 86_400 : difference
}

public func nextInstant(planned: Int, delay: Int, now: Int) -> Int {
    let target = planned + delay
    if secondsBetween(target, now) > resyncAfterSeconds {
        return now
    }
    return target
}

// MARK: - Sleep detection (power log)

public func sleptIn(_ log: String, started: Int, elapsed: Int) -> Bool {
    guard let latest = latestSleep(log) else { return false }
    let since = (latest - started + 86_400) % 86_400
    return since < elapsed
}

func latestSleep(_ log: String) -> Int? {
    var best: Int?
    for line in log.split(separator: "\n", omittingEmptySubsequences: true) {
        if let t = sleepTime(String(line)) {
            best = t
        }
    }
    return best
}

func sleepTime(_ line: String) -> Int? {
    let fields = line.split(separator: " ", omittingEmptySubsequences: true)
    guard fields.count >= 2 else { return nil }
    let clock = fields[1]
    let parts = clock.split(separator: ":")
    guard parts.count == 3,
          let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]) else { return nil }
    return h * 3600 + m * 60 + s
}

// MARK: - Clock & pmset datetime

public func clock(_ seconds: Int) -> String {
    String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
}

public func pmsetDatetime(secondsFromNow: Int) -> String {
    let now = Date()
    let calendar = Calendar.current
    let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
    let year = comps.year ?? 0
    let month = comps.month ?? 0
    let day = comps.day ?? 0
    let hour = comps.hour ?? 0
    let minute = comps.minute ?? 0
    let second = comps.second ?? 0

    let secondsToday = hour * 3600 + minute * 60 + second
    let target = secondsToday + secondsFromNow

    let (daysAhead, timeOfDay): (Int, Int)
    if target >= 86_400 {
        daysAhead = 1
        timeOfDay = target - 86_400
    } else {
        daysAhead = 0
        timeOfDay = target
    }

    let (finalYear, finalMonth, finalDay) = advanceDate(year, month, day, days: daysAhead)
    let (fh, fm, fs) = splitClock(timeOfDay)

    return "\(pad(finalMonth))/\(pad(finalDay))/\(finalYear) \(pad(fh)):\(pad(fm)):\(pad(fs))"
}

func splitClock(_ seconds: Int) -> (Int, Int, Int) {
    (seconds / 3600, seconds / 60 % 60, seconds % 60)
}

func advanceDate(_ year: Int, _ month: Int, _ day: Int, days: Int) -> (Int, Int, Int) {
    guard days > 0 else { return (year, month, day) }
    return advanceOneDay(year, month, day)
}

func advanceOneDay(_ year: Int, _ month: Int, _ day: Int) -> (Int, Int, Int) {
    let maxDay = daysInMonth(year, month)
    if day + 1 > maxDay {
        if month + 1 > 12 {
            return (year + 1, 1, 1)
        }
        return (year, month + 1, 1)
    }
    return (year, month, day + 1)
}

func daysInMonth(_ year: Int, _ month: Int) -> Int {
    switch month {
    case 2:
        return isLeapYear(year) ? 29 : 28
    case 4, 6, 9, 11: return 30
    default: return 31
    }
}

func isLeapYear(_ year: Int) -> Bool {
    year % 4 == 0 && year % 100 != 0 || year % 400 == 0
}

func pad(_ value: Int) -> String {
    String(format: "%02d", value)
}

// MARK: - Delay rendering

public func describeDelay(_ delay: Int) -> String {
    let hours = delay / 3600
    let minutes = delay / 60 % 60
    let seconds = delay % 60
    var parts: [String] = []
    if hours > 0 { parts.append("\(hours)h") }
    if minutes > 0 { parts.append("\(minutes)m") }
    if seconds > 0 { parts.append("\(seconds)s") }
    if parts.isEmpty { return "0s" }
    return parts.joined(separator: " ")
}

// MARK: - Alarm

public let defaultPlayFailures = 40
public let ringBetweenSeconds = 5

public let ringbackTone = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/facetime/multiway_invitation.caf"

public func alarmRing(_ options: AlarmOptions, _ effects: AlarmEffects) -> AlarmOutcome {
    keepRinging(options, effects, rings: 1, failures: 0)
}

func keepRinging(_ options: AlarmOptions, _ effects: AlarmEffects, rings: Int, failures: Int) -> AlarmOutcome {
    switch effects.play(ringbackTone) {
    case .success:
        effects.sleep(options.between)
        let idleNow = effects.idleSeconds()
        if answered(idleNow: idleNow, rings: rings, options: options) {
            return .rung(rings: rings)
        }
        return keepRinging(options, effects, rings: rings + 1, failures: 0)
    case .failure(let reason):
        if failures + 1 >= options.playFailures {
            return .silent(reason: reason)
        }
        effects.sleep(options.between)
        return keepRinging(options, effects, rings: rings, failures: failures + 1)
    }
}

func answered(idleNow: Int, rings: Int, options: AlarmOptions) -> Bool {
    let touched = rings >= 2 && idleNow <= 1
    let capped = options.giveUpAfter.map { rings >= $0 } ?? false
    return touched || capped
}
