import Foundation
import Testing
@testable import ShowupCore

/// The contract between the two sides of the install, as a file format: what
/// one run of the CLI decides is what the renewal reads back, byte for byte
/// of meaning. A contract that says nothing wrong parses; one that says
/// something wrong names its field, because a guessed schedule is a Mac
/// waking for reasons nobody wrote.
///
/// One line is history rather than error: `ring yes|no`, which older
/// contracts wrote for an option the program no longer has. It is read and
/// dropped, because the wake either rings the person back or there is no
/// fetch at all, and the next write of the contract leaves the line out.
@Suite struct ScheduleContractTests {
    @Test func theRoundTripHoldsEveryField() throws {
        let contract = ScheduleContract(
            app: "Finder",
            times: [TimeOfDay(hour: 4, minute: 0), TimeOfDay(hour: 8, minute: 0)]
        )
        let text = contract.render()
        #expect(text == "app Finder\ntimes 04:00,08:00\n")
        #expect(try ScheduleContract.read(text) == contract)
    }

    @Test func anAppNameWithSpacesSurvivesAsOneValue() throws {
        let contract = ScheduleContract(
            app: "Adobe Photoshop 2024",
            times: [TimeOfDay(hour: 9, minute: 0)]
        )
        let text = contract.render()
        #expect(text == "app Adobe Photoshop 2024\ntimes 09:00\n")
        #expect(try ScheduleContract.read(text) == contract)
    }

    /// A contract written by an installed copy that still knew the old
    /// option: its `ring yes` line is history, accepted and dropped, and the
    /// schedule it carries as a whole still parses.
    @Test func aLegacyRingLineIsReadAndDropped() throws {
        let contract = try ScheduleContract.read(
            "app Mail\ntimes 20:00,08:00,08:00\nring yes"
        )
        #expect(contract.times == [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 20, minute: 0)])
        // And the next write of the contract leaves the line out.
        #expect(!contract.render().contains("ring"))
    }

    @Test func aMissingFieldNamesItself() {
        #expect(throws: ScheduleContract.ReaderError.missingField(name: "times")) {
            try ScheduleContract.read("app Finder")
        }
    }

    @Test func aLineThatOwnsNoFieldIsRefusedByName() {
        #expect(throws: ScheduleContract.ReaderError.unnamed(line: "wrench 3")) {
            try ScheduleContract.read("app Finder\ntimes 04:00\nwrench 3")
        }
    }

    @Test func aFieldSaidTwiceIsRefusedByName() {
        #expect(throws: ScheduleContract.ReaderError.repeatedField(name: "app")) {
            try ScheduleContract.read("app Finder\napp Mail\ntimes 04:00")
        }
    }

    @Test func aTimeTheContractCannotHonorNamesItsField() {
        #expect(throws: ScheduleContract.ReaderError.badValue(field: "times", value: "25:00")) {
            try ScheduleContract.read("app Finder\ntimes 25:00")
        }
    }

    @Test func anUnreadableRingAnswerNamesItsField() {
        #expect(throws: ScheduleContract.ReaderError.badValue(field: "ring", value: "maybe")) {
            try ScheduleContract.read("app Finder\ntimes 04:00\nring maybe")
        }
    }

    @Test func anEmptyTimesFieldNamesItsField() {
        #expect(throws: ScheduleContract.ReaderError.badValue(field: "times", value: "")) {
            try ScheduleContract.read("app Finder\ntimes \nring yes")
        }
    }

    @Test func anEmptyContractHasNothingItCanName() {
        #expect(throws: ScheduleContract.ReaderError.missingField(name: "app")) {
            try ScheduleContract.read("")
        }
    }
}
