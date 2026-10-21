import Foundation

// MARK: - The wall clock

/// Seconds since local midnight, which is the unit the whole scheduler speaks.
///
/// Local means the system's, read live: the calendar defaults to
/// `.autoupdatingCurrent`, which follows the machine's timezone setting while
/// this process runs. showup is a daemon and outlives a timezone change - the
/// Mac is carried to another zone, or a setting that was wrong is corrected -
/// and a requirement is a local moment, so it is read where the machine now
/// says it is. Which zone that is, is the machine's business: a zone with no
/// daylight saving, mainland China since 1991 among them, is a plain calendar
/// and there is nothing here for it to get wrong.
public func secondsSinceMidnight(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Int {
    Int(date.timeIntervalSince(calendar.startOfDay(for: date)))
}

/// `HH:MM:SS` from seconds since midnight, for the log.
public func clock(_ seconds: Int) -> String {
    String(format: "%02d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
}

/// The `MM/DD/YYYY HH:MM:SS` argument `pmset schedule wake` expects.
///
/// `Calendar` does the day arithmetic, so month lengths, leap years and
/// daylight saving are its problem and not this program's. It is the system's
/// calendar, followed live, which is also the zone `pmset` itself reads.
public func pmsetDatetime(now: Date, secondsFromNow: Int, calendar: Calendar = .autoupdatingCurrent) -> String {
    let target = now.addingTimeInterval(Double(secondsFromNow))
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: target)
    return String(
        format: "%02d/%02d/%04d %02d:%02d:%02d",
        parts.month ?? 0,
        parts.day ?? 0,
        parts.year ?? 0,
        parts.hour ?? 0,
        parts.minute ?? 0,
        parts.second ?? 0
    )
}

/// How long a wait reads to a person: `2h 5m`, `5m 3s`, `0s`.
public func describeDelay(_ delay: Int) -> String {
    var parts: [String] = []
    if delay / 3_600 > 0 { parts.append("\(delay / 3_600)h") }
    if delay / 60 % 60 > 0 { parts.append("\(delay / 60 % 60)m") }
    if delay % 60 > 0 { parts.append("\(delay % 60)s") }
    return parts.isEmpty ? "0s" : parts.joined(separator: " ")
}

/// Seconds from one time of day to another, counting forward round the clock,
/// so a wait that runs past midnight does not read as a negative.
public func secondsBetween(_ from: Int, _ to: Int) -> Int {
    let difference = to - from
    return difference < 0 ? difference + secondsPerDay : difference
}

// MARK: - Parsing times

public enum TimeParseError: Error, Equatable, CustomStringConvertible {
    /// Not a number at all, or too many colons.
    case malformed
    /// 25, or 24 with minutes after midnight.
    case hourOutOfRange
    case minuteOutOfRange
    /// The whole list was empty, as opposed to one empty entry inside it.
    case empty

    public var description: String {
        switch self {
        case .malformed: "malformed"
        case .hourOutOfRange: "hourOutOfRange"
        case .minuteOutOfRange: "minuteOutOfRange"
        case .empty: "empty"
        }
    }
}

/// `8`, `08`, `8:00`, `24:00`. A bare hour means the top of it.
public func parseTime(_ input: String) throws(TimeParseError) -> TimeOfDay {
    let parts = input.split(separator: ":", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count) else { throw TimeParseError.malformed }
    guard let hour = Int(parts[0]) else { throw TimeParseError.malformed }

    var minute = 0
    if parts.count == 2 {
        guard let parsed = Int(parts[1]) else { throw TimeParseError.malformed }
        minute = parsed
    }

    // 24:00 is the end of the day, which is the start of the next one.
    let normalised = hour == 24 && minute == 0 ? 0 : hour
    guard (0...23).contains(normalised) else { throw TimeParseError.hourOutOfRange }
    guard (0...59).contains(minute) else { throw TimeParseError.minuteOutOfRange }
    return TimeOfDay(hour: normalised, minute: minute)
}

/// A comma separated list. Spaces around each entry are forgiven, because the
/// shell hands over one argument whether or not the user quoted it.
public func parseTimeList(_ input: String) throws(TimeParseError) -> [TimeOfDay] {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw TimeParseError.empty }

    var times: [TimeOfDay] = []
    for entry in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
        times.append(try parseTime(entry.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    return times
}

/// Sorted, with repeats removed: `-t 9 -t 9` and `-t 9,9` mean the same thing.
public func normalise(_ times: [TimeOfDay]) -> [TimeOfDay] {
    Array(Set(times)).sorted()
}