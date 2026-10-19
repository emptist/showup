import Testing
@testable import ShowupCore

@Suite struct SleepDetectionTests {
    /// The measurement from the README, verbatim. The counter advanced 2.34s
    /// across a 353s wait, so the Mac was asleep for essentially all of it.
    @Test func aFrozenCounterMeansTheMachineSlept() {
        #expect(sleepEvidence(idleBefore: 5, idleAfter: 8, elapsed: 353) == .slept)
    }

    /// The same 353 seconds on a Mac that never went down would have carried
    /// the counter to 358.
    @Test func aCounterThatKeepsUpWithTheWallClockMeansTheMacStayedUp() {
        #expect(sleepEvidence(idleBefore: 5, idleAfter: 358, elapsed: 353) == .awake)
    }

    /// The counter only ever moves backwards when input arrives, which means
    /// somebody was at the machine and there is nothing to wake.
    @Test func aCounterThatWentBackwardsMeansSomebodyWasThere() {
        #expect(sleepEvidence(idleBefore: 900, idleAfter: 0, elapsed: 3_600) == .inputArrived)
    }

    @Test func anUnreadableCounterCountsAsAsleep() {
        // Unknown is not the cautious reading here. Raising a window at a
        // machine nobody is looking at achieves nothing, so the loud reading
        // wins: one extra ring costs a few seconds of noise.
        #expect(sleepEvidence(idleBefore: nil, idleAfter: 30, elapsed: 300).wokeTheUser)
        #expect(sleepEvidence(idleBefore: 30, idleAfter: nil, elapsed: 300).wokeTheUser)
        #expect(sleepEvidence(idleBefore: nil, idleAfter: nil, elapsed: 300) == .unreadable)
    }

    /// Four hours of continuous typing leaves the counter barely moved, which is
    /// indistinguishable from a freeze. It costs one ring, which stops on the
    /// next reading, and that is the right trade against a silent wake.
    @Test func aBusyMachineLooksLikeASleepAndIsTreatedAsOne() {
        #expect(sleepEvidence(idleBefore: 400, idleAfter: 410, elapsed: 14_400) == .slept)
    }

    @Test func onlySleepAndUnknownWakeTheUser() {
        #expect(SleepEvidence.awake.wokeTheUser == false)
        #expect(SleepEvidence.inputArrived.wokeTheUser == false)
        #expect(SleepEvidence.slept.wokeTheUser)
        #expect(SleepEvidence.unreadable.wokeTheUser)
    }

    /// A wait shorter than the tolerance cannot be told apart from a sleep, and
    /// the tolerance is what stops a two second wait from ringing.
    @Test func aShortWaitWithNoCounterMovementIsNotASleep() {
        #expect(sleepEvidence(idleBefore: 100, idleAfter: 101, elapsed: 3) == .awake)
    }
}