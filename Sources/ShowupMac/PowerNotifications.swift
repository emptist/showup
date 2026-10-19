import Foundation
import IOKit
import IOKit.pwr_mgt
import ShowupCore

/// The IOKit message identifiers, spelled out because they are C macros the
/// Swift importer does not carry across.
///
/// IOMessage.h defines them as `iokit_common_msg(0x280)` and
/// `iokit_common_msg(0x300)`, which expands to
/// `sys_iokit | sub_iokit_common | n` — that is `err_system(0x38) | err_sub(0) | n`.
private enum IOKitMessage {
    static let willSleep = UInt32(0xe0000280)  // kIOMessageSystemWillSleep
    static let hasPoweredOn = UInt32(0xe0000300)  // kIOMessageSystemHasPoweredOn
}

/// Apple's own sleep and wake notifications, from the root power domain.
///
/// `IORegisterForSystemPower` is documented to deliver:
/// - `kIOMessageSystemWillSleep` "at the point the system is initiating a
///   non-abortable sleep". Must be acknowledged with `IOAllowPowerChange`; not
///   acknowledging it stalls the sleep for thirty seconds.
/// - `kIOMessageSystemWillPowerOn` "at early wakeup time, before most hardware
///   has been powered on". Must not be acknowledged.
/// - `kIOMessageSystemHasPoweredOn` "at wakeup completion time, after all device
///   drivers and hardware have handled the wakeup event". Must not be
///   acknowledged.
///
/// A DarkWake is abortable and never completes a wake, so it produces neither
/// of the first or last messages. That is the question the alarm needs answered,
/// asked of the kernel rather than inferred from a log line powerd may not have
/// written yet.
public final class PowerNotifications: @unchecked Sendable {
    private let lock = NSLock()
    private var cycle = PowerCycle()
    private var notifier: UInt32 = 0
    private var port: OpaquePointer?
    private var rootPort: UInt32 = 0

    /// One registration for the life of the process, since registration is a
    /// connection to the root power domain and there is no reason to make two.
    public static let shared: PowerNotifications? = PowerNotifications()

    /// Nil when the system would not let us listen, which has to fall back on
    /// something else rather than be taken as an answer.
    public init?() {
        var notifier: UInt32 = 0
        var port: OpaquePointer?

        let rootPort = withUnsafeMutablePointer(to: &notifier) { notifier in
            IORegisterForSystemPower(
                Unmanaged.passUnretained(self).toOpaque(),
                &port,
                { refcon, _, message, argument in
                    guard let refcon else { return }
                    Unmanaged<PowerNotifications>
                        .fromOpaque(refcon)
                        .takeUnretainedValue()
                        .record(message, notificationID: argument.map(Int.init) ?? 0)
                },
                notifier
            )
        }

        guard rootPort != UInt32(io_object_t(MACH_PORT_NULL)), let port else {
            if let port { IONotificationPortDestroy(port) }
            return nil
        }

        self.rootPort = rootPort
        self.notifier = notifier
        self.port = port

        // A dispatch queue rather than a run loop source: showup blocks in
        // Thread.sleep, so nothing is ever going to service a run loop.
        IONotificationPortSetDispatchQueue(port, DispatchQueue(label: "showup.power"))
    }

    deinit {
        var notifier = self.notifier
        if notifier != 0 { _ = IODeregisterForSystemPower(&notifier) }
        if let port { IONotificationPortDestroy(port) }
    }

    private func record(_ message: UInt32, notificationID: Int) {
        lock.withLock {
            switch message {
            case IOKitMessage.willSleep:
                // Without this the system waits thirty seconds and then sleeps
                // anyway. Apple is blunt about it.
                _ = IOAllowPowerChange(rootPort, notificationID)
                cycle.willSleep = true
            case IOKitMessage.hasPoweredOn:
                cycle.hasPoweredOn = true
            default:
                break  // will-power-on: return without acknowledging
            }
        }
    }

    /// What has been announced since this was last taken, clearing the flags so
    /// the next cycle starts from nothing.
    public func takeCycle() -> PowerCycle {
        lock.withLock {
            let taken = cycle
            cycle = PowerCycle()
            return taken
        }
    }
}