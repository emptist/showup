import Foundation
import IOKit
import IOKit.pwr_mgt
import ShowupCore

extension ScheduledWake {
    /// Arms one one-shot wake at a calendar instant, under the renewal tag.
    ///
    /// The night run's own `schedule(in:)` takes its previous wake back first
    /// and notes the instant for the exit take-back, because it works pass by
    /// pass. The renewal is bookkept by `planRenewal` instead - the plan is
    /// the discipline - so this is only the kernel ask: no cancels first, no
    /// process note, and the event expires when it is used.
    ///
    /// A refusal is kept in the shape the warn route already knows; the
    /// renewal runs as root, where such a refusal means the kernel has
    /// spoken, not that an identity was missing.
    public func arm(at instant: Date) -> Result<Void, ShowError> {
        let status = IOPMSchedulePowerEvent(instant as CFDate, renewalTag as CFString, kIOPMAutoWake as CFString)
        guard status == kIOReturnSuccess else {
            return .failure(
                .failed(command: "IOPMSchedulePowerEvent", status: status, detail: "this needs root")
            )
        }
        return .success(())
    }

    /// Cancels exactly one armed wake, matched by the pair the kernel keeps:
    /// the instant and the name of the program that armed it. Returns whether
    /// the kernel accepted the cancel, so the renewal can say what happened
    /// on the list rather than assume it happened.
    @discardableResult
    public func cancel(wake: OwnedWake) -> Bool {
        IOPMCancelScheduledPowerEvent(
            wake.at as CFDate, wake.owner as CFString, kIOPMAutoWake as CFString
        ) == kIOReturnSuccess
    }
}

/// Runs one renewal against the schedule contract at the given path, as root.
///
/// The reading comes first, and the kernel list is touched only by the plan:
/// `planRenewal` - the one RenewalTests judge - says what is taken back and
/// what is armed, and every action is reported as it happens, to stderr.
///
/// The stderr is deliberate and it is the renewal's whole story: under the
/// daemon, launchd captures this stream onto the user's own ground, so the
/// audible acts land next to the run's logs - one visible story, on the
/// ground the person reads. A renew that narrated into root's own ground
/// would be telling its story two homes away from the logs it matters to.
/// A contract that cannot be read is a refusal that says the useful thing,
/// and no kernel act happens for it: renew is not the place the file is
/// repaired, it is the place the file is honored.
///
/// The return is the exit code: 0 when the plan was acted on whole, 1 when a
/// refusal of any kind stopped it before any act.
public func runRenewal(contractDirectory: String) -> Int {
    let path = contractDirectory + "/" + ScheduleContract.fileName
    let contract: ScheduleContract
    do {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        contract = try ScheduleContract.read(text)
    } catch let error as ScheduleContract.ReaderError {
        renewalSays("\(error)")
        return 1
    } catch {
        renewalSays("cannot read the renewal contract at \(path): \(error)")
        return 1
    }

    let now = Date()
    let plan = planRenewal(
        requested: requestedMoments(times: contract.times, now: now),
        armed: ScheduledWake.shared.armedWakes().map { OwnedWake(at: $0.when, owner: $0.owner) },
        now: now
    )

    renewalSays(
        "renewal from \(path): app \(contract.app), times "
            + contract.times.map { $0.rendered }.joined(separator: ",")
    )

    guard !(plan.cancel.isEmpty && plan.arm.isEmpty) else {
        renewalSays("the list already holds exactly what the contract owes; nothing to act on")
        return 0
    }

    var actedWhole = true
    for wake in plan.cancel {
        if ScheduledWake.shared.cancel(wake: wake) {
            renewalSays("took back the wake of ours at \(renewalInstant(wake.at))")
        } else {
            renewalSays("WARNING the kernel did not take back the wake at \(renewalInstant(wake.at)); the next renewal tries again")
            actedWhole = false
        }
    }
    for at in plan.arm {
        switch ScheduledWake.shared.arm(at: at) {
        case .success:
            renewalSays("armed the wake for the contract's \(renewalInstant(at))")
        case .failure(let reason):
            renewalSays("WARNING \(reason); the next renewal tries again")
            actedWhole = false
        }
    }
    return actedWhole ? 0 : 1
}

/// The renewal's one speaking line at a time, out on stderr.
private func renewalSays(_ line: String) {
    FileHandle.standardError.write(Data("showup: \(line)\n".utf8))
}

/// The instant as the renewal says it in the log: the date and the time the
/// machine's own zone puts on it, so a wake for 04:00 is read as 04:00.
private func renewalInstant(_ date: Date) -> String {
    let format = DateFormatter()
    format.timeZone = .autoupdatingCurrent
    format.dateFormat = "yyyy-MM-dd HH:mm"
    return format.string(from: date)
}
