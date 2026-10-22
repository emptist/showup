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
            keepTheContract(config)
        case .show(let config):
            bootTheNight(config)
        case .runFromContract:
            // Root has no contract to read and its bare invocation was always
            // an error: the wording stands, asked for at the same place.
            guard !Ground.isRoot else {
                FileHandle.standardError.write(Data("showup: \(ShowError.missingApp.description)\n\n".utf8))
                FileHandle.standardError.write(Data(usage().utf8))
                exit(2)
            }
            runFromTheSchedule()
        case .renew(let directory):
            renewFrom(directory)
        }
    }

    /// Serves the schedule the contract carries: the night run as an
    /// installed thing performs it.
    ///
    /// The schedule lives in the contract, not in an argument, so it is read
    /// here once, loudly - a schedule that cannot be read is not guessed at,
    /// and the run says which field or value was wrong - and then the same
    /// start as an spoken-schedule run takes over. From the first moment on,
    /// the contract is re-read quietly between moments: a schedule changed in
    /// the terminal is picked up by the run standing since morning, because
    /// all three - the run, the renewal and the person - follow the same
    /// words then.
    static func runFromTheSchedule() {
        Ground.ensureDirectories()
        let path = Ground.userLockDirectory + "/" + ScheduleContract.fileName
        do {
            let contract = try readContract(at: path)
            bootTheNight(
                Config(app: contract.app, times: contract.times, ring: contract.ring, dryRun: false)
            )
        } catch let error as CocoaError where error.code == CocoaError.Code.fileReadNoSuchFile {
            FileHandle.standardError.write(Data(
                "showup: there is no schedule contract at \(path)\n\n".utf8
            ))
            FileHandle.standardError.write(Data((
                "showup: one is written by every run that says a schedule, for example:\n"
                    + "  showup -a Safari -t 8:00,12:00,16:00,20:00 --dry-run\n"
            ).utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data(
                "showup: cannot read the schedule contract at \(path): \(error)\n".utf8
            ))
            exit(1)
        }
    }

    /// Between two moments, take the schedule the contract carries now.
    ///
    /// Returns nil - keep what is standing - on every kind of unreadable
    /// contract, said into the log rather than nowhere, because a silent
    /// failure of exactly this kind is what leaves a run surfacing a dead
    /// schedule. The run keeps its schedule instead of quitting on the
    /// omission: the contract's absence can be mended the way it was caused,
    /// and the run that quits empties out the whole night until someone
    /// relaunches it.
    ///
    /// This is asked every few seconds while a run holds a moment, so each
    /// distinct note is said once rather than on every failed read; a
    /// readable contract is answered without a word unless it had been
    /// unreadable, in which case its return to health is said too.
    static func refreshSchedule() -> Config? {
        let path = Ground.userLockDirectory + "/" + ScheduleContract.fileName
        do {
            let contract = try readContract(at: path)
            if lastContractNote != nil {
                lastContractNote = nil
                Log.write("the schedule contract reads again")
            }
            return Config(app: contract.app, times: contract.times, ring: contract.ring, dryRun: false)
        } catch let error as CocoaError where error.code == CocoaError.Code.fileReadNoSuchFile {
            noteContractOnce("the schedule contract is gone from \(path); keeping the standing schedule")
            return nil
        } catch {
            noteContractOnce("cannot re-read the schedule contract at \(path): \(error); keeping the standing schedule")
            return nil
        }
    }

    /// Said-state for the notes above. The refresh runs alone on the run's
    /// one thread, like the lock descriptor and the signal sources.
    private nonisolated(unsafe) static var lastContractNote: String?

    /// Each distinct contract note is said once, until a different note
    /// takes its place.
    private static func noteContractOnce(_ note: String) {
        guard note != lastContractNote else { return }
        lastContractNote = note
        Log.write(note)
    }

    /// The contract at a path, in the one voice a missed file and a broken
    /// file share: a missing file surfaces as its own Swift error, a
    /// misshapen one as the reader's error that names the field.
    static func readContract(at path: String) throws -> ScheduleContract {
        try ScheduleContract.read(String(contentsOfFile: path, encoding: .utf8))
    }

    /// The run's own boot, once: the contract gets the word, then ground,
    /// lock, log, and the night loop.
    static func bootTheNight(_ config: Config) {
        // The word lands before the lock: a second run saying a changed
        // schedule is not fighting this run for the night, it is recording
        // a schedule - if locks decided whether the schedule changed, a run
        // standing since morning would be the only voice the contract ever
        // heard, and changing times would need killing it first.
        Ground.ensureDirectories()
        keepTheContract(config)
        // The lock is taken before anything else, so two runs never arm
        // two wakes or surface anything twice.
        if !InstanceLock.hold() { exit(1) }
        if !announceLog() { exit(1) }
        if let stamp = readBuildStamp() {
            Log.write(stamp)
        } else {
            Log.write("no build stamp; this binary was not built with make")
        }
        Log.pruneOldRuns()
        startTheNight(config)
    }

    /// The night loop, after the boot: sleep-and-wake bookkeeping spoken of
    /// where it belongs, then every moment in the schedule, for as long as
    /// there are moments.
    ///
    /// A run on a user ground re-reads the contract between moments, so the
    /// schedule it serves follows the words the contract now carries, not
    /// the ones it woke with. A legacy root run never re-reads: its schedule
    /// is its own argument, the way it always was.
    static func startTheNight(_ config: Config) {
        // Which of the two detection paths this run will use is worth
        // saying up front: the kernel's own notifications, or the power log.
        Log.write(
            PowerNotifications.shared == nil
                ? "no kernel sleep and wake notifications, falling back to the power log"
                : "listening for the kernel's own sleep and wake notifications"
        )
        leaveNothingArmed()
        takeTheWakeBackOnExit()

        let refresh: (() -> Config?)? = Ground.isRoot ? nil : { refreshSchedule() }
        run(
            config,
            effects: .live(alarm: { alarmRing(AlarmOptions(budget: $0), LiveAlarmEffects()) }),
            scheduleRefresh: refresh
        )
    }

    /// Puts the decided schedule on record for the renewal, on ground the
    /// user side owns.
    ///
    /// The file is what makes a schedule change a user act: it is written on
    /// every run that decides a schedule - the run as well as its preview -
    /// and quietly, because the contract is the run's own citizenship, not
    /// news. A legacy root run does not write it: its ground is not ground it
    /// shares with a renewal, and its whole identity story is the old one.
    ///
    /// A contract that cannot be written is said out loud, because a schedule
    /// the renewal cannot honor is a wake nobody re-arms - and the run
    /// carries on regardless, the way the night has always run.
    static func keepTheContract(_ config: Config) {
        guard !Ground.isRoot else { return }
        Ground.ensureDirectories()
        let path = Ground.userLockDirectory + "/" + ScheduleContract.fileName
        do {
            try ScheduleContract(app: config.app, times: config.times, ring: config.ring)
                .render()
                .write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data(
                "showup: cannot write the renewal contract at \(path): \(error)\n".utf8
            ))
        }
    }

    /// The renewal, run as root: the one place in the design that acts on the
    /// kernel's wake list on schedule.
    ///
    /// Refusals are read before anything is touched: a run without root is
    /// told the standing handoff line, and a contract that cannot be read is
    /// refused by `runRenewal` without a kernel act. The renewal takes
    /// neither the instance lock nor the exit take-back - its acts are
    /// planned whole and owned by the plan itself.
    ///
    /// Its narration is stderr, `runRenewal`'s own story: under the daemon,
    /// the plist's error path carries that stream onto the user's ground,
    /// and run by hand it lands in the terminal. The build stamp is spoken
    /// first, so the stream can be weighed against the binary that spoke it.
    static func renewFrom(_ directory: String) {
        guard Ground.isRoot else {
            FileHandle.standardError.write(Data(
                "showup: renew is the renewal side's act; it runs as root\n".utf8
            ))
            FileHandle.standardError.write(Data(
                "showup: \(ShowError.wakeIsNotOurs(announced: true).description)\n".utf8
            ))
            exit(1)
        }
        let stamp = readBuildStamp() ?? "no build stamp; this binary was not built with make"
        FileHandle.standardError.write(Data("showup: \(stamp)\n".utf8))
        exit(Int32(runRenewal(contractDirectory: directory)))
    }

    /// Says what the kernel already has armed, so an alarm nobody expects is
    /// visible at startup rather than discovered later as a Mac waking up for no
    /// reason.
    ///
    /// The take-back of leftovers happens first, under the instance lock: a run
    /// killed outright leaves its wake armed, and this is the only place left
    /// to take it back. What is listed afterwards is what survived the clean-up.
    ///
    /// On a run without the cancel right the sweep is skipped - nothing of this
    /// shape can be armed by runs like it - and the standing handoff is said
    /// once, here if not said earlier. The list is still read and reported: a
    /// user run narrates the kernel list, it just does not own its writes.
    static func leaveNothingArmed() {
        if Ground.isRoot {
            ScheduledWake.shared.takeBackLeftovers()
        } else if let line = ScheduledWake.shared.wakeHandoffLine() {
            Log.write(line)
        }
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
                if Ground.isRoot {
                    Log.write("stopping; taking the wake back with it")
                    ScheduledWake.shared.cancel()
                } else {
                    // The run without the cancel right has none armed by its
                    // own kind: the standing handoff already said why.
                    Log.write("stopping; the wake was never ours to take back")
                }
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
    ///
    /// Returns `false` when the run has to stop rather than carry on: on root's
    /// ground a log that cannot be written is degraded and stays in the terminal,
    /// on a user run's own ground the unwritable ground is the run's own home not
    /// being writable, and silence there would be lying.
    static func announceLog() -> Bool {
        if Log.isWritable {
            FileHandle.standardOutput.write(Data("showup: logging to \(Log.path)\n".utf8))
            return true
        }
        if Ground.isRoot {
            FileHandle.standardError.write(
                Data("showup: cannot write \(Log.path); the log stays in the terminal\n".utf8)
            )
            return true
        }
        FileHandle.standardError.write(
            Data("showup: cannot write \(Log.path); the log ground is not writable\n".utf8)
        )
        return false
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
            "  showup                         # the installed run: serves the",
            "                                 # schedule contract as it stands",
            "  showup renew <contract-directory>",
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
        "  showup                        # no schedule said: the one the",
        "                                # contract carries, set up at install",
        "  showup renew ~/Library/Application\\ Support/showup   # as root",
        "",
        ].joined(separator: "\n")
    }
}
