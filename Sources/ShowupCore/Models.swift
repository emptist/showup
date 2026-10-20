import Foundation

public let secondsPerDay = 86_400

// MARK: - Times of day

public struct TimeOfDay: Hashable, Comparable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public var secondsSinceMidnight: Int { hour * 3_600 + minute * 60 }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.secondsSinceMidnight < rhs.secondsSinceMidnight
    }

    /// `HH:MM`, as it is written in the command line and printed in the log.
    public var rendered: String {
        String(format: "%02d:%02d", hour, minute)
    }
}

/// One scheduled appearance of the app.
public struct Wake: Equatable {
    public var at: TimeOfDay
    public var delay: Int // seconds from now until `at`

    public init(at: TimeOfDay, delay: Int) {
        self.at = at
        self.delay = delay
    }
}

// MARK: - Commands

public enum Command: Equatable {
    case show(Config)
    case showSchedule(Config)
    case help
}

public struct Config: Equatable {
    public var app: String
    public var times: [TimeOfDay]
    public var ring: Bool
    public var dryRun: Bool

    public init(app: String, times: [TimeOfDay], ring: Bool, dryRun: Bool) {
        self.app = app
        self.times = times
        self.ring = ring
        self.dryRun = dryRun
    }
}

// MARK: - Outcomes

public enum ShowOutcome: Equatable {
    case launched
    case surfaced
    case failed(String)
    /// The app was not brought up on purpose: there was no user to bring it
    /// up to. This is not a failure of the command - the command was never
    /// run.
    case notShown(reason: String)
}

public enum AlarmOutcome: Equatable {
    /// Somebody answered.
    case rung(rings: Int)
    /// Nobody came back. The machine is about to sleep, or already has, so this
    /// wake has passed and there is nothing left to ring at.
    case failed(rings: Int)
    case silent(reason: String)
}