import Foundation
import Testing
@testable import ShowupCore

/// The renewal's pure planner: given what the contract owes, what the kernel
/// holds, and when the renewal runs, exactly what is taken back and what is
/// armed - judged here, without a kernel, so the daemon only ever executes a
/// plan the tests already blessed.
///
/// One habit runs through all of these: the planner reaches only the wakes
/// whose owner is showup's own tag. Every other wake on the list is somebody
/// else's, and a plan that touched it would be the plan of a program that
/// answers for something it does not hold.
@Suite struct RenewalTests {
    let tag = renewalTag

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    @Test func thePlanCancelsOnlyWhatItOwns() {
        let ours = Date(timeIntervalSince1970: 1_700_000_000 + 3_600)
        let theirsFirst = Date(timeIntervalSince1970: 1_700_000_000 + 7_200)
        let theirsSecond = Date(timeIntervalSince1970: 1_700_000_000 + 10_800)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let plan = planRenewal(
            requested: [],
            armed: [
                OwnedWake(at: theirsFirst, owner: "com.apple.acmd.alarm"),
                OwnedWake(at: theirsSecond, owner: "com.apple.alarm.travel"),
                OwnedWake(at: ours, owner: tag),
            ],
            now: now
        )

        #expect(plan.cancel == [OwnedWake(at: ours, owner: tag)])
        #expect(plan.arm == [])
    }

    @Test func theListAlreadyHoldingWhatItOwesRunsAPlanOfNothing() {
        let owed = Date(timeIntervalSince1970: 1_700_000_000 + 3_600)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let plan = planRenewal(
            requested: [owed],
            armed: [OwnedWake(at: owed, owner: tag)],
            now: now
        )

        #expect(plan.cancel == [])
        #expect(plan.arm == [])
    }

    @Test func thePlanArmsWhatItOwesAndLeavesWhatIsArmed() {
        let first = Date(timeIntervalSince1970: 1_700_000_000 + 3_600)
        let second = Date(timeIntervalSince1970: 1_700_000_000 + 7_200)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let plan = planRenewal(
            requested: [first, second],
            armed: [OwnedWake(at: first, owner: tag)],
            now: now
        )

        #expect(plan.cancel == [])
        #expect(plan.arm == [second])
    }

    @Test func aSpentRequestIsNotArmedAndItsLingerIsTakenBack() {
        let spent = Date(timeIntervalSince1970: 1_700_000_000 - 60)
        let next = Date(timeIntervalSince1970: 1_700_000_000 + 3_600)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let plan = planRenewal(
            requested: [spent, next],
            armed: [OwnedWake(at: spent, owner: tag)],
            now: now
        )

        #expect(plan.cancel == [OwnedWake(at: spent, owner: tag)])
        #expect(plan.arm == [next])
    }

    @Test func aRequestArrivingExactlyAtNowIsSpent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let plan = planRenewal(
            requested: [now],
            armed: [OwnedWake(at: now, owner: tag)],
            now: now
        )

        #expect(plan.cancel == [OwnedWake(at: now, owner: tag)])
        #expect(plan.arm == [])
    }

    @Test func aCoincidentalWakeAtASpokeMomentDoesNotStandInForOneOfOurs() {
        let owed = Date(timeIntervalSince1970: 1_700_000_000 + 3_600)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let plan = planRenewal(
            requested: [owed],
            armed: [OwnedWake(at: owed, owner: "com.apple.alarm.travel")],
            now: now
        )

        #expect(plan.cancel == [])
        #expect(plan.arm == [owed])
    }

    /// Acting on the plan is not the planner's business, but what it owes the
    /// caller is verifiability: once the plan has been acted on, the same
    /// contract re-read at a second now - the sixty seconds later, say, that
    /// a retry would run at - plans nothing, for as long as the owed moments
    /// stay future.
    @Test func thePlanIsIdempotentAcrossTwoNows() {
        let owed = Date(timeIntervalSince1970: 1_700_000_000 + 3_600)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let first = planRenewal(requested: [owed], armed: [], now: now)
        #expect(first.cancel == [])
        #expect(first.arm == [owed])

        let second = planRenewal(
            requested: [owed],
            armed: first.arm.map { OwnedWake(at: $0, owner: tag) },
            now: now.addingTimeInterval(60)
        )

        #expect(second.cancel == [])
        #expect(second.arm == [])
    }

    /// A moment arriving exactly at the instant the reading is taken is
    /// tomorrow's, by the same rule the scheduler answers every schedule
    /// with, so the same window is never served twice.
    @Test func theMomentOfATimeArrivingExactlyIsTomorrowSameTime() throws {        let calendar = calendar("UTC")
        let atTheMoment = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 8, hour: 4, minute: 0
        )))
        let tomorrowSameTime = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 9, hour: 4, minute: 0
        )))

        let moments = requestedMoments(
            times: [TimeOfDay(hour: 4, minute: 0)], now: atTheMoment, calendar: calendar
        )

        #expect(moments == [tomorrowSameTime])
    }

    /// A time of day already gone is tomorrow's, which is what makes a
    /// 04:00 contract held at 23:00 arm for the 04:00 that is coming rather
    /// than the one that has already been served.
    @Test func theMomentsOfAPastTimeFallTomorrow() throws {
        let calendar = calendar("UTC")
        let lateEvening = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 8, hour: 23
        )))
        let nextMorning = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 9, hour: 4, minute: 0
        )))

        let moments = requestedMoments(
            times: [TimeOfDay(hour: 4, minute: 0)], now: lateEvening, calendar: calendar
        )

        #expect(moments == [nextMorning])
    }

    /// On the night the clocks lose an hour, an hour of the morning does not
    /// exist. The calendar answers a requirement for it with the instant the
    /// day resumes - one instant, no invention - and `requestedMoments` uses
    /// the same `bySettingHour` call `nextWakeAbsolute` has always used, so
    /// the renewal's answer is the night run's answer, not a new opinion.
    @Test func aNonexistentHourOnTheSpringNightIsTheCalendarsOwnAnswer() throws {
        let calendar = calendar("America/New_York")
        let stillWinter = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 8, hour: 1, minute: 30
        )))
        // The calendar's answer to "02:30" on this night: 03:00, the instant
        // the hour that exists begins.
        let theResumedInstant = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 8, hour: 3, minute: 0
        )))

        let moments = requestedMoments(
            times: [TimeOfDay(hour: 2, minute: 30)], now: stillWinter, calendar: calendar
        )

        #expect(moments == [theResumedInstant])
        #expect(moments.first!.timeIntervalSince(stillWinter) == 1_800)
    }

    /// On the night the clocks gain an hour back, one hour of the morning
    /// exists twice. The owed instant is the first one - the early half is
    /// when the requirement next happens, and the second pass belongs to
    /// nobody.
    @Test func aRepeatedHourOnTheAutumnNightKeepsItsEarlierHalf() throws {
        let calendar = calendar("America/New_York")
        let beforeTheHour = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 1, hour: 0, minute: 30
        )))
        let theEarlyHalf = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 1, hour: 1, minute: 30
        )))

        let moments = requestedMoments(
            times: [TimeOfDay(hour: 1, minute: 30)], now: beforeTheHour, calendar: calendar
        )

        #expect(moments == [theEarlyHalf])
    }
}
