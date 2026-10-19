import Foundation
import Testing
@testable import ShowupCore

/// Verbatim from this Mac on 2026-10-19.
///
/// `pmset -g custom` prints one block per power source and the two halves
/// disagree: the same Mac sleeps the display after 20 minutes on AC and after
/// 10 on battery. Reading the wrong block is not a rounding error, it is the
/// difference between a wake that works and one that does not.
private let realPmsetCustom = """
    Battery Power:
     Sleep On Power Button 1
     lowpowermode         1
     standby              1
     ttyskeepawake        1
     hibernatemode        3
     powernap             1
     hibernatefile        /var/vm/sleepimage
     displaysleep         10
     womp                 0
     networkoversleep     0
     sleep                15
     lessbright           1
     tcpkeepalive         1
     disksleep            10
    AC Power:
     Sleep On Power Button 1
     lowpowermode         1
     standby              1
     ttyskeepawake        1
     hibernatemode        3
     powernap             1
     hibernatefile        /var/vm/sleepimage
     displaysleep         20
     womp                 1
     networkoversleep     0
     sleep                25
     tcpkeepalive         1
     disksleep            10

    """

private let realPmsetPS = """
    Now drawing from 'AC Power'
     -InternalBattery-0 (id=39321609)\t100%; finishing charge; 0:07 remaining present: true

    """

@Suite struct PowerSourceTests {
    @Test func readsWhichHalfApplies() {
        #expect(parsePowerSource(realPmsetPS) == .ac)
        #expect(parsePowerSource("Now drawing from 'Battery Power'") == .battery)
        #expect(parsePowerSource("") == nil)
        #expect(parsePowerSource("something else entirely") == nil)
    }
}

@Suite struct PowerSettingsTests {
    @Test func readsTheActiveSourceFromRealOutput() throws {
        let settings = try #require(readPowerSettings(ps: realPmsetPS, custom: realPmsetCustom))
        #expect(settings.source == .ac)
        #expect(settings.displaySleepMinutes == 20)
        #expect(settings.systemSleepMinutes == 25)
        #expect(settings.powerNap)
    }

    @Test func readsTheOtherSourceWhenItIsTheOneInUse() throws {
        let ps = "Now drawing from 'Battery Power'"
        let settings = try #require(readPowerSettings(ps: ps, custom: realPmsetCustom))
        #expect(settings.source == .battery)
        #expect(settings.displaySleepMinutes == 10)
        #expect(settings.systemSleepMinutes == 15)
    }

    /// The display goes first, so the smaller timer is the window in which
    /// anything showup does can be seen or heard.
    @Test func theIdleWindowIsTheShorterOfTheTwoTimers() {
        let settings = PowerSettings(source: .ac, displaySleepMinutes: 20, systemSleepMinutes: 25, powerNap: true)
        #expect(settings.idleWindowSeconds == 20 * 60)
    }

    @Test func aDisabledTimerMeansTheMachineNeverSleeps() {
        let neverDisplays = PowerSettings(source: .ac, displaySleepMinutes: 0, systemSleepMinutes: 25, powerNap: false)
        #expect(neverDisplays.idleWindowSeconds == 25 * 60)
        #expect(neverDisplays.neverSleeps == false)

        let neverSleeps = PowerSettings(source: .ac, displaySleepMinutes: 0, systemSleepMinutes: 0, powerNap: false)
        #expect(neverSleeps.idleWindowSeconds == nil)
        #expect(neverSleeps.neverSleeps)
    }

    /// `powernap` and `powernaptimer` share a prefix, and `sleep` and
    /// `standbydelayhigh` are neighbours in a block that is mostly other keys.
    @Test func keysAreMatchedWhole() {
        let output = """
            AC Power:
             powernaptimer        120
             standbydelayhigh     10800
             displaysleep         3
             sleep                4
             powernap             0
            """
        let settings = parsePowerSettings(output, source: .ac)
        #expect(settings?.powerNap == false)
        #expect(settings?.displaySleepMinutes == 3)
        #expect(settings?.systemSleepMinutes == 4)
    }

    @Test func reportsSettingsItCannotFind() {
        #expect(parsePowerSettings("", source: .ac) == nil)
        #expect(parsePowerSettings("AC Power:\n", source: .ac) == nil)
        #expect(readPowerSettings(ps: "", custom: realPmsetCustom) == nil)
    }
}

@Suite struct IdleWindowAuditTests {
    @Test func aNormalMachineIsDescribedAndNotWarnedAbout() {
        let settings = PowerSettings(source: .ac, displaySleepMinutes: 20, systemSleepMinutes: 25, powerNap: true)
        let report = auditIdleWindow(settings)
        #expect(report.warnings.isEmpty)
        #expect(report.summary.contains("20m"))
        #expect(report.summary.contains("AC power"))
    }

    @Test func aMachineThatNeverSleepsIsSaidToAndLeftAlone() {
        let settings = PowerSettings(source: .battery, displaySleepMinutes: 0, systemSleepMinutes: 0, powerNap: false)
        let report = auditIdleWindow(settings)
        #expect(report.warnings.isEmpty)
        #expect(report.summary.contains("never"))
        #expect(report.summary.contains("battery"))
    }

    @Test func settingsThatCannotBeReadAreSaidOutLoud() {
        let report = auditIdleWindow(nil)
        #expect(report.warnings.count == 1)
        #expect(report.summary.contains("could not read"))
    }
}