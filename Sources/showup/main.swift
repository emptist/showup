import Foundation
import ShowupCore

// MARK: - Scheduler effects (platform boundary)

protocol Effects {
    var now: () -> Int { get }            // seconds since local midnight
    var sleep: (Int) -> Void { get }      // seconds, wall-clock stepped
    var scheduleWake: (String) -> Result<Void, String> { get } // pmset datetime
    var idleSeconds: () -> Int { get }    // ioreg HIDIdleTime
    var sleptDuring: (Int, Int) -> Result<Bool, String> { get } // (started, elapsed)
    var show: (String) -> ShowOutcome { get }
    var alarm: () -> AlarmOutcome { get }
    var outputVolume: () -> Result<Int, String> { get }
    var atDesktop: () -> Bool { get }
    var log: (String) -> Void { get }
    var warn: (String) -> Void { get }
}

// MARK: - Live effects (macOS)

final class LiveEffects: Effects {
    let now: () -> Int
    let sleep: (Int) -> Void
    let scheduleWake: (String) -> Result<Void, String>
    let idleSeconds: () -> Int
    let sleptDuring: (Int, Int) -> Result<Bool, String>
    let show: (String) -> ShowOutcome
    let alarm: () -> AlarmOutcome
    let outputVolume: () -> Result<Int, String>
    let atDesktop: () -> Bool
    let log: (String) -> Void
    let warn: (String) -> Void

    init(alarm: @escaping () -> AlarmOutcome) {
        self.now = Self.nowSeconds
        self.sleep = { seconds in
            let target = (LiveEffects.nowSeconds() + seconds) % 86_400
            sleepUntilLive(target: target, budget: seconds)
        }
        self.scheduleWake = { datetime in
            exec("/usr/bin/pmset", ["schedule", "wake", datetime]).map { _ in () }
        }
        self.idleSeconds = { parseIdleSeconds(execIoreg()) }
        self.sleptDuring = { started, elapsed in
            execSleepLog().map { sleptIn($0, started: started, elapsed: elapsed) }
        }
        self.show = { app in showApp(app) }
        self.alarm = alarm
        self.outputVolume = { speakerVolume() }
        self.atDesktop = { isAtDesktop() }
        self.log = { message in
            print("showup: \(message)")
            record(message)
        }
        self.warn = { message in
            fputs("showup: \(message)\n", stderr)
            record("WARNING \(message)")
        }
    }

    static func nowSeconds() -> Int {
        let now = Date()
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: now)
        return Int(now.timeIntervalSince(midnight))
    }
}

final class LiveAlarmEffects: AlarmEffects {
    let idleSeconds: () -> Int = { parseIdleSeconds(execIoreg()) }
    let play: (String) -> Result<Void, String> = { playSound($0) }
    let sleep: (Int) -> Void = { seconds in Thread.sleep(forTimeInterval: Double(seconds)) }
}

// MARK: - Scheduler loop

func run(app: String, times: [TimeOfDay], effects: Effects) {
    var instant = effects.now()
    while true {
        switch step(app: app, times: times, effects: effects, from: instant) {
        case .surfaced(let wake, _):
            instant = nextInstant(planned: instant, delay: wake.delay, now: effects.now())
        case .idle:
            return
        }
    }
}

enum Step {
    case surfaced(wake: Wake, showed: ShowOutcome)
    case idle
}

func step(app: String, times: [TimeOfDay], effects: Effects, from now: Int) -> Step {
    guard let wake = nextWake(times, from: now) else {
        effects.log("no times to wait for, stopping")
        return .idle
    }

    let delaySeconds = wake.delay
    let leadSeconds = leadFor(hour: wake.at.hour)
    let (ahead, remaining) = leadSplit(delaySeconds: delaySeconds, leadSeconds: leadSeconds)
    let datetime = pmsetDatetime(secondsFromNow: ahead)

    effects.log("waking at \(wake.at.rendered()) (pmset \(datetime)), in \(describeDelay(delaySeconds))")

    switch effects.scheduleWake(datetime) {
    case .failure(let reason):
        effects.warn("could not schedule wake (did you run with sudo?): \(reason)")
    case .success: break
    }

    let started = effects.now()
    sleepSeconds(effects, ahead)
    let elapsed = secondsBetween(started, effects.now())

    let slept: Bool
    switch effects.sleptDuring(started, elapsed) {
    case .success(let s): slept = s
    case .failure(let reason):
        effects.warn("could not read the power log: \(reason)")
        slept = true
    }

    var spent = 0
    if slept {
        effects.log("the Mac was asleep, waking you up first")
        spent = rouse(effects)
        sleepSeconds(effects, remaining - spent)
    } else {
        effects.log("the Mac was awake throughout, nothing to wake")
        sleepSeconds(effects, remaining)
    }

    let showed = surface(app, effects)
    return .surfaced(wake: wake, showed: showed)
}

