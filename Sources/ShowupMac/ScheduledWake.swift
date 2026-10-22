import Foundation
import IOKit
import IOKit.pwr_mgt
import ShowupCore

/// The RTC wake, and the business of taking it back.
///
/// `IOPMSchedulePowerEvent` is the documented way to ask the kernel to wake the
/// Mac, and it needs root, which is the same requirement `pmset schedule wake`
/// had. `pmset` also recorded itself as `scheduledby = pmset`, which made a
/// leftover indistinguishable from anybody else's alarm; the identifier here is
/// ours.
///
/// Leaving an alarm armed is a defect, not a tidiness question. An earlier
/// version asked for a wake on every pass and never took one back, so Ctrl-C
/// left the Mac armed to wake at a time nobody was expecting.
/// `IOPMCopyScheduledPowerEvents` is how that was found: six of them, from six
/// runs that had already exited.
public final class ScheduledWake: @unchecked Sendable {
    public static let shared = ScheduledWake()

    /// The identifier every event showup schedules carries. Cancelling needs the
    /// same one, and the same time, as the schedule used.
    private let identifier = "com.showup.wake" as CFString

    private let lock = NSLock()
    private var scheduledFor: Date?

    /// Whether this run has said the handoff line for not owning the kernel
    /// act. The refusal at `schedule`, the skip in the leftover take-back and
    /// the skip on the way out are all one standing fact, and the run says it
    /// once: the first time anything tries anyway.
    private var handoffSaid = false

    private init() {}

    /// The handoff line, for exactly one ask per run.
    ///
    /// The take-back sites live outside this type's own logging - they log in
    /// the entry file - so they ask here for the words. The first site that
    /// asks gets the line; every later ask is nil, because the fact is already
    /// on record. Root never needs it.
    public func wakeHandoffLine() -> String? {
        lock.withLock {
            if handoffSaid { return nil }
            handoffSaid = true
            return ShowError.wakeIsNotOurs(announced: true).description
        }
    }

    /// Asks the kernel to bring the Mac back in that many seconds.
    ///
    /// Any wake still armed from the previous pass is taken back first: the
    /// alarm is one alarm, not a queue of them.
    ///
    /// A refusal on the user path is the designed handoff, not a failure: the
    /// error carries `announced` once, at the run's first refusal, and the
    /// scheduling site logs the line for that one and carries on. Refusals
    /// after that are the same standing fact, already said.
    public func schedule(in seconds: Int) -> Result<Void, ShowError> {
        cancel()

        let when = Date().addingTimeInterval(Double(seconds))
        let status = IOPMSchedulePowerEvent(when as CFDate, identifier, kIOPMAutoWake as CFString)
        guard status == kIOReturnSuccess else {
            return .failure(.wakeIsNotOurs(announced: lock.withLock {
                let first = !handoffSaid
                handoffSaid = true
                return first
            }))
        }
        lock.withLock { scheduledFor = when }
        return .success(())
    }

    /// Takes back the wake this process asked for, if any.
    public func cancel() {
        let when: Date? = lock.withLock {
            let taken = scheduledFor
            scheduledFor = nil
            return taken
        }
        guard let when else { return }
        _ = IOPMCancelScheduledPowerEvent(when as CFDate, identifier, kIOPMAutoWake as CFString)
    }

    /// Takes back every wake still armed under this program's identifier.
    ///
    /// The stop handler only answers signals, so a run killed outright - a
    /// `kill -9`, or a crash - leaves its wake armed and nobody to take it
    /// back. Measured: one run left theirs armed for two days, and the Mac
    /// woke for it alone. Nothing else may hold this identifier while the
    /// single-instance lock is ours, so anything left under it is a leftover:
    /// taken back here rather than recorded in a file that would have to
    /// survive the same kill.
    ///
    /// The sweep is a root act - cancelling is the same privilege as
    /// scheduling - so a run without it does nothing here and says the
    /// standing handoff from its own site instead. Nothing was armed by runs
    /// like it either, so there is nothing of ours for the kernel to keep.
    public func takeBackLeftovers() {
        guard Ground.isRoot else { return }
        let ours = armedWakes().filter { $0.owner == identifier as String }
        for wake in ours {
            _ = IOPMCancelScheduledPowerEvent(
                wake.when as CFDate, identifier, kIOPMAutoWake as CFString
            )
        }
    }

    /// Every RTC wake currently armed, so a leftover can be seen rather than
    /// discovered later as a Mac that wakes up for no reason.
    public func armedWakes() -> [(when: Date, owner: String)] {
        guard let events = IOPMCopyScheduledPowerEvents()?.takeRetainedValue(),
            let all = events as? [[String: Any]]
        else {
            return []
        }
        return all.compactMap { event in
            guard let when = event[kIOPMPowerEventTimeKey as String] as? Date,
                let owner = event[kIOPMPowerEventAppNameKey as String] as? String
            else {
                return nil
            }
            return (when, owner)
        }
    }
}