import Testing
@testable import ShowupCore

@Suite struct CLITests {
    func show(_ app: String, _ times: [TimeOfDay]) -> Command {
        .show(Config(app: app, times: times, dryRun: false))
    }

    @Test func parsesTheDocumentedExample() throws {
        let command = try parseCLI(["-a", "Safari", "-t", "8:00,12:00,16:00,20:00"])
        #expect(
            command == show("Safari", [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 12, minute: 0),
                                       TimeOfDay(hour: 16, minute: 0), TimeOfDay(hour: 20, minute: 0)])
        )
    }

    @Test func parsesLongFlags() throws {
        #expect(
            try parseCLI(["--app", "Mail", "--times", "9:00"]) == show("Mail", [TimeOfDay(hour: 9, minute: 0)])
        )
    }

    @Test func parsesFlagsWithEquals() throws {
        let nineAndFive = [TimeOfDay(hour: 9, minute: 0), TimeOfDay(hour: 17, minute: 0)]
        #expect(
            try parseCLI(["--app=Slack", "--times=9,17"]) == show("Slack", nineAndFive)
        )
    }

    @Test func parsesTheDryRunFlag() throws {
        let nine = TimeOfDay(hour: 9, minute: 0)
        let command = try parseCLI(["-a", "Mail", "-t", "9", "-n"])
        #expect(command == .showSchedule(Config(app: "Mail", times: [nine], dryRun: true)))
    }

    /// The ring has no switch: a wake exists because the person is absent,
    /// and the ring is the only voice the program has. Asking for silence
    /// with a flag is an unknown argument, like any other word the tool does
    /// not own.
    @Test func asksForSilenceAndIsRefusedInWords() {
        #expect(throws: ShowError.unknownArgument("--no-ring")) {
            try parseCLI(["-a", "Mail", "-t", "9", "--no-ring"])
        }
    }

    @Test func collectsRepeatedTimeFlags() throws {
        let nine = TimeOfDay(hour: 9, minute: 0)
        let five = TimeOfDay(hour: 17, minute: 0)
        #expect(
            try parseCLI(["-a", "Mail", "-t", "9", "--times", "17"]) == show("Mail", [nine, five])
        )
    }

    @Test func acceptsAnAppNameWithSpaces() throws {
        let nine = TimeOfDay(hour: 9, minute: 0)
        #expect(try parseCLI(["-a", "  System Settings  ", "-t", "9"]) == show("System Settings", [nine]))
    }

    @Test func acceptsAQuotedListWithSpacesAfterCommas() throws {
        #expect(
            try parseCLI(["-a", "Safari", "-t", "8:00, 12:00, 16:00"])
                == show("Safari", [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 12, minute: 0),
                                    TimeOfDay(hour: 16, minute: 0)])
        )
    }

    @Test func sortsAndDeduplicatesWhateverOrderTheyArriveIn() throws {
        #expect(
            try parseCLI(["-a", "Mail", "-t", "12:00,8:00", "-t", "8:00"])
                == show("Mail", [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 12, minute: 0)])
        )
    }

    @Test func parsesHelp() throws {
        #expect(try parseCLI(["--help"]) == .help)
        #expect(try parseCLI(["-h"]) == .help)
    }

    /// Nothing said at all is the installed night run: no schedule is said
    /// out loud, because the schedule lives in the contract. Every other
    /// shape still has to say its app.
    @Test func nothingSaidIsTheRunFromTheContract() throws {
        #expect(try parseCLI([]) == .runFromContract)
    }

    // MARK: Everything it can get wrong

    @Test(arguments: [
        (["-t", "9:00"], ShowError.missingApp),
        (["-a", "Mail"], ShowError.noTimesGiven),
        (["-a", "   ", "-t", "9:00"], ShowError.emptyApp),
        (["-a", "Mail", "-t", "half past nine"], ShowError.invalidTime("half past nine")),
        (["-a", "Mail", "-t", "8:00,"], ShowError.timesSplitBySpaces("8:00,")),
        (["-a", "Mail", "-t"], ShowError.missingValue("-t")),
        (["-a"], ShowError.missingValue("-a")),
        (["--lunch", "12:00"], ShowError.unknownArgument("--lunch")),
        (["Safari"], ShowError.unknownArgument("Safari")),
        (["--lunch=12:00"], ShowError.unknownArgument("--lunch=12:00")),
    ])
    func reportsBadArgumentsInWords(arguments: [String], expected: ShowError) {
        #expect(throws: expected) { try parseCLI(arguments) }
    }

    @Test func everyErrorHasSomethingToRead() {
        let errors: [ShowError] = [
            .missingApp, .emptyApp, .noTimesGiven, .invalidTime("x"),
            .timesSplitBySpaces("x,"), .missingValue("-t"), .unknownArgument("--x"),
            .unavailable(what: "volume", reason: "no"),
            .failed(command: "pmset", status: 1, detail: "denied"),
            .failed(command: "pmset", status: 1, detail: ""),
            .unexpectedOutput(what: "volume", sample: "loud"),
        ]
        #expect(errors.allSatisfy { !$0.description.isEmpty })
    }
}