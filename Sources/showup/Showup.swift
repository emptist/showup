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
            run(config, effects: .live(alarm: { alarmRing(AlarmOptions(), LiveAlarmEffects()) }))
        }
    }

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
        print("showup will surface \(config.app) at:")
        for (index, wake) in upcoming(config.times, from: secondsSinceMidnight(Date()), count: 5).enumerated() {
            let when = index == 0 ? "in \(describeDelay(wake.delay))" : "\(describeDelay(wake.delay)) later"
            print("  \(wake.at.rendered)  \(when)")
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
            "                        five seconds, only when it had to wake the Mac",
            "                        from sleep and nothing answered it. Use this if",
            "                        you would rather it only ever brought the window",
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
}