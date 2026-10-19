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

    private init() {}

    /// Asks the kernel to bring the Mac back in that many seconds.
    ///
    /// Any wake still armed from the previous pass is taken back first: the
    /// alarm is one alarm, not a queue of them.
    public func schedule(in seconds: Int) -> Result<Void, ShowError> {
        cancel()

        let when = Date().addingTimeInterval(Double(seconds))
        let status = IOPMSchedulePowerEvent(when as CFDate, identifier, kIOPMAutoWake as CFString)
        guard status == kIOReturnSuccess else {
            return .failure(
                .failed(command: "IOPMSchedulePowerEvent", status: status, detail: "this needs root")
            )
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