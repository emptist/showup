import Foundation
import Testing
@testable import ShowupCore

// MARK: - Times

@Suite struct TimeParsingTests {
    // `try` is hoisted out of `#expect` throughout: a typed throw inside the
    // macro expansion sends the type checker round in circles.

    @Test func parsesTheFormsTheHelpTextPromises() throws {
        let bare = try parseTime("8")
        let padded = try parseTime("08")
        let halfPast = try parseTime("08:30")
        let singleDigitMinute = try parseTime("8:05")
        let midnight = try parseTime("0:00")

        #expect(bare == TimeOfDay(hour: 8, minute: 0))
        #expect(padded == bare)
        #expect(halfPast == TimeOfDay(hour: 8, minute: 30))
        #expect(singleDigitMinute == TimeOfDay(hour: 8, minute: 5))
        #expect(midnight == TimeOfDay(hour: 0, minute: 0))
    }

    @Test func readsTheEndOfTheDayAsMidnight() throws {
        let endOfDay = try parseTime("24:00")
        #expect(endOfDay == TimeOfDay(hour: 0, minute: 0))
    }

    @Test(arguments: [
        ("24:30", TimeParseError.hourOutOfRange),
        ("25:00", TimeParseError.hourOutOfRange),
        ("-1", TimeParseError.hourOutOfRange),
        ("8:60", TimeParseError.minuteOutOfRange),
        ("8:-1", TimeParseError.minuteOutOfRange),
        ("noon", TimeParseError.malformed),
        ("", TimeParseError.malformed),
        ("8:00:00", TimeParseError.malformed),
        ("8:", TimeParseError.malformed),
    ])
    func rejectsWhatItCannotRead(input: String, expected: TimeParseError) {
        #expect(throws: expected) { try parseTime(input) }
    }

    @Test func parsesAList() throws {
        let times = try parseTimeList("8:00,12:00,20:00")
        #expect(times.map(\.rendered) == ["08:00", "12:00", "20:00"])
    }

    @Test func forgivesSpacesAroundEntries() throws {
        // A quoted "8:00, 12:00" arrives as one argument with spaces in it.
        let times = try parseTimeList(" 8:00 , 12:00 ")
        #expect(times.map(\.rendered) == ["08:00", "12:00"])
    }

    @Test func rejectsAnEmptyListAndAnEmptyEntry() {
        #expect(throws: TimeParseError.empty) { try parseTimeList("   ") }
        #expect(throws: TimeParseError.malformed) { try parseTimeList("8:00,") }
    }

    @Test func sortsAndRemovesRepeats() {
        let input = [
            TimeOfDay(hour: 20, minute: 0),
            TimeOfDay(hour: 8, minute: 0),
            TimeOfDay(hour: 20, minute: 0),
            TimeOfDay(hour: 12, minute: 0),
        ]
        #expect(normalise(input).map(\.rendered) == ["08:00", "12:00", "20:00"])
    }
}

// MARK: - The wall clock

struct Delay: Sendable, CustomTestStringConvertible {
    let seconds: Int
    let expected: String
    init(_ seconds: Int, _ expected: String) {
        self.seconds = seconds
        self.expected = expected
    }
    var testDescription: String { expected }
}

@Suite struct ClockTests {
    @Test func rendersHoursMinutesAndSeconds() {
        #expect(clock(3 * 3_600 + 5 * 60 + 7) == "03:05:07")
        #expect(clock(0) == "00:00:00")
    }

    @Test(arguments: [
        Delay(0, "0s"),
        Delay(9, "9s"),
        Delay(303, "5m 3s"),
        Delay(3_900, "1h 5m"),
        Delay(10_800, "3h"),
        Delay(86_400, "24h"),
    ])
    func describesADelayTheWayAPersonReadsIt(_ delay: Delay) {
        #expect(describeDelay(delay.seconds) == delay.expected)
    }

    @Test func countsForwardRoundTheClock() {
        #expect(secondsBetween(23 * 3_600 + 55 * 60, 2 * 60) == 7 * 60)
        #expect(secondsBetween(100, 100) == 0)
    }

    @Test func readsSecondsSinceLocalMidnight() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let threeOhSeventeen = Date(timeIntervalSince1970: 3 * 3_600 + 17 * 60)
        #expect(secondsSinceMidnight(threeOhSeventeen, calendar: utc) == 3 * 3_600 + 17 * 60)
    }

    /// The format `pmset schedule wake` takes, checked across a month boundary
    /// so the date arithmetic has to be real rather than "add a day".
    @Test func formatsThePmsetArgument() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        let jan31 = Date(timeIntervalSince1970: 1_769_817_600) // 2026-01-31 00:00:00 UTC
        #expect(pmsetDatetime(now: jan31, secondsFromNow: 0, calendar: utc) == "01/31/2026 00:00:00")
        #expect(pmsetDatetime(now: jan31, secondsFromNow: 60, calendar: utc) == "01/31/2026 00:01:00")
        #expect(pmsetDatetime(now: jan31, secondsFromNow: 24 * 3_600, calendar: utc) == "02/01/2026 00:00:00")
        #expect(pmsetDatetime(now: jan31, secondsFromNow: 59, calendar: utc) == "01/31/2026 00:00:59")
    }

    /// 2028 is a leap year and 2027 is not, and February is the only month that
    /// has ever caught a hand written day counter.
    @Test func crossesFebruaryCorrectly() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        let nonLeap = Date(timeIntervalSince1970: 1_803_772_800) // 2027-02-28 00:00:00 UTC
        let leap = Date(timeIntervalSince1970: 1_835_308_800) // 2028-02-28 00:00:00 UTC
        #expect(pmsetDatetime(now: nonLeap, secondsFromNow: 24 * 3_600, calendar: utc) == "03/01/2027 00:00:00")
        #expect(pmsetDatetime(now: leap, secondsFromNow: 24 * 3_600, calendar: utc) == "02/29/2028 00:00:00")
    }
}