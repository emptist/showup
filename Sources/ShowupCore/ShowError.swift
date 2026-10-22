/// Everything showup can be asked to do wrong, and every way talking to macOS
/// can fail.
///
/// One error type across both layers, so a failure keeps its meaning as it
/// crosses the platform boundary instead of decaying into a `String`.
public enum ShowError: Error, Equatable, CustomStringConvertible {
    // Argument problems, all reported before anything is scheduled.
    case missingApp
    case emptyApp
    case noTimesGiven
    case invalidTime(String)
    case timesSplitBySpaces(String)
    case missingValue(String)
    case unknownArgument(String)

    // Failures reading the system.
    case unavailable(what: String, reason: String)
    case failed(command: String, status: Int32, detail: String)
    case unexpectedOutput(what: String, sample: String)

    // The kernel's wake list is root ground. Refused there is not seen as a
    // failure to nag about but a designed handoff: the run says the line once
    // - `announced` is set only for the refusal that gets to say it - and every
    // refusal after that in the same run is the same standing fact, already
    // on record. No silence anywhere: the first moment still speaks.
    case wakeIsNotOurs(announced: Bool)

    public var description: String {
        switch self {
        case .missingApp:
            "no app given, pass one with -a/--app"
        case .emptyApp:
            "the app name given with -a/--app is empty"
        case .noTimesGiven:
            "no times given, pass some with -t/--times"
        case .invalidTime(let input):
            "expected a time like 8:00, but got \"\(input)\""
        case .timesSplitBySpaces(let value):
            """
            the times "\(value)" end in a comma, so the shell split the list on \
            the spaces after each one. Write them as a single argument, such as \
            "8:00,12:00,16:00"
            """
        case .missingValue(let flag):
            "\"\(flag)\" needs a value"
        case .unknownArgument(let argument):
            "unexpected argument \(argument)"
        case .unavailable(let what, let reason):
            "could not read \(what): \(reason)"
        case .failed(let command, let status, let detail):
            detail.isEmpty
                ? "\(command) exited with status \(status)"
                : "\(command) exited with status \(status): \(detail)"
        case .unexpectedOutput(let what, let sample):
            "could not understand the \(what) output, which began: \(sample)"
        case .wakeIsNotOurs:
            "the wake is the renewal side's to arm; this run does not own the kernel list"
        }
    }
}