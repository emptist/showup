import Foundation
import Testing
@testable import ShowupMac
@testable import ShowupCore

/// showup used to shell out to `scutil` and `ioreg` and parse their output, and
/// the parsers had fixtures taken verbatim from this machine - one of them
/// exists because `parseUID` once searched for the substring `UID : `, which also
/// matches the tail of `CGSSessionUniqueSessionUUID : ...`, so it failed on
/// every real input while every test passed.
///
/// Those parsers are gone. `SCDynamicStoreCopyConsoleUser`,
/// `CGEventSource.secondsSinceLastEventType` and CoreAudio answer the questions
/// directly, so there is no text left to disagree with reality - which is the
/// better outcome, and the one worth recording here.
///
/// What remains below is the command runner, which still shells out for the
/// things with no public API: the configured idle timers, and surfacing an app
/// into another user's session.
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
