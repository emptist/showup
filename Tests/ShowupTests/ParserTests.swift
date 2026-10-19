import Foundation
import Testing
@testable import ShowupCore
@testable import ShowupMac

/// Tests for the parsers, run against verbatim output captured from this Mac on
/// 2026-10-19 — padding, tabs, nesting and all.
///
/// These live in the test target rather than being exercised through `Effects`
/// because that is the only way to catch a parser that disagrees with reality.
/// `parseUID` once searched for the substring `UID : `, which also matches the
/// tail of `CGSSessionUniqueSessionUUID : ...`, so it failed on every real input
/// and the app was never surfaced at all — while every test passed, because
/// every test supplied a fake.

private let realScutil = """
    <dictionary> {
      GID : 20
      Name : jk
      SessionInfo : <array> {
        0 : <dictionary> {
          CGSSessionUniqueSessionUUID : 3CC66676-A9B2-4F50-B909-EA4F54CD9AE7
          kCGSSessionAuditIDKey : 100016
          kCGSSessionGroupIDKey : 20
          kCGSSessionIDKey : 257
          kCGSSessionLoginwindowSafeLogin : FALSE
          kCGSSessionOnConsoleKey : TRUE
          kCGSSessionSystemSafeBoot : FALSE
          kCGSSessionUserIDKey : 501
          kCGSSessionUserNameKey : jk
          kCGSessionLoginDoneKey : TRUE
          kCGSessionLongUserNameKey : jk
          kSCSecuritySessionID : 100016
        }
      }
      UID : 501
    }

    """

private let realIOHIDSystem = """
    +-o IOHIDSystem  <class IOHIDSystem, id 0x100000479, registered, matched, active, busy 0 (854 ms), retain 13>
        {
          "IOClass" = "IOHIDSystem"
          "HIDScrollCountMaxTimeDeltaBetween" = 600
          "IOPersonalityPublisher" = "com.apple.iokit.IOHIDFamily"
          "IOResourceMatch" = "IOBSD"
          "IOMatchedAtBoot" = Yes
          "HIDServiceGlobalModifiersUsage" = 1
          "IOProviderClass" = "IOResources"
          "IOReportLegendPublic" = Yes
          "IOProbeScore" = 0
          "HIDIdleTime" = 345692520750
          "HIDScrollCountIgnoreMomentumScrolls" = Yes
          "HIDScrollCountAccelerationFactor" = 163840
          "HIDServiceSupport" = Yes
          "HIDScrollCountMouseCanReset" = Yes
          "IOReportLegendPublic" = Yes
          "CursorState" = {}
          "HIDPowerOnDelayNS" = 500000000
          "PrimaryUsage" = 23
        }

    """

@Suite struct ScutilParserTests {
    /// The trap: `CGSSessionUniqueSessionUUID : ...` appears *before* the real
    /// `UID : ` line and contains the substring `UID : `. A parser that searches
    /// for the substring finds the UUID first and gives up.
    @Test func readsTheUIDFromRealScutilOutput() throws {
        #expect(try Mac.parseUID(realScutil) == 501)
    }

    @Test func refusesToMistakeTheSessionUUIDForTheUID() throws {
        // If this ever parses as 0 or throws, the parser is matching a substring.
        #expect(throws: (any Error).self) {
            try Mac.parseUID("  CGSSessionUniqueSessionUUID : 3CC66676-A9B2\n")
        }
    }

    @Test func treatsALoggedOutConsoleAsNobody() {
        let loggedOut = """
            <dictionary> {
              GID : 20
              Name : loginwindow
              SessionInfo : <array> {
                0 : <dictionary> {
                  kCGSSessionUserIDKey : 0
                  kCGSessionLoginDoneKey : FALSE
                }
              }
              UID : 0
            }

            """
        #expect(throws: (any Error).self) { try Mac.parseUID(loggedOut) }
    }

    @Test func toleratesSpacingAroundTheValue() throws {
        #expect(try Mac.parseUID("  UID :   501  \n") == 501)
        #expect(try Mac.parseUID("UID :501") == 501)
    }

    @Test func reportsOutputItCannotUnderstand() {
        #expect(throws: (any Error).self) { try Mac.parseUID("") }
        #expect(throws: (any Error).self) { try Mac.parseUID("  UID : nobody\n") }
    }
}

/// Reconstructed from the documented shape of `State:/Users/ConsoleUser` at the
/// login window. Unlike the two fixtures above this is NOT a verbatim capture:
/// getting to a real login window means logging out of the session. It needs
/// replacing with a real capture before anyone trusts it.
private let loginWindowScutil = """
    <dictionary> {
      GID : 20
      Name : loginwindow
      SessionInfo : <array> {
        0 : <dictionary> {
          kCGSSessionAuditIDKey : 4294967295
          kCGSSessionGroupIDKey : 20
          kCGSSessionIDKey : 4294967295
          kCGSSessionLoginwindowSafeLogin : FALSE
          kCGSSessionOnConsoleKey : TRUE
          kCGSSessionUserIDKey : 0
          kCGSSessionUserNameKey : loginwindow
          kCGSessionLoginDoneKey : FALSE
        }
      }
      UID : 0
    }

    """

@Suite struct LoginWindowTests {
    @Test func theLoginWindowHasNoConsoleUser() {
        // uid 0 is the login window, not a user.
        #expect(throws: (any Error).self) { try Mac.parseUID(loginWindowScutil) }
    }

    @Test func theLoginWindowIsNotTheDesktop() {
        #expect(loginWindowScutil.contains(Mac.loginDoneKey) == false)
    }

    @Test func theDesktopIsTheDesktop() {
        #expect(realScutil.contains(Mac.loginDoneKey))
    }
}

@Suite struct IdleCounterParserTests {
    @Test func readsTheCounterOutOfRealIOHIDOutput() throws {
        #expect(try Mac.parseIdleSeconds(realIOHIDSystem) == 345)
    }

    /// The regression: the path with no trailing newline returned the raw
    /// nanosecond figure as seconds, which is a number about ten billion times
    /// too large. `ioreg` does not promise a final newline, so this path runs.
    @Test func readsTheCounterWhenItIsTheLastLineWithNoNewline() throws {
        let noNewline = "      \"HIDIdleTime\" = 345692520750"
        #expect(try Mac.parseIdleSeconds(noNewline) == 345)
    }

    @Test func readsASmallCounter() throws {
        #expect(try Mac.parseIdleSeconds("\"HIDIdleTime\" = 0\n") == 0)
        #expect(try Mac.parseIdleSeconds("\"HIDIdleTime\" = 999999999\n") == 0)
        #expect(try Mac.parseIdleSeconds("\"HIDIdleTime\" = 1000000000\n") == 1)
    }

    @Test func reportsACounterItCannotFind() {
        #expect(throws: (any Error).self) { try Mac.parseIdleSeconds("\"IOClass\" = \"IOHIDSystem\"\n") }
        #expect(throws: (any Error).self) { try Mac.parseIdleSeconds("\"HIDIdleTime\" = soon\n") }
    }
}

@Suite struct CommandRunnerTests {
    /// The regression: the runner waited for the child to exit *before* reading
    /// the pipe, so a command writing more than the pipe buffer deadlocked
    /// forever. 512KB is comfortably past that buffer and well past the 64KB
    /// one macOS uses.
    @Test func readsOutputLargerThanThePipeBuffer() {
        guard case .success(let output) = Mac.run("/bin/sh", ["-c", "yes abcdefghij | head -c 524288"]) else {
            Issue.record("a large output should still be read")
            return
        }
        #expect(output.count == 524_288)
    }

    @Test func reportsANonZeroExitWithItsOutput() {
        guard case .failure(let error) = Mac.run("/bin/sh", ["-c", "echo something went wrong >&2; exit 3"]) else {
            Issue.record("a failing command should fail")
            return
        }
        #expect(error.description.contains("3"))
        #expect(error.description.contains("something went wrong"))
    }

    @Test func reportsACommandThatIsNotThere() {
        guard case .failure = Mac.run("/usr/bin/definitely-not-a-command", []) else {
            Issue.record("a missing command should fail")
            return
        }
    }
}
@Suite struct LogPathTests {
    /// One file per run, named for when it started, so a single run can be read
    /// on its own and the directory sorts into the order things happened.
    @Test func theLogIsNamedForWhenTheRunStarted() {
        let started = Date(timeIntervalSince1970: 1_788_000_000)
        #expect(logPath(now: started) == "/var/log/showup1788000000.log")
    }

    /// `/var/log` and not `/tmp`: showup runs as root, and `/tmp` is world
    /// writable, so a file there is a way for a user to choose where a root
    /// process writes.
    @Test func theLogIsAlwaysInOnePlace() {
        let started = Date(timeIntervalSince1970: 1_788_000_000)
        #expect(logPath(now: started) == "/var/log/showup1788000000.log")
        #expect(logPath(now: started.addingTimeInterval(1)) == "/var/log/showup1788000001.log")
        #expect(logPath().hasPrefix("/var/log/showup"))
        #expect(logPath().hasSuffix(".log"))
        #expect(Log.path.hasPrefix("/var/log/showup"))
    }
}
