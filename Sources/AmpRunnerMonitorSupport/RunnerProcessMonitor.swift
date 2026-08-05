import Foundation

#if os(Linux)
import Glibc
#elseif os(macOS)
import Darwin
#endif

public struct RunnerProcessMonitorConfiguration: Equatable, Sendable {
    public let parentProcessID: Int32
    public let pollInterval: TimeInterval
    public let shutdownTimeout: TimeInterval
    public let executableURL: URL
    public let arguments: [String]
    public let workingDirectoryURL: URL

    public init(
        parentProcessID: Int32,
        pollInterval: TimeInterval,
        shutdownTimeout: TimeInterval,
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL
    ) {
        self.parentProcessID = parentProcessID
        self.pollInterval = pollInterval
        self.shutdownTimeout = shutdownTimeout
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectoryURL = workingDirectoryURL
    }

    public static func parse(
        arguments: [String],
        workingDirectoryURL: URL
    ) throws -> RunnerProcessMonitorConfiguration {
        var parentProcessID: Int32?
        var pollInterval: TimeInterval = 1
        var shutdownTimeout: TimeInterval = 8
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                let commandArguments = Array(arguments.dropFirst(index + 1))
                guard let executablePath = commandArguments.first else {
                    throw RunnerProcessMonitorError.missingExecutable
                }
                return RunnerProcessMonitorConfiguration(
                    parentProcessID: try requireParentProcessID(parentProcessID),
                    pollInterval: pollInterval,
                    shutdownTimeout: shutdownTimeout,
                    executableURL: URL(fileURLWithPath: executablePath),
                    arguments: Array(commandArguments.dropFirst()),
                    workingDirectoryURL: workingDirectoryURL
                )
            }

            guard index + 1 < arguments.count else {
                throw RunnerProcessMonitorError.missingValue(argument)
            }

            let value = arguments[index + 1]
            switch argument {
            case "--parent-pid":
                guard let parsed = Int32(value), parsed > 0 else {
                    throw RunnerProcessMonitorError.invalidValue(argument, value)
                }
                parentProcessID = parsed
            case "--poll-interval":
                pollInterval = try parsePositiveTimeInterval(argument: argument, value: value)
            case "--shutdown-timeout":
                shutdownTimeout = try parsePositiveTimeInterval(argument: argument, value: value)
            default:
                throw RunnerProcessMonitorError.unknownArgument(argument)
            }
            index += 2
        }

        throw RunnerProcessMonitorError.missingSeparator
    }

    private static func requireParentProcessID(_ value: Int32?) throws -> Int32 {
        guard let value else {
            throw RunnerProcessMonitorError.missingParentProcessID
        }
        return value
    }

    private static func parsePositiveTimeInterval(
        argument: String,
        value: String
    ) throws -> TimeInterval {
        guard let parsed = TimeInterval(value), parsed > 0 else {
            throw RunnerProcessMonitorError.invalidValue(argument, value)
        }
        return parsed
    }
}

public enum RunnerProcessMonitorError: Error, Equatable, CustomStringConvertible {
    case missingParentProcessID
    case missingSeparator
    case missingExecutable
    case missingValue(String)
    case invalidValue(String, String)
    case unknownArgument(String)

    public var description: String {
        switch self {
        case .missingParentProcessID:
            return "Missing --parent-pid."
        case .missingSeparator:
            return "Missing -- before the Amp executable path."
        case .missingExecutable:
            return "Missing Amp executable path."
        case .missingValue(let argument):
            return "Missing value for \(argument)."
        case .invalidValue(let argument, let value):
            return "Invalid value for \(argument): \(value)."
        case .unknownArgument(let argument):
            return "Unknown argument: \(argument)."
        }
    }
}

public final class RunnerProcessMonitor {
    private let configuration: RunnerProcessMonitorConfiguration
    private let lock = NSLock()
    private var childProcess: Process?
    private var stopRequested = false

    public init(configuration: RunnerProcessMonitorConfiguration) {
        self.configuration = configuration
    }

    public func requestStop() {
        let process = locked {
            stopRequested = true
            return childProcess
        }
        interrupt(process)
    }

    public func run(
        standardOutput: FileHandle = .standardOutput,
        standardError: FileHandle = .standardError
    ) -> Int32 {
        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.currentDirectoryURL = configuration.workingDirectoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            write(
                "[amp-runner-monitor] failed to launch \(configuration.executableURL.path): \(error.localizedDescription)\n",
                to: standardError
            )
            return 127
        }

        locked {
            childProcess = process
        }

        var stoppedByMonitor = false
        while process.isRunning {
            if isStopRequested || !Self.processExists(pid: configuration.parentProcessID) {
                stoppedByMonitor = true
                stop(process)
                break
            }
            Thread.sleep(forTimeInterval: configuration.pollInterval)
        }

        process.waitUntilExit()
        locked {
            childProcess = nil
        }

        if stoppedByMonitor || isStopRequested {
            return 0
        }

        switch process.terminationReason {
        case .exit:
            return process.terminationStatus
        case .uncaughtSignal:
            return 128 + process.terminationStatus
        @unknown default:
            return process.terminationStatus
        }
    }

    private var isStopRequested: Bool {
        locked { stopRequested }
    }

    private func stop(_ process: Process) {
        interrupt(process)

        let deadline = Date().addingTimeInterval(configuration.shutdownTimeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: min(configuration.pollInterval, 0.05))
        }

        if process.isRunning {
            process.terminate()
        }
    }

    private func interrupt(_ process: Process?) {
        guard let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGINT)
    }

    private func write(_ message: String, to handle: FileHandle) {
        handle.write(Data(message.utf8))
    }

    private func locked<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    private static func processExists(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}
