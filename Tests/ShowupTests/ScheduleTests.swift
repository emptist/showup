import Foundation
import Testing
@testable import ShowupCore

// MARK: - Choosing the next wake

@Suite struct ScheduleTests {
    let noon = TimeOfDay(hour: 12, minute: 0)
    let nine = TimeOfDay(hour: 9, minute: 0)
    let eight = TimeOfDay(hour: 8, minute: 0)
    let twenty = TimeOfDay(hour: 20, minute: 0)

    @Test func picksTheSoonestTimeToday() {
        #expect(
            nextWake([twenty, eight, noon], from: nine.secondsSinceMidnight)
                == Wake(at: noon, delay: 3 * 3_600)
        )
    }

    @Test func waitsForTomorrowWhenTheTimeHasPassed() {
        #expect(nextWake([eight], from: nine.secondsSinceMidnight) == Wake(at: eight, delay: 23 * 3_600))
    }

    @Test func waitsAWholeDayWhenTheTimeIsNow() {
        #expect(nextWake([noon], from: noon.secondsSinceMidnight) == Wake(at: noon, delay: 86_400))
    }

    @Test func treatsMidnightAsLaterToday() {
        let midnight = TimeOfDay(hour: 0, minute: 0)
        let eleven = TimeOfDay(hour: 23, minute: 0)
        #expect(nextWake([midnight], from: eleven.secondsSinceMidnight) == Wake(at: midnight, delay: 3_600))
    }

    @Test func hasNoNextTimeWithoutTimes() {
        #expect(nextWake([], from: nine.secondsSinceMidnight) == nil)
    }

    /// A fixed ordinary day, at a fixed local hour. Ordinary on purpose: no
    /// zone changes its clock in June, wherever the suite runs.
    func localDate(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(
            from: DateComponents(year: 2026, month: 6, day: 15, hour: hour, minute: minute)
        )!
    }

    @Test func listsTheNextWakesInOrder() {
        let times = [eight, noon, twenty]
        let wakes = upcomingAbsolute(times, from: localDate(7), count: 4)
        #expect(wakes.map(\.wake.at.rendered) == ["08:00", "12:00", "20:00", "08:00"])
    }

    @Test func keepsRepeatingOverSeveralDays() {
        let times = [noon, twenty]
        let from = localDate(9)
        let wakes = upcomingAbsolute(times, from: from, count: 4)
        #expect(wakes.map(\.wake.at.rendered) == ["12:00", "20:00", "12:00", "20:00"])
        // The gap between consecutive wakes, as the clock counts them.
        #expect(wakes.map(\.wake.delay) == [3 * 3_600, 8 * 3_600, 16 * 3_600, 8 * 3_600])
        // Measured from the reading, which is what `--dry-run` prints: the time
        // that will actually pass before each wake.
        #expect(wakes.map { Int($0.target.timeIntervalSince(from)) } == [3 * 3_600, 11 * 3_600, 27 * 3_600, 35 * 3_600])
    }

    @Test func listsNothingWhenAskedForNothing() {
        #expect(upcomingAbsolute([eight], from: localDate(7), count: 0).isEmpty)
    }
}

// MARK: - The instant a wake falls on

