/// What the kernel announced over a sleep and wake.
///
/// `IORegisterForSystemPower` sends `kIOMessageSystemWillSleep` at the point
/// the system begins a **non-abortable** sleep, and `kIOMessageSystemHasPoweredOn`
/// at **wakeup completion**. A DarkWake is abortable and never completes a wake,
/// so it produces neither: this is the kernel distinguishing them, rather than
/// showup inferring it from a log powerd may not have written yet.
public struct PowerCycle: Equatable, Sendable {
    public var willSleep = false
    public var hasPoweredOn = false

    public init(willSleep: Bool = false, hasPoweredOn: Bool = false) {
        self.willSleep = willSleep
        self.hasPoweredOn = hasPoweredOn
    }

    /// A real sleep that also completed a wake. This is the only state in which
    /// ringing is worth anything.
    public var completedFullWake: Bool { willSleep && hasPoweredOn }
}
