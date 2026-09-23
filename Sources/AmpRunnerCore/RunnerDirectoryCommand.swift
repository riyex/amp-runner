import Foundation

/// Live directory operations use the launched command, not an edited profile.
public enum RunnerDirectoryCommand {
    public enum Operation: Equatable, Sendable {
        case list
        case add(String)
        case remove(String)
    }

    public enum Error: Swift.Error, LocalizedError {
        case missingRunnerID

        public var errorDescription: String? {
            "The running command needs an explicit --runner-id to manage its directories safely."
        }
    }

    public static func resolve(_ operation: Operation, launch: ResolvedRunnerCommand) throws -> ResolvedRunnerCommand {
        func value(for flag: String) -> String? {
            var value: String?
            for (index, argument) in launch.arguments.enumerated() {
                if argument.hasPrefix(flag + "=") {
                    value = String(argument.dropFirst(flag.count + 1))
                } else if argument == flag, index + 1 < launch.arguments.count,
                          !launch.arguments[index + 1].hasPrefix("-") {
                    value = launch.arguments[index + 1]
                }
            }
            return value
        }
        guard let runnerID = value(for: "--runner-id"), !runnerID.isEmpty else {
            throw Error.missingRunnerID
        }
        var arguments = ["runner", "dirs"]
        switch operation {
        case .list: arguments += ["list"]
        case .add(let path): arguments += ["add", path]
        case .remove(let path): arguments += ["remove", path]
        }
        arguments += ["--runner-id", runnerID]
        if let settings = value(for: "--settings-file") {
            arguments += ["--settings-file", settings]
        }
        return ResolvedRunnerCommand(executableURL: launch.executableURL, arguments: arguments,
                                     workingDirectoryURL: launch.workingDirectoryURL)
    }
}