func sleepSeconds(_ effects: Effects, _ seconds: Int) {
    let target = (effects.now() + seconds) % 86_400
    sleepUntilLive(target: target, budget: seconds)
}

func sleepUntilLive(target: Int, budget: Int) {
    let now = LiveEffects.nowSeconds()
    let ahead = (target - now + 86_400) % 86_400
    if ahead == 0 || ahead > budget { return }
    let step = min(ahead, sleepStepSeconds)
    Thread.sleep(forTimeInterval: Double(step))
    sleepUntilLive(target: target, budget: budget - step)
}

// MARK: - Program 2 (rouse)

func rouse(_ effects: Effects) -> Int {
    checkAudible(effects)

    DispatchQueue.global().async {
        let rung = effects.alarm()
        switch rung {
        case .awake:
            effects.log("you were already awake, skipping alarm")
        case .rung(let rings):
            effects.log("rang \(rings) times to be heard")
        case .silent(let reason):
            effects.warn("could not ring: \(reason)")
        }
    }

    return ensureAtDesktop(effects)
}

func checkAudible(_ effects: Effects) {
    switch effects.outputVolume() {
    case .success(let volume):
        if volume < quietVolume {
            effects.warn("the alarm plays at the speaker volume, which is \(volume) - you will not hear it")
        }
    case .failure: break
    }
}

func ensureAtDesktop(_ effects: Effects) -> Int {
    if effects.atDesktop() {
        effects.log("already at desktop")
        return 0
    }
    effects.log("waiting for login to complete...")
    return pollUntilDesktop(effects, remaining: loginTimeoutSeconds)
}

func pollUntilDesktop(_ effects: Effects, remaining: Int) -> Int {
    if effects.atDesktop() {
        effects.log("login complete, desktop ready")
        return 0
    }
    if remaining > 0 {
        effects.sleep(1)
        return 1 + pollUntilDesktop(effects, remaining: remaining - 1)
    }
    effects.warn("timed out waiting for login")
    return remaining
}

// MARK: - Program 1 (surface)

func surface(_ app: String, _ effects: Effects) -> ShowOutcome {
    effects.log("about to show \(app)")
    let showed = effects.show(app)
    report(app, showed, effects)
    return showed
}

func report(_ app: String, _ showed: ShowOutcome, _ effects: Effects) {
    switch showed {
    case .launched: effects.log("launched \(app)")
    case .surfaced: effects.log("brought \(app) to the foreground")
    case .failed(let reason): effects.warn("could not show \(app): \(reason)")
    }
}

// MARK: - Entry point

func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())

    switch parseCLI(arguments) {
    case .success(let command):
        switch command {
        case .help:
            print(usage())
            return
        case .showSchedule(let config):
            printSchedule(config)
            return
        case .show(let config):
            let effects = LiveEffects(alarm: {
                alarmRing(AlarmOptions(), LiveAlarmEffects())
            })
            run(app: config.app, times: config.times, effects: effects)
        }
    case .failure(let error):
        fputs("showup: \(error.description)\n\n", stderr)
        fputs(usage(), stderr)
        exit(2)
    }
}

func printSchedule(_ config: Config) {
    let previewCount = 5
    let now = LiveEffects.nowSeconds()
    print("showup will surface \(config.app) at:")
    let wakes = upcoming(config.times, from: now, count: previewCount)
    for (index, wake) in wakes.enumerated() {
        if index == 0 {
            print("  \(wake.at.rendered())  in \(describeDelay(wake.delay))")
        } else {
            print("  \(wake.at.rendered())  \(describeDelay(wake.delay)) later")
        }
    }
}

