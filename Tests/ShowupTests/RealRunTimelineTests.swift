import Testing
@testable import ShowupCore

/// The two windows from a real run on this Mac, reproduced to the second.
///
/// `-t 04:00,08:00` on 2026-10-22, `sudo showup -a Binance`. Both windows went
/// up enormously late — 04:00 at 04:16:38, 08:00 at 09:40:53 — and the log
/// lines are the ones that run produced. They are kept here because the
/// numbers are the specification: a hold that cannot reproduce this timeline is
/// not the hold this program needs.
///
/// The cause was a hold that counted elapsed seconds on a clock which stops
/// while the Mac is suspended. It asked "how far off the moment am I?" by
/// adding up seconds that never arrived.
@Suite struct RealRunTimeline {
    /// The first window. The log:
    ///
    ///     03:58:20  waking at 04:00 (pmset 10/22/2026 03:58:20), in 1m 39s
    ///     03:58:20  the Mac was awake throughout (idle 76s -> 76s over 0s)
    ///     03:58:20  holding the window for 99s until the required time
    ///     04:00:14  holding the window for 59s until the required time
    ///     04:16:19  holding the window for 19s until the required time
    ///     04:16:38  about to show Binance
    ///
    /// The hold began at 03:58:20 with 99 seconds to wait for 04:00:00. By
    /// 04:00:14 the wall clock had passed the moment and the count said 59
    /// seconds still owed — the machine had gone down and the seconds it spent
    /// down were not seconds the count received.
    @Test func the0400WindowGoesUpAtFour() {
        let machine = FakeMachine()
        machine.setClock(3 * 3_600 + 58 * 60 + 20)  // 03:58:20
        machine.sleepsDuringWait = false
        machine.setIdleCounter(76)
        // The kernel would not say, so nothing was rung for and the hold is
        // what is under test.
        machine.powerCycle = PowerCycle(willSleep: false, hasPoweredOn: false)
        // The Mac goes down 74 seconds into the 99 second hold and comes back
        // 16 minutes later, which is what the wall clock in the log shows.
        machine.suspendsDuring(1, for: 74)

        _ = step(config(hour: 4), effects: machine.effects, from: 3 * 3_600 + 58 * 60 + 20)

        #expect(machine.shownApps == ["Binance"])
        // 04:00:00. The wall clock passed the moment at 04:00:14 and the
        // window went up then at the latest — never at 04:16:38.
        #expect(machine.now == 4 * 3_600)
    }

    /// The second window, and the worse of the two. The log:
    ///
    ///     04:16:38  waking at 08:00 (pmset 10/22/2026 07:58:59), in 3h 43m 21s
    ///     07:58:59  input arrived during the wait (idle 175s -> 0s over 13341s)
    ///     07:58:59  holding the window for 6114s until the required time
    ///     09:40:53  about to show Binance
    ///
    /// The step began at 04:16:38 and asked for 08:00. The Mac was down for two
    /// hours of that wait, so by 07:58:59 the count believed it still owed 6114
    /// seconds — and 07:58:59 plus 6114 is 09:40:53, exactly where the app came
    /// up. The wait was owed the whole two hours again.
    @Test func the0800WindowGoesUpAtEight() {
        let machine = FakeMachine()
        machine.setClock(4 * 3_600 + 16 * 60 + 38)  // 04:16:38
        machine.sleepsDuringWait = true  // the idle counter froze, as it does
        machine.setIdleCounter(175)
        machine.powerCycle = PowerCycle(willSleep: false, hasPoweredOn: false)
        // The Mac goes down for the two hours between the step and the RTC
        // wake, and is up and taking input when it comes back at 07:58:59.
        machine.suspendsDuring(1, for: 7_243)

        _ = step(config(hour: 8), effects: machine.effects, from: 4 * 3_600 + 16 * 60 + 38)

        #expect(machine.shownApps == ["Binance"])
        // 08:00:00 — not 09:40:53.
        #expect(machine.now == 8 * 3_600)
    }

    /// The same run, whole, as a loop: several times served in order, each on
    /// its own moment, with the machine going down and coming back in between.
    /// This is the shape the fix has to hold under, because a hold that is
    /// right once is not a hold that is right.
    @Test func everyTimeInTheRunLandsOnItsOwnMoment() {
        let machine = FakeMachine()
        let times = [
            TimeOfDay(hour: 0, minute: 0), TimeOfDay(hour: 4, minute: 0),
            TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 12, minute: 0),
            TimeOfDay(hour: 16, minute: 0), TimeOfDay(hour: 20, minute: 0),
        ]
        let config = Config(app: "Binance", times: times, ring: true, dryRun: false)
        // Every wake: the Mac is asleep, the kernel will not say, nothing is
        // rung for, and the machine spends part of the wait down.
        machine.sleepsDuringWait = true
        machine.setIdleCounter(300)
        machine.powerCycle = PowerCycle(willSleep: false, hasPoweredOn: false)

        var cursor = 3 * 3_600  // 03:00, where the fake machine starts
        var served: [Int] = []
        var landed: [Int] = []
        for _ in 0..<times.count {
            // Each step's wait for the wake is interrupted once: the machine
            // goes down partway through and the RTC wake brings it back with
            // the hold to finish, which is the shape the real run had. The
            // suspension ends before the moment, so the window can still be on
            // time — a wait that ended after it would be late, which is
            // allowed but is not what this is about.
            var fired = false
            machine.suspendsDuringSleep = { _, asked in
                guard !fired, asked > 0 else { return 0 }
                fired = true
                return 600
            }

            guard case .surfaced(let wake, _) = step(
                config, effects: machine.effects, from: cursor, at: machine.currentDate
            ) else { break }
            served.append(wake.at.secondsSinceMidnight)
            // What the machine's clock said when the window came up. This is
            // the number that was wrong in the real run.
            landed.append(machine.now)
            // The loop's own rule: step past the wake just served, by its
            // moment rather than by the clock.
            cursor = (wake.at.secondsSinceMidnight + 1) % secondsPerDay
        }

        // Each configured time served once, in order. The run begins at 03:00,
        // so 00:00 is already past and the list closes with it, a day later.
        #expect(served == [14_400, 28_800, 43_200, 57_600, 72_000, 0])
        #expect(machine.shownApps == Array(repeating: "Binance", count: times.count))
        // And every window went up on its own moment to the second — 04:00:00
        // for the 04:00 window, 08:00:00 for the 08:00 one, whatever the
        // machine was doing in between. In the real run these read 04:16:38
        // and 09:40:53.
        #expect(landed == served)
    }

    /// The hold must also be right when the machine is up throughout — the
    /// ordinary case, and the one the 126 tests before this already covered.
    /// It is here so the two are pinned in the same place: a fix for the
    /// sleeping case that broke the awake one would show up here.
    @Test func anAwakeMachineStillGetsEveryWindowOnTime() {
        let machine = FakeMachine()
        machine.sleepsDuringWait = false
        let times = [TimeOfDay(hour: 4, minute: 0), TimeOfDay(hour: 8, minute: 0)]
        let config = Config(app: "Safari", times: times, ring: true, dryRun: false)

        var cursor = 3 * 3_600
        var landed: [Int] = []
        for _ in 0..<times.count {
            _ = step(config, effects: machine.effects, from: cursor, at: machine.currentDate)
            landed.append(machine.now)
            cursor = machine.now
        }

        #expect(landed == [4 * 3_600, 8 * 3_600])
    }

    func config(hour: Int) -> Config {
        Config(
            app: "Binance",
            times: [TimeOfDay(hour: hour, minute: 0)],
            ring: true,
            dryRun: false
        )
    }
}