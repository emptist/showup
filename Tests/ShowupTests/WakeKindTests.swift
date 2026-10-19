import Testing
@testable import ShowupCore

/// Verbatim from `pmset -g log` on this Mac, from the morning the sleep test
/// ran. The four DarkWakes at 40 second intervals are the real thing: the Mac
/// ran them while it was asleep, and showup slept straight through them.
private let realWakeLog = """
    2026-10-19 10:32:02 +0800 Assertions           \tPID 600(powerd) Created InternalPreventSleep "com.apple.powermanagement.darkwakelinger" 00:00:00  id:0x0xd00009262 [System: PrevIdle DeclUser SRPrevSleep kCPU kDisp]
    2026-10-19 10:32:07 +0800 Assertions           \tPID 600(powerd) TimedOut InternalPreventSleep "com.apple.powermanagement.darkwakelinger" 00:00:00  id:0x0xd00009262 [System: PrevIdle DeclUser SRPrevSleep kCPU kDisp]
    2026-10-19 10:32:34 +0800 DarkWake             \tDarkWake from Deep Idle [CDNP] : due to smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty/ Using AC (Charge:100%) 10 secs
    2026-10-19 10:33:11 +0800 DarkWake             \tDarkWake from Deep Idle [CDNP] : due to smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty/ Using AC (Charge:100%) 10 secs
    2026-10-19 10:33:48 +0800 DarkWake             \tDarkWake from Deep Idle [CDNP] : due to smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty/ Using AC (Charge:100%) 10 secs
    2026-10-19 10:34:00 +0800 DarkWake             \tDarkWake from Deep Idle [CDNP] : due to smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty/HID Activity Using AC (Charge:100%) 0 secs
    2026-10-19 10:34:00 +0800 Wake                 \tDarkWake to FullWake from Deep Idle [CDNVA] : due to HID Activity Using AC (Charge:100%)

    """

private func at(_ h: Int, _ m: Int, _ s: Int) -> Int { h * 3_600 + m * 60 + s }

@Suite struct WakeKindTests {
    /// The morning's actual wake: a DarkWake that HID activity promoted to a
    /// FullWake. The last line is the FullWake, so this is a wake with a person.
    @Test func theRTCWakeThatPromotedToAFullWakeIsAFullWake() {
        #expect(newestWake(realWakeLog, now: at(10, 34, 1)) == .full)
    }

    /// One of the maintenance wakes: screen off, nothing to hear. Only the
    /// lines powerd had written by 10:33:48, which is what the machine would
    /// have been able to read at that moment.
    @Test func aMaintenanceWakeIsADarkWake() {
        let asKnownAt3348 = realWakeLog
            .split(separator: "\n")
            .filter { !$0.contains("10:34:00") }
            .joined(separator: "\n")
        #expect(newestWake(asKnownAt3348, now: at(10, 33, 48)) == .dark)
    }

    /// The race the README documents: powerd has not written our wake yet, so
    /// the newest entry is one from before it. That must not be read as ours,
    /// or a real wake goes silent because of a stale DarkWake.
    @Test func aStaleEntryIsNotThisWake() {
        #expect(newestWake(realWakeLog, now: at(14, 0, 0)) == .unknown)
    }

    @Test func anEntryJustOutsideTheWindowIsNotOurs() {
        #expect(newestWake(realWakeLog, now: at(10, 34, 1) + wakeEvidenceWindowSeconds + 1) == .unknown)
    }

    @Test func noLogMeansNoClaimEitherWay() {
        #expect(newestWake("", now: at(10, 34, 1)) == .unknown)
        #expect(newestWake("2026-10-19 10:34:00 +0800 Sleep  Entering Sleep state", now: at(10, 34, 1)) == .unknown)
    }

    /// Only the wake lines are evidence. An Assertions or Sleep line in the
    /// same log must not be mistaken for one.
    @Test func otherEventsAreNotWakes() {
        #expect(latestWakeEvent(realWakeLog)?.kind == .full)
        #expect(latestWakeEvent("2026-10-19 10:34:00 +0800 Sleep  x") == nil)
    }
}