func usage() -> String {
    [
        "showup - bring a macOS app to the foreground at times you choose",
        "",
        "Usage:",
        "  showup -a <app> -t <times> [-n] [-q]",
        "",
        "Arguments:",
        "  -a, --app <name>      The application to surface, for example \"Safari\".",
        "  -t, --times <times>   Comma separated times of day, for example",
        "                        8:00,12:00,16:00,20:00,24:00. A bare hour such",
        "                        as 8 means 8:00.",
        "  -n, --dry-run         Print the next few wake times and exit.",
        "  -q, --no-ring         Never make a sound. By default showup rings",
        "                        like an incoming FaceTime call, repeating every",
        "                        five seconds, whenever it had to wake the Mac from",
        "                        sleep and nothing answered it. Use this if you",
        "                        would rather it only ever brought the window",
        "                        forward silently.",
        "  -h, --help            Show this message.",
        "",
        "Both --flag value and --flag=value forms are accepted. A time that has",
        "already passed today waits for tomorrow.",
        "",
        "Examples:",
        "  showup -a Safari -t 8:00,12:00,16:00,20:00",
        "  showup -a Safari -t \"8:00, 12:00\"    # spaces need quoting",
        "  showup --app=\"Slack\" --times=\"9,17\"",
        "  showup -a Mail -t 24:00 --dry-run",
        "",
    ].joined(separator: "\n")
}

// MARK: - Platform primitives

func exec(_ executable: String, _ args: [String]) -> Result<String, String> {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = outputPipe
    do {
        try process.run()
        process.waitUntilExit()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus == 0 {
            return .success(output)
        } else {
            return .failure("exit code \(process.terminationStatus): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    } catch {
        return .failure("\(error)")
    }
}

func execIoreg() -> String {
    switch exec("/usr/sbin/ioreg", ["-r", "-c", "IOHIDSystem", "-d1"]) {
    case .success(let output): return output
    case .failure: return ""
    }
}

func execSleepLog() -> Result<String, String> {
    exec("/bin/sh", ["-c", "/usr/bin/pmset -g log | /usr/bin/grep 'Entering Sleep state' | /usr/bin/tail -20"])
}

func parseIdleSeconds(_ report: String) -> Int {
    guard let markerRange = report.range(of: "\"HIDIdleTime\" = ") else { return 0 }
    let after = String(report[markerRange.upperBound...])
    guard let newline = after.firstIndex(of: "\n") else {
        return Int(after.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
    let value = String(after[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
    return (Int(value) ?? 0) / 1_000_000_000
}

func consoleUID() -> Result<Int, String> {
    switch scutilQuery() {
    case .success(let output): return parseUID(output)
    case .failure(let reason): return .failure(reason)
    }
}

func scutilQuery() -> Result<String, String> {
    exec("/bin/sh", ["-c", "echo 'show State:/Users/ConsoleUser' | /usr/sbin/scutil"])
}

func parseUID(_ output: String) -> Result<Int, String> {
    let uidKey = "UID : "
    let candidates = output.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.hasPrefix(uidKey) }
    guard let line = candidates.first else {
        return .failure("no UID line in scutil output")
    }
    let rest = line[line.index(line.startIndex, offsetBy: uidKey.count)...]
    let value = rest.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let uid = Int(value) else {
        return .failure("could not parse UID from scutil output")
    }
    if uid == 0 { return .failure("no console user (UID is 0)") }
    return .success(uid)
}

func isRunning(_ app: String) -> Bool {
    switch exec("/usr/bin/lsappinfo", ["info", app]) {
    case .success(let record): return !record.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .failure: return false
    }
}

func showApp(_ app: String) -> ShowOutcome {
    let wasRunning = isRunning(app)
    switch consoleUID() {
    case .success(let uid):
        switch exec("/bin/launchctl", ["asuser", String(uid), "/usr/bin/open", "-a", app]) {
        case .success:
            return wasRunning ? .surfaced : .launched
        case .failure(let reason): return .failed(reason)
        }
    case .failure(let reason): return .failed(reason)
    }
}

func isAtDesktop() -> Bool {
    switch scutilQuery() {
    case .success(let output):
        switch parseUID(output) {
        case .success: return output.contains("kCGSessionLoginDoneKey : TRUE")
        case .failure: return false
        }
    case .failure: return true
    }
}

func speakerVolume() -> Result<Int, String> {
    switch exec("/usr/bin/osascript", ["-e", "output volume of (get volume settings)"]) {
    case .failure(let reason): return .failure(reason)
    case .success(let answer):
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let volume = Int(trimmed) else { return .failure("could not parse volume") }
        return .success(volume)
    }
}

func playSound(_ sound: String) -> Result<Void, String> {
    switch exec("/usr/bin/afplay", [sound]) {
    case .success: return .success(())
    case .failure(let reason): return .failure(reason)
    }
}

let logPath = "/tmp/showup.log"

func record(_ message: String) {
    let seconds = LiveEffects.nowSeconds()
    let line = clock(seconds) + "  " + message
    _ = exec("/bin/sh", ["-c", "printf '%s\\n' \"$1\" >> \(logPath)", "showup", line])
}

main()