/// The calendar, not the clock, settles when a wake is.
///
/// A wait measured between two times of day is an hour out on the two days of
/// the year when the clock changes, so these are written against a timezone
/// that has them: New York springs forward on 2026-03-08 and falls back on
/// 2026-11-01, whichever timezone the tests themselves run in.
@Suite struct WakeInstantTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    /// The day the clocks go forward, 02:00 does not exist. A 03:30 requirement
    /// is two hours away as the wall clock counts it, and one hour away as the
    /// hours pass.
    @Test func theInstantOfAWakeIsSettledByTheCalendarOnTheDayTheClocksGoForward() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 30))!
        let (wake, target) = nextWakeAbsolute(
            [TimeOfDay(hour: 3, minute: 30)], from: 5_400, on: date, calendar: calendar
        )!

        #expect(wake.delay == 7_200)
        #expect(target.timeIntervalSince(date) == 3_600)
    }

    /// The day the clocks go back, the hour between 01:00 and 02:00 happens
    /// twice. A 02:30 requirement is two hours away as the wall clock counts
    /// it, and three hours away as the hours pass.
    @Test func theInstantOfAWakeCountsTheHourTwiceWhenTheClocksGoBack() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 30))!
        let (wake, target) = nextWakeAbsolute(
            [TimeOfDay(hour: 2, minute: 30)], from: 1_800, on: date, calendar: calendar
        )!

        #expect(wake.delay == 7_200)
        #expect(target.timeIntervalSince(date) == 10_800)
    }

    /// On an ordinary day the two agree, which is what keeps the instant and
    /// the delay from disagreeing anywhere but the two days that matter.
    @Test func theInstantAndTheDelayAgreeOnAnOrdinaryDay() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 1, minute: 30))!
        let (wake, target) = nextWakeAbsolute(
            [TimeOfDay(hour: 3, minute: 30)], from: 5_400, on: date, calendar: calendar
        )!

        #expect(wake.delay == 7_200)
        #expect(target.timeIntervalSince(date) == 7_200)
    }

    /// A moment that has arrived is tomorrow's, by the same rule `nextWake`
    /// answers it with - including one that has arrived exactly.
    @Test func aMomentThatHasArrivedIsTomorrows() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 9, minute: 30))!
        let (wake, target) = nextWakeAbsolute(
            [TimeOfDay(hour: 9, minute: 0)], from: 9 * 3_600 + 30 * 60, on: date, calendar: calendar
        )!

        #expect(wake.delay == 86_400 - 30 * 60)
        #expect(target.timeIntervalSince(date) == 86_400 - 30 * 60)
    }

    @Test func hasNoInstantWithoutTimes() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 1, minute: 30))!
        #expect(nextWakeAbsolute([], from: 5_400, on: date, calendar: calendar) == nil)
    }
}

// MARK: - A zone without daylight saving

/// Mainland China has not observed daylight saving since 1991, and neither do
/// most of the world's zones. Where there is no change there is nothing to be
/// right about: the calendar is a plain calendar, and the instant of a wake is
/// the time of day it says it is.
///
/// These are written against the two nights another zone does change, because
/// that is where a program which had assumed the change - or assumed a
/// particular zone - would go wrong.
@Suite struct NoDaylightSavingTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    /// The night New York springs forward, 02:30 exists here and is as far away
    /// as the wall clock says it is.
    @Test func theNightAnotherZoneSpringsForwardIsAnOrdinaryNightHere() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 30))!
        let (wake, target) = nextWakeAbsolute(
            [TimeOfDay(hour: 2, minute: 30)], from: 5_400, on: date, calendar: calendar
        )!

        #expect(wake.at.rendered == "02:30")
        #expect(wake.delay == 3_600)
        #expect(target.timeIntervalSince(date) == 3_600)
    }

    /// The night New York falls back, the hour that happens twice there happens
    /// once, and the wait is the distance the wall clock says.
    @Test func theNightAnotherZoneFallsBackIsAnOrdinaryNightHere() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 30))!
        let (wake, target) = nextWakeAbsolute(
            [TimeOfDay(hour: 2, minute: 30)], from: 1_800, on: date, calendar: calendar
        )!

        #expect(wake.delay == 7_200)
        #expect(target.timeIntervalSince(date) == 7_200)
    }

    /// The same reading, in two zones, is not the same wait. That is the point:
    /// the system's timezone is what says when a requirement is, and the answer
    /// belongs to the zone it was asked in.
    @Test func theSameNightIsADifferentWaitInADifferentZone() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!

        let here = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 30))!
        let there = newYork.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 30))!

        let (wake, hereTarget) = nextWakeAbsolute(
            [TimeOfDay(hour: 2, minute: 30)], from: 1_800, on: here, calendar: calendar
        )!
        let (_, thereTarget) = nextWakeAbsolute(
            [TimeOfDay(hour: 2, minute: 30)], from: 1_800, on: there, calendar: newYork
        )!

        // Two hours here, three there: the hour that happens twice is waited
        // through only where it happens.
        #expect(wake.delay == 7_200)
        #expect(hereTarget.timeIntervalSince(here) == 7_200)
        #expect(thereTarget.timeIntervalSince(there) == 10_800)
    }
}

