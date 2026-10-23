public func parseCLI(_ arguments: [String]) throws(ShowError) -> Command {
    // The renewal is a positional command, not a flag set: it takes the one
    // thing it is not allowed to guess, the directory the contract lives in.
    if arguments.first == "renew" {
        guard arguments.count == 2 else { throw ShowError.missingValue("renew") }
        return .renew(directory: arguments[1])
    }

    // Nothing said at all is the installed night run: the schedule it serves
    // is whoever's contract is on the user ground, not an argument. Every
    // other shape still has to say its app, the way it always has.
    if arguments.isEmpty {
        return .runFromContract
    }

    var app: String?
    var times: [TimeOfDay] = []
    var dryRun = false
    var index = arguments.startIndex

    while index < arguments.endIndex {
        let argument = arguments[index]
        index += 1

        switch argument {
        case "-h", "--help":
            return .help
        case "-n", "--dry-run":
            dryRun = true
        case "-a", "--app":
            guard index < arguments.endIndex else { throw ShowError.missingValue(argument) }
            app = arguments[index].trimmed()
            index += 1
        case "-t", "--times":
            guard index < arguments.endIndex else { throw ShowError.missingValue(argument) }
            times.append(contentsOf: try parseTimesArgument(arguments[index]))
            index += 1
        default:
            guard let (name, value) = splitAssignment(argument) else {
                throw ShowError.unknownArgument(argument)
            }
            switch name {
            case "app": app = value.trimmed()
            case "times": times.append(contentsOf: try parseTimesArgument(value))
            default: throw ShowError.unknownArgument(argument)
            }
        }
    }

    guard let app else { throw ShowError.missingApp }
    guard !app.isEmpty else { throw ShowError.emptyApp }
    guard !times.isEmpty else { throw ShowError.noTimesGiven }

    let config = Config(app: app, times: normalise(times), dryRun: dryRun)
    return dryRun ? .showSchedule(config) : .show(config)
}

/// `--flag=value` into its two halves, or `nil` if this is not that form.
private func splitAssignment(_ argument: String) -> (name: String, value: String)? {
    guard argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") else { return nil }
    let name = String(argument[argument.index(argument.startIndex, offsetBy: 2)..<equals])
    let value = String(argument[argument.index(after: equals)...])
    return (name, value)
}

/// A times argument, reporting the two ways it goes wrong in words a user can act on.
private func parseTimesArgument(_ value: String) throws(ShowError) -> [TimeOfDay] {
    // An unquoted "8:00, 12:00" reaches us as "8:00," with "12:00" as a
    // separate argument, which is a shell problem rather than a time problem.
    if value.hasSuffix(",") { throw ShowError.timesSplitBySpaces(value) }
    do {
        return try parseTimeList(value)
    } catch {
        throw ShowError.invalidTime(value)
    }
}

extension String {
    fileprivate func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}