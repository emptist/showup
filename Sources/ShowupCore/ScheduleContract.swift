import Foundation

/// The contract between the two sides of the install: the schedule the user
/// side owns, and the renewal side owes.
///
/// Every armable user run writes it on ground it owns - the same directory
/// the instance lock lives in, this file next to `showup.lock` - and the
/// renewal (`showup renew`, run as root) reads it back from there. A schedule
/// change stays an ordinary user act because of this file: the run decides
/// the schedule afresh each time, the renewal re-reads it each cycle, and no
/// password sits in between.
///
/// The format is what the CLI already accepts, one field a line, after its
/// name:
///
///     app Finder
///     times 04:00,08:00
///
/// Anything else is an error, never a warning: the renewal refuses to guess,
/// because a guessed schedule is a Mac that wakes for the wrong reasons. An
/// app name with spaces survives as one value, because only the first space
/// separates a field from its value. One legacy line is the exception: a
/// contract from before the ring became the work carries a `ring yes|no`
/// line. It is read and dropped. The option it stood for no longer exists -
/// the wake either rings the person back or there is no fetch at all - and
/// the next write of the contract leaves the line out.
public struct ScheduleContract: Equatable {
    public static let fileName = "schedule.txt"

    /// The application the night run surfaces. Recorded whole, so the file
    /// stays one honest record of the decision; the kernel hours live in
    /// `times`.
    public var app: String
    public var times: [TimeOfDay]

    public init(app: String, times: [TimeOfDay]) {
        self.app = app
        self.times = times
    }

    /// What a wrong contract says about itself: always its field, by name.
    public enum ReaderError: Error, Equatable, CustomStringConvertible {
        case unnamed(line: String)
        case missingField(name: String)
        case repeatedField(name: String)
        case badValue(field: String, value: String)

        public var description: String {
            switch self {
            case .unnamed(let line):
                "a line in the contract owns no field: \"\(line)\""
            case .missingField(name: let name):
                "the contract has no \(name) line, and both are the schedule"
            case .repeatedField(name: let name):
                "the contract says \(name) twice, and a schedule answers each field once"
            case .badValue(field: let field, value: let value):
                "the contract's \(field) line holds a value it cannot honor: \"\(value)\""
            }
        }
    }

    /// The contract as the file holds it: two lines, in this order.
    public func render() -> String {
        let times = self.times.map { $0.rendered }.joined(separator: ",")
        return "app \(app)\ntimes \(times)\n"
    }

    /// Reads a contract back from the file's text.
    ///
    /// Missing, repeated, unknown or unparseable fields are errors that name
    /// themselves. The times come back normalised, the way every schedule
    /// comes back: sorted, without repeats.
    public static func read(_ text: String) throws -> ScheduleContract {
        var app: String?
        var times: [TimeOfDay]?

        for rawLine in text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n") {
            let line = String(rawLine)
            guard let space = line.firstIndex(of: " ") else {
                throw ReaderError.unnamed(line: line)
            }
            let name = String(line[..<space])
            let value = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            switch name {
            case "app":
                guard app == nil else { throw ReaderError.repeatedField(name: "app") }
                guard !value.isEmpty else { throw ReaderError.badValue(field: "app", value: line) }
                app = value
            case "times":
                guard times == nil else { throw ReaderError.repeatedField(name: "times") }
                do {
                    times = try parseTimeList(value)
                } catch {
                    throw ReaderError.badValue(field: "times", value: value)
                }
            case "ring":
                // The line an older contract wrote for an option that no
                // longer exists. A `yes` or `no` is history, not a schedule;
                // anything else is still a contract that names what it holds.
                guard value == "yes" || value == "no" else {
                    throw ReaderError.badValue(field: "ring", value: value)
                }
            default:
                throw ReaderError.unnamed(line: line)
            }
        }

        guard let app else { throw ReaderError.missingField(name: "app") }
        guard let times else { throw ReaderError.missingField(name: "times") }
        return ScheduleContract(app: app, times: normalise(times))
    }
}