// MARK: - The plan, in the hours that will pass

/// `--dry-run` prints how long until each wake, and that number is the time
/// that will actually pass, not the difference between two times of day.
@Suite struct PlanTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    /// The night the clocks go forward, read at 01:30: a 03:30 requirement is
    /// two hours away as the wall clock counts it and one hour away as the
    /// hours pass. The plan prints the hour that passes.
    @Test func thePlanCountsTheHoursThatPassOnTheNightTheClocksGoForward() {
        let from = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 30))!
        let wakes = upcomingAbsolute(
            [TimeOfDay(hour: 3, minute: 30)], from: from, count: 2, calendar: calendar
        )

        #expect(wakes.count == 2)
        #expect(wakes[0].wake.at.rendered == "03:30")
        #expect(Int(wakes[0].target.timeIntervalSince(from)) == 3_600)
        // The next one is the skipped hour on top of the day, not the two
        // hours the wall clock would count between 01:30 and 03:30.
        #expect(Int(wakes[1].target.timeIntervalSince(from)) == 25 * 3_600)
    }
}

// MARK: - The lead window

@Suite struct LeadTests {
    @Test(arguments: [(9, 60), (16, 60), (21, 60), (22, 300), (2, 300), (7, 60), (0, 300)])
    func givesAMorningAMinuteAndAnEveningFive(hour: Int, expected: Int) {
        #expect(leadFor(hour: hour) == expected)
    }
}

// MARK: - Stepped sleeping

@Suite struct SleepSteppingTests {
    /// The wait is broken into steps because a monotonic timer stops while the
    /// system is suspended, so one long sleep returns late by however long the
    /// Mac was asleep.
    @Test func neverSleepsLongerThanOneStep() {
        #expect(nextSleepStep(target: 1_000, now: 100, budget: 3_600) == sleepStepSeconds)
        #expect(nextSleepStep(target: 105, now: 100, budget: 3_600) == 5)
    }

    @Test func stopsOnceTheTargetHasPassed() {
        #expect(nextSleepStep(target: 100, now: 100, budget: 3_600) == nil)
        #expect(nextSleepStep(target: 100, now: 200, budget: 3_600) == nil)
    }

    @Test func stopsWhenTheWallClockHasOutrunTheWait() {
        // budget and target stay in step because each step is subtracted from
        // both. So a distance larger than the budget can only mean the machine
        // slept through the step, and sleeping the rest would double the wait.
        #expect(nextSleepStep(target: 400, now: 100, budget: 10) == nil)
        #expect(nextSleepStep(target: 109, now: 100, budget: 10) == 9)
    }

    /// A machine that was asleep the whole way overshoots by more than a step.
    /// This is the case the stepping exists for: without it the loop would sleep
    /// for the full budget again and come back a second time.
    @Test func aWaitDoesNotSleepTwiceAfterAnOvershoot() {
        let machine = FakeMachine()
        machine.setClock(1_000)
        sleepSeconds(machine.effects, 300)
        #expect(machine.now == 1_300)
    }

    @Test func aLongWaitIsBrokenIntoSteps() {
        let machine = FakeMachine()
        machine.setClock(0)
        sleepSeconds(machine.effects, 300)
        #expect(machine.sleptFor == Array(repeating: sleepStepSeconds, count: 30))
    }

    @Test func waitsNothingForNothing() {
        let machine = FakeMachine()
        sleepSeconds(machine.effects, 0)
        sleepSeconds(machine.effects, -30)
        #expect(machine.sleptFor.isEmpty)
    }
}