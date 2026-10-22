import Foundation
import Testing
@testable import ShowupCore

/// The contract between the two sides of the install, as a file format: what
/// one run of the CLI decides is what the renewal reads back, byte for byte
/// of meaning. A contract that says nothing wrong parses; one that says
/// something wrong names its field, because a guessed schedule is a Mac
/// waking for reasons nobody wrote.
@Suite struct ScheduleContractTests {
    @Test func theRoundTripHoldsEveryField() throws {
        let contract = ScheduleContract(
            app: "Finder",
            times: [TimeOfDay(hour: 4, minute: 0), TimeOfDay(hour: 8, minute: 0)],
            ring: true
        )
        let text = contract.render()
        #expect(text == "app Finder\ntimes 04:00,08:00\nring yes\n")
        #expect(try ScheduleContract.read(text) == contract)
    }

    @Test func anAppNameWithSpacesSurvivesAsOneValue() throws {
        let contract = ScheduleContract(
            app: "Adobe Photoshop 2024",
            times: [TimeOfDay(hour: 9, minute: 0)],
            ring: false
        )
        let text = contract.render()
        #expect(text == "app Adobe Photoshop 2024\ntimes 09:00\nring no\n")
        #expect(try ScheduleContract.read(text) == contract)
    }

    @Test func theTimesComeBackNormalisedTheWayEveryScheduleDoes() throws {
        let contract = try ScheduleContract.read(
            "app Mail\ntimes 20:00,08:00,08:00\nring yes"
        )
        #expect(contract.times == [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 20, minute: 0)])
    }

    @Test func aMissingFieldNamesItself() {
        #expect(throws: ScheduleContract.ReaderError.missingField(name: "times")) {
            try ScheduleContract.read("app Finder\nring yes")
        }
    }

    @Test func aLineThatOwnsNoFieldIsRefusedByName() {
        #expect(throws: ScheduleContract.ReaderError.unnamed(line: "wrench 3")) {
            try ScheduleContract.read("app Finder\ntimes 04:00\nring yes\nwrench 3")
        }
    }

    @Test func aFieldSaidTwiceIsRefusedByName() {
        #expect(throws: ScheduleContract.ReaderError.repeatedField(name: "app")) {
            try ScheduleContract.read("app Finder\napp Mail\ntimes 04:00\nring yes")
        }
    }

    @Test func aTimeTheContractCannotHonorNamesItsField() {
        #expect(throws: ScheduleContract.ReaderError.badValue(field: "times", value: "25:00")) {
            try ScheduleContract.read("app Finder\ntimes 25:00\nring yes")
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
