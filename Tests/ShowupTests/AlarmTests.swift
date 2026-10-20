import Testing
@testable import ShowupCore

@Suite struct AlarmTests {
    /// Nothing but a key press stops the alarm, so every test scripts the
    /// keyboard readings that stop it.
    let options = AlarmOptions(between: 10, playFailures: 3)

    @Test func aKeyPressAfterTheFirstRingStopsIt() {
        // readings[0] is the baseline, taken before the first ring.
        let alarm = FakeAlarm(readings: [900, 900, 0])
        #expect(alarmRing(options, alarm) == .rung(rings: 2))
        #expect(alarm.plays == 2)
    }

    /// A key press in the window before the first ring stops the alarm before it
    /// rings again at all.
    @Test func aKeyPressBeforeTheFirstCheckStopsIt() {
        let alarm = FakeAlarm(readings: [900, 0])
        #expect(alarmRing(options, alarm) == .rung(rings: 1))
        #expect(alarm.plays == 1)
    }

    /// The baseline is read before the first ring, so a sudo password typed a
    /// moment ago cannot be mistaken for the answer.
    @Test func aCounterBelowTheBaselineCountsAsAKeyPress() {
        let alarm = FakeAlarm(readings: [900, 900, 400])
        #expect(alarmRing(options, alarm) == .rung(rings: 2))
    }

    /// A tap leaves the counter back at zero and climbing again, so by the time
    /// it is sampled it is a small number rather than a fall below the original
    /// baseline. Measured against the reading before, a tap is always visible.
    /// Against the original baseline this case rang past the user: 4 is above 2.
    @Test func aTapIsStillSeenWhenTheUserWasJustAtTheKeyboard() {
        // readings[0] is the baseline: the user touched the keyboard just before
        // the alarm started. Then 5, then 4 - the counter fell, which only a key
        // press does.
        let alarm = FakeAlarm(readings: [2, 5, 4])

        #expect(alarmRing(AlarmOptions(between: 10, playFailures: 3, budget: 30), alarm) == .rung(rings: 2))
    }

    /// A zero baseline happens whenever the user touched the keyboard just
    /// before the alarm started, which is common on a wake. The counter can
    /// only still be zero after a real wait if a key arrived during it.
    @Test func aZeroBaselineStillStopsForAZeroReading() {
        let alarm = FakeAlarm(readings: [0, 5, 0])
        #expect(alarmRing(options, alarm) == .rung(rings: 2))
    }

    /// A counter that cannot be read at all is not evidence that anybody is
    /// awake. Stopping here is the failure the bias is designed to avoid.
    @Test func anUnreadableCounterKeepsRinging() {
        let alarm = FakeAlarm(readings: [nil, nil, nil, 0])
        #expect(alarmRing(options, alarm) == .rung(rings: 3))
    }

    @Test func reportsASoundItCouldNotPlay() {
        let alarm = FakeAlarm(readings: [600], playResult: .failure(.unavailable(what: "sound", reason: "no such file")))
        #expect(alarmRing(options, alarm) == .silent(reason: "could not read sound: no such file"))
        #expect(alarm.plays == 3)
    }

    /// An audio device that is still coming up after a wake fails the first few
    /// plays, so a handful of failures is not yet a reason to stop.
    @Test func waitsOutAnAudioDeviceStillComingUp() {
        let busy = Result<Void, ShowError>.failure(.unavailable(what: "sound", reason: "busy"))
        let alarm = FakeAlarm(readings: [600, 600, 600, 0], playResults: [busy, busy, .success(())])

        #expect(alarmRing(AlarmOptions(between: 10, playFailures: 4), alarm) == .rung(rings: 1))
        #expect(alarm.plays == 3)  // two failures, then a ring
    }

    /// The audio device is still coming up, but the user is already at the
    /// keyboard. Ignoring them until the sound works is the bug this covers.
    @Test func aKeyPressDuringPlayFailuresStopsTheAlarm() {
        let busy = Result<Void, ShowError>.failure(.unavailable(what: "sound", reason: "busy"))
        // baseline (readings[0]) is high; after the first failed play, the counter drops to 0.
        let alarm = FakeAlarm(readings: [900, 0], playResults: [busy])

        #expect(alarmRing(AlarmOptions(between: 10, playFailures: 40), alarm) == .rung(rings: 0))
        #expect(alarm.plays == 1)
    }

    /// Nobody came back, so the Mac went back to sleep on its own idle timer.
    /// `Thread.sleep` counts uptime and stalls while suspended, so the wait
    /// comes back much later than it was asked for. The alarm stops there, and
    /// the loop goes back to arming the next wake rather than resuming this ring.
    @Test func theMacGoingBackToSleepStopsTheAlarm() {
        let alarm = FakeAlarm(readings: [900, 900, 900])
        alarm.sleepAdvancesClock = { _ in 600 }   // ten minutes of sleep

        #expect(alarmRing(options, alarm) == .failed(rings: 1))
        #expect(alarm.plays == 1)
    }

    /// A wake is worth what its window is worth. Once the machine is due to
    /// sleep again with nobody there, the run has failed and there is nothing
    /// left to ring for.
    @Test func ringingPastTheIdleWindowConcludesTheWakeHasFailed() {
        let alarm = FakeAlarm(readings: [900])   // nobody ever touches the keyboard
        let budget = AlarmOptions(between: 10, playFailures: 3, budget: 100)

        #expect(alarmRing(budget, alarm) == .failed(rings: 10))
        #expect(alarm.sleeps == 10)
    }

    /// No budget means no deadline, not a shorter one.
    @Test func withoutABudgetOnlyAKeyStopsIt() {
        let alarm = FakeAlarm(readings: [900, 900, 0])
        #expect(alarmRing(options, alarm) == .rung(rings: 2))
    }

    /// The tolerance that decides "the Mac slept" has to allow for the ring
    /// itself taking longer than the wait between rings.
    @Test func aSlowRingIsNotMistakenForTheMacSleeping() {
        let alarm = FakeAlarm(readings: [900, 900, 0])
        alarm.sleepAdvancesClock = { _ in awakeToleranceSeconds - 1 }

        #expect(alarmRing(options, alarm) == .rung(rings: 2))
    }

    @Test func theDefaultsAreTheOnesTheREADMEDescribes() {
        #expect(AlarmOptions().between == 5)
        #expect(AlarmOptions().budget == nil)
        #expect(defaultPlayFailures == 40)
        #expect(ringbackTone.hasSuffix("multiway_invitation.caf"))
    }
}
