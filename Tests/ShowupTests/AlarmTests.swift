import Testing
@testable import ShowupCore

@Suite struct AlarmTests {
    /// The alarm does not give up on its own by default, so these run against an
    /// explicit cap.
    let options = AlarmOptions(between: 10, giveUpAfter: 6, playFailures: 3)

    @Test func stopsAtTheCapWhenNothingElseHappens() {
        let alarm = FakeAlarm(readings: [600])
        #expect(alarmRing(options, alarm) == .rung(rings: 6))
        #expect(alarm.plays == 6)
        #expect(alarm.sleeps == 6)
    }

    @Test func ringsOnceWhenAskedTo() {
        let alarm = FakeAlarm(readings: [600])
        #expect(alarmRing(AlarmOptions(between: 10, giveUpAfter: 1, playFailures: 3), alarm) == .rung(rings: 1))
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
        let alarm = FakeAlarm(readings: [600], playResults: [busy, busy, .success(())])

        #expect(alarmRing(AlarmOptions(between: 10, giveUpAfter: 3, playFailures: 4), alarm) == .rung(rings: 3))
        #expect(alarm.plays == 5)  // two failures, then three rings
    }

    /// Input during the ring resets the counter, which is how somebody answers.
    @Test func inputDuringRingingStopsIt() {
        // readings[0] is the baseline, taken before the first ring.
        let alarm = FakeAlarm(readings: [900, 900, 0])
        #expect(alarmRing(AlarmOptions(between: 10, giveUpAfter: 99, playFailures: 3), alarm) == .rung(rings: 2))
    }

    /// The baseline is read before the first ring, so a sudo password typed a
    /// moment ago cannot be mistaken for the answer.
    @Test func aCounterBelowTheBaselineCountsAsInput() {
        let alarm = FakeAlarm(readings: [900, 900, 400])
        #expect(alarmRing(AlarmOptions(between: 10, giveUpAfter: 99, playFailures: 3), alarm) == .rung(rings: 2))
    }

    /// A zero baseline happens whenever the user touched the keyboard just
    /// before the alarm started, which is common on a wake. The counter can
    /// only still be zero after a real wait if input arrived during it.
    @Test func aZeroBaselineStillStopsForAZeroReading() {
        let alarm = FakeAlarm(readings: [0, 5, 0])
        #expect(alarmRing(AlarmOptions(between: 10, giveUpAfter: 99, playFailures: 3), alarm) == .rung(rings: 2))
    }

    /// A counter that cannot be read at all is not evidence that anybody is
    /// awake. Stopping here is the failure the bias is designed to avoid.
    @Test func anUnreadableCounterKeepsRinging() {
        let alarm = FakeAlarm(readings: [nil])
        #expect(alarmRing(AlarmOptions(between: 10, giveUpAfter: 3, playFailures: 3), alarm) == .rung(rings: 3))
    }

    @Test func theDefaultsAreTheOnesTheREADMEDescribes() {
        #expect(AlarmOptions().between == 5)
        #expect(AlarmOptions().giveUpAfter == nil)
        #expect(defaultPlayFailures == 40)
        #expect(ringbackTone.hasSuffix("multiway_invitation.caf"))
    }
}
