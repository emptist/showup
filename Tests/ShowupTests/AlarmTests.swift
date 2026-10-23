import Testing
@testable import ShowupCore

@Suite struct AlarmTests {
    /// Nothing but a key press stops the alarm, so every test scripts the
    /// keyboard readings that stop it. The first slot in a script is not read -
    /// nothing is read before the first ring - and each check takes the slot
    /// after its ring.
    let options = AlarmOptions(between: 10, playFailures: 3)

    @Test func aKeyPressAfterTheFirstRingStopsIt() {
        let alarm = FakeAlarm(readings: [900, 900, 0])
        #expect(alarmRing(options, alarm) == .rung(rings: 2))
        #expect(alarm.plays == 2)
    }

    /// A key press in front of the first check stops the alarm before it
    /// rings again at all.
    @Test func aKeyPressBeforeTheFirstCheckStopsIt() {
        let alarm = FakeAlarm(readings: [900, 0])
        #expect(alarmRing(options, alarm) == .rung(rings: 1))
        #expect(alarm.plays == 1)
    }

    /// Measured on a real afternoon: four rings went out at somebody who
    /// was continuously typing their password at the login window. Their
    /// readings against the reading before them climbed as often as they
    /// fell, so a fall test did not see a hand at all. Against the wall
    /// clock since the alarm started, the same readings sit permanently
    /// short of it, and the very first check answers.
    @Test func typingStopsTheRingEvenWhenNoReadingFalls() {
        // 2, 3: no fall in either comparison, and a key pressed within
        // ten seconds of the alarm's start all the same.
        let alarm = FakeAlarm(readings: [0, 2, 3])

        #expect(alarmRing(options, alarm) == .rung(rings: 1))
        #expect(alarm.plays == 1)
    }

    /// A tap leaves the counter back at a small number, so a reading taken a
    /// moment after it answers the alarm even though the previous sample of
    /// the same hand read higher.
    @Test func aTapIsStillSeenWhenTheUserWasJustAtTheKeyboard() {
        let alarm = FakeAlarm(readings: [2, 5, 4])

        #expect(alarmRing(AlarmOptions(between: 10, playFailures: 3, budget: 30), alarm) == .rung(rings: 2))
    }

    /// A zero reading answers on its own: after a real gap the counter cannot
    /// still be zero unless a key put it there.
    @Test func aZeroReadingStopsTheRing() {
        let alarm = FakeAlarm(readings: [0, 5, 0])
        #expect(alarmRing(options, alarm) == .rung(rings: 2))
    }

    /// A key that landed minutes ago is not somebody being back. The counter
    /// reads long again as soon as it catches up with the clock, and the fall
    /// test used to stop for it; against the clock it reads past both, as a
    /// key that old should.
    @Test func aKeyMinutesOldDoesNotStopTheRing() {
        let alarm = FakeAlarm(readings: [900, 900, 400])
        let budget = AlarmOptions(between: 10, playFailures: 3, budget: 30)

        #expect(alarmRing(budget, alarm) == .failed(rings: 3))
    }

    /// The counter sitting level with the clock is a machine nobody is at,
    /// even when the numbers themselves are small ones - the ring keeps going
    /// and the budget concludes the wake has failed.
    @Test func theCounterKeepingUpWithTheClockMeansNobodyIsThere() {
        let alarm = FakeAlarm(readings: [2, 12, 22, 32, 42])
        let budget = AlarmOptions(between: 10, playFailures: 3, budget: 40)

        #expect(alarmRing(budget, alarm) == .failed(rings: 4))
        #expect(alarm.sleeps == 4)
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
        #expect(keyAnswerToleranceSeconds == 5)
    }
}
