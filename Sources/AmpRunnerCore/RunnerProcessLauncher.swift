import Foundation

/// The concrete process invocation used to supervise a runner command.
public struct RunnerProcessLaunchPlan: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]

    public init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }
}

/// Builds a native monitor invocation that keeps the Amp child tied to the app lifetime.
///
/// A `Process` child is normally reparented if the app is killed by Xcode or crashes.
/// The monitor helper survives long enough to notice that the app's PID disappeared,
/// then forwards a graceful shutdown to the Amp process it started.
public enum RunnerProcessLauncher {
    public static func monitoredLaunchPlan(
        for command: ResolvedRunnerCommand,
        monitorExecutableURL: URL,
        parentProcessID: Int32,
        pollIntervalSeconds: TimeInterval = 1,
        shutdownTimeoutSeconds: TimeInterval = 8
    ) -> RunnerProcessLaunchPlan {
        RunnerProcessLaunchPlan(
            executableURL: monitorExecutableURL,
            arguments: [
                "--parent-pid",
                "\(parentProcessID)",
                "--poll-interval",
                "\(pollIntervalSeconds)",
                "--shutdown-timeout",
                "\(shutdownTimeoutSeconds)",
                "--",
                command.executableURL.path
            ] + command.arguments
        )
    }
}
