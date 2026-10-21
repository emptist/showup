import Foundation
import ShowupCore
import ShowupMac

@main
enum Showup {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        let command: Command
        do {
            command = try parseCLI(arguments)
        } catch {
            FileHandle.standardError.write(Data("showup: \(error.description)\n\n".utf8))
            FileHandle.standardError.write(Data(usage().utf8))
            exit(2)
        }

        switch command {
        case .help:
            print(usage())
        case .showSchedule(let config):
            printSchedule(config)
        case .show(let config):
            announceLog()
            // Which of the two detection paths this run will use is worth
            // saying up front: the kernel's own notifications, or the power log.
            Log.write(
                PowerNotifications.shared == nil
                    ? "no kernel sleep and wake notifications, falling back to the power log"
                    : "listening for the kernel's own sleep and wake notifications"
            )
            leaveNothingArmed()
            takeTheWakeBackOnExit()

            run(config, effects: .live(alarm: { alarmRing(AlarmOptions(budget: $0), LiveAlarmEffects()) }))
        }
    }

    /// Says what the kernel already has armed, so an alarm nobody expects is
    /// visible at startup rather than discovered later as a Mac waking up for no
    /// reason.
    static func leaveNothingArmed() {
        let armed = ScheduledWake.shared.armedWakes()
        guard !armed.isEmpty else { return }
        Log.write("the kernel already has \(armed.count) wake\(armed.count == 1 ? "" : "s") armed:")
        for wake in armed.sorted(by: { $0.when < $1.when }) {
            Log.write("  \(clock(secondsSinceMidnight(wake.when))) from \(wake.owner)")
        }
    }

    /// Takes the RTC wake back when showup stops.
    ///
    /// Without this, Ctrl-C leaves the Mac armed to wake at a time nobody asked
    /// for, and the leftovers accumulate across runs. Six were found on this
    /// machine, from six runs that had already exited.
    static func takeTheWakeBackOnExit() {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                Log.write("stopping; taking the wake back with it")
                ScheduledWake.shared.cancel()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Held for the life of the process. A DispatchSource that is released is
    /// cancelled, and then Ctrl-C does nothing at all - which is exactly what
    /// happened the first time this was written.
    private nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []

    /// Says where this run is writing before anything else, so the file can be
    /// found afterwards without guessing.
    static func announceLog() {
        if Log.isWritable {
            FileHandle.standardOutput.write(Data("showup: logging to \(Log.path)\n".utf8))
        } else {
            FileHandle.standardError.write(
                Data("showup: cannot write \(Log.path); the log stays in the terminal\n".utf8)
            )
        }
    }

    static func printSchedule(_ config: Config) {
        let now = Date()
        print("showup will surface \(config.app) at:")
        for (index, entry) in upcomingAbsolute(config.times, from: now, count: 5).enumerated() {
            // The delay is the time that will actually pass, measured to the
            // instant rather than between two times of day: on the night the
            // clock changes those are not the same number.
            let delay = Int(entry.target.timeIntervalSince(now).rounded(.down))
            let when = index == 0 ? "in \(describeDelay(delay))" : "\(describeDelay(delay)) later"
            print("  \(entry.wake.at.rendered)  \(when)")
        }
    }

    static func usage() -> String {
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
            "                        five seconds until you press a key, and only",
            "                        when it had to wake the Mac from sleep. Use this",
            "                        if you would rather it only ever brought the",
            "                        window forward silently.",
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
}