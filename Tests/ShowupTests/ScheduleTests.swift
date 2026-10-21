import Testing
@testable import ShowupCore

// MARK: - Choosing the next wake

@Suite struct ScheduleTests {
    let noon = TimeOfDay(hour: 12, minute: 0)
    let nine = TimeOfDay(hour: 9, minute: 0)
    let eight = TimeOfDay(hour: 8, minute: 0)
    let seven = TimeOfDay(hour: 7, minute: 0)
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

    @Test func listsTheNextWakesInOrder() {
        let times = [eight, noon, twenty]
        #expect(upcoming(times, from: seven.secondsSinceMidnight, count: 4).map(\.at.rendered) == ["08:00", "12:00", "20:00", "08:00"])
    }

    @Test func keepsRepeatingOverSeveralDays() {
        let times = [noon, twenty]
        let wakes = upcoming(times, from: nine.secondsSinceMidnight, count: 4)
        #expect(wakes.map(\.at.rendered) == ["12:00", "20:00", "12:00", "20:00"])
        #expect(wakes.map(\.delay) == [3 * 3_600, 8 * 3_600, 16 * 3_600, 8 * 3_600])
    }

    @Test func listsNothingWhenAskedForNothing() {
        #expect(upcoming([eight], from: 0, count: 0) == [])
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