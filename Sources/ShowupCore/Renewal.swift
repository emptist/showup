import Foundation

/// A wake on the kernel list as it is read back: the instant it settles the
/// machine at, and the name the kernel records the program under.
///
/// The renewal only ever works with the events whose name is showup's own
/// tag. Another program's wake belongs to that program, and none of it is
/// cancelled wholesale - the list is read as witnesses, not as a holding.
public struct OwnedWake: Equatable, Hashable {
    public var at: Date
    public var owner: String

    public init(at: Date, owner: String) {
        self.at = at
        self.owner = owner
    }
}

/// The name every wake the renewal arms carries - the same one the night
/// run's own act has always used, which is what keeps cancel and re-arm
/// matched pairs instead of a sweep.
public let renewalTag = "com.showup.wake"

/// The plan of a renewal, as a pure question with an exact answer: given the
/// moments the contract owes, the wakes the kernel currently holds, and the
/// instant the renewal is running at, what is taken back and what is armed.
///
/// Cancellation reaches only wakes showup armed itself, matched by the tag
/// and the exact instant. Arming reaches every still-future requested moment
/// the list does not already hold - reachability is owned, not borrowed, so
/// a coincidental wake another program holds never stands in for one of
/// showup's. A request whose moment has passed is spent: said nothing about,
/// armed for nothing, because the window it was for has already run.
///
/// The plan is idempotent by construction: the same three inputs give the
/// same plan, and once the plan has been acted on, the next plan with the
/// same contract is no actions at all. What is owed equals what is armed;
/// that equality is the whole point of running the renewal every cycle.
public func planRenewal(
    requested: [Date], armed: [OwnedWake], now: Date
) -> (cancel: [OwnedWake], arm: [Date]) {
    let ours = armed.filter { $0.owner == renewalTag }
    let owed = Set(requested.filter { $0 > now })
    let cancel = ours.filter { !owed.contains($0.at) }.sorted { $0.at < $1.at }
    let arm = owed.subtracting(Set(ours.map { $0.at })).sorted()
    return (cancel: cancel, arm: arm)
}

/// The instants the kernel is asked to settle the machine at, read the way
/// the night scheduler reads times: the next occurrence of each contract
/// time, settled on the calendar, then pulled forward by that hour's own
/// lead - the wake exists to open the lead window, so the arm sits at the
/// window's mouth, not at the minute the app belongs to. A moment arriving
/// exactly now is tomorrow's by the same rule `nextWakeAbsolute` answers
/// every schedule with; the lead comes off the settled instant, and on a
/// clock-change night the calendar's own answer for the hour settles the
/// mouth the same way it settles the moment.
///
/// The two clock-change nights are the calendar's business here because they
/// are the calendar's business everywhere else - an hour that exists twice
/// keeps its earlier half, an hour that does not exist rolls to the next
/// one, and nothing is invented to fill either.
public func requestedMoments(
    times: [TimeOfDay], now: Date, calendar: Calendar = .autoupdatingCurrent
) -> [Date] {
    let mouths = normalise(times).compactMap { at -> Date? in
        guard let today = calendar.date(bySettingHour: at.hour, minute: at.minute, second: 0, of: now) else {
            return nil
        }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }
    return mouths
        .map { $0.addingTimeInterval(-Double(leadFor(hour: calendar.component(.hour, from: $0)))) }
        .sorted()
}
