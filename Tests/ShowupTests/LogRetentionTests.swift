import Foundation
import Testing
@testable import ShowupMac

/// The retention rule is pure, so its verdicts are pinned here rather than
/// trusted: a mistaken rule either deleted a log somebody still needed or kept
/// a directory growing without bound.
@Suite struct LogRetentionTests {
    private var now: Date { Date(timeIntervalSince1970: 1_000_000_000) }

    private func prunes(
        _ name: String, modified isOld: Int = 8 * 24 * 60 * 60, regular: Bool = true
    ) -> Bool {
        prunableLog(
            name,
            isRegularFile: regular,
            modified: now.addingTimeInterval(TimeInterval(-isOld)),
            now: now
        )
    }

    /// The name the program actually writes, older than a week.
    @Test func anOldLogOfThisShapeIsPruned() {
        #expect(prunes("showup1792377113.log"))
    }

    /// Recent enough to keep: the run that produced it is not a week dead.
    @Test func aWeekYoungLogIsKept() {
        #expect(!prunes("showup1792377113.log", modified: 24 * 60 * 60))
    }

    /// The threshold is exclusive on the keep side: a minute short of the week
    /// survives, a minute past it does not.
    @Test func theBoundaryIsTheWeek() {
        #expect(!prunes("showup1792377113.log", modified: 7 * 24 * 60 * 60 - 60))
        #expect(prunes("showup1792377113.log", modified: 7 * 24 * 60 * 60 + 60))
    }

    /// Names the program never produced are left alone, whatever their age.
    @Test func namesTheProgramDoesNotWriteAreLeftAlone() {
        #expect(!prunes("showup.log"))            // no number between the halves
        #expect(!prunes("showupper10.log"))       // not a number between the halves
        #expect(!prunes("showup1792377113"))      // no .log suffix
        #expect(!prunes("systemlog.log"))
    }

    /// The type check runs before the name check: a symlink to anywhere that
    /// happens to be named like a log is never deleted, because deletion is
    /// by name upstream and by lstat here.
    @Test func anythingButARegularFileIsNotDeleted() {
        #expect(!prunes("showup1792377113.log", regular: false))
    }
}

/// The stamp is what a post-mortem starts with, so a run that found a stamp
/// prints it and a run without one says so, and neither invents.
@Suite struct BuildStampTests {
    private func withDirectory(_ body: (String) -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("showup-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        body(directory.path)
    }

    /// A stamp file next to the binary is read and reported in full.
    @Test func theStampNextToTheBinaryIsWhatTheRunReports() {
        withDirectory { directory in
            precondition(FileManager.default.createFile(
                atPath: directory + "/showup", contents: Data("x".utf8)
            ))
            precondition(FileManager.default.createFile(
                atPath: directory + "/showup.stamp",
                contents: Data("build 0404c92 2026-10-22 13:53 +0800\n".utf8)
            ))
            #expect(
                readBuildStamp(
                    argument: directory + "/showup", path: nil, workingDirectory: directory
                ) == "build 0404c92 2026-10-22 13:53 +0800"
            )
        }
    }

    /// A binary reached through `PATH` is found through `PATH`, which is what
    /// `showup -a ...` is after the shell resolves it.
    @Test func aPlainNameIsResolvedThroughThePath() {
        withDirectory { directory in
            precondition(FileManager.default.createFile(
                atPath: directory + "/showup", contents: Data("x".utf8)
            ))
            precondition(FileManager.default.createFile(
                atPath: directory + "/showup.stamp",
                contents: Data("build 0404c92 2026-10-22 13:53 +0800\n".utf8)
            ))
            #expect(
                readBuildStamp(
                    argument: "showup", path: directory + "/nope:" + directory,
                    workingDirectory: directory
                ) == "build 0404c92 2026-10-22 13:53 +0800"
            )
        }
    }

    /// No stamp file means no stamp; an empty one is no stamp either. Nothing
    /// is invented, because a made-up identity is worse than a missing one.
    @Test func aMissingOrEmptyStampIsNoStamp() {
        withDirectory { directory in
            precondition(FileManager.default.createFile(
                atPath: directory + "/showup", contents: Data("x".utf8)
            ))
            #expect(readBuildStamp(
                argument: directory + "/showup", path: nil, workingDirectory: directory
            ) == nil)
            precondition(FileManager.default.createFile(
                atPath: directory + "/showup.stamp",
                contents: Data("\n \n".utf8)
            ))
            #expect(readBuildStamp(
                argument: directory + "/showup", path: nil, workingDirectory: directory
            ) == nil)
        }
    }
}
