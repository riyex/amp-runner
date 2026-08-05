import Foundation
import Combine
import AmpRunnerCore

/// Supervises exactly one `amp --no-tui` process for one profile.
///
/// Two independent sources of truth feed `status`:
///  * monitored process liveness and exit code — always reliable
///  * parsed log lines — heuristic, and never allowed to contradict a dead process
@MainActor
final class ProcessSupervisor: ObservableObject {

    /// How many log lines are kept in memory for the log viewer.
    static let logCapacity = 500

    /// How long a graceful SIGINT is given before escalating.
    static let gracefulShutdownTimeout: TimeInterval = 8

    @Published private(set) var status: RunnerStatus = .stopped
    @Published private(set) var logLines: [String] = []
    @Published private(set) var lastEvent: RunnerEvent?

    let profileID: UUID
    private(set) var profile: RunnerProfile

    /// Emits every parsed event so the coordinator can raise notifications.
    let events = PassthroughSubject<RunnerEvent, Never>()

    private let parser: RunnerLogParser
    private let homeDirectoryPath: String
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutRemainder = Data()
    private var stderrRemainder = Data()
    private var escalationTask: Task<Void, Never>?
    private var logFileHandle: FileHandle?

    init(
        profile: RunnerProfile,
        parser: RunnerLogParser = RunnerLogParser(),
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.profileID = profile.id
        self.profile = profile
        self.parser = parser
        self.homeDirectoryPath = homeDirectoryPath
    }

    var isRunning: Bool { process?.isRunning ?? false }

    /// Applies an edited profile. A running process keeps its old command until it is
    /// restarted — the user is told this in the profile editor.
    func update(profile: RunnerProfile) {
        self.profile = profile
    }

    /// The Amp command that `start()` hands to the native monitor helper.
    func resolvedCommand() throws -> ResolvedRunnerCommand {
        try RunnerCommandBuilder.resolve(profile: profile, homeDirectoryPath: homeDirectoryPath)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }

        let command: ResolvedRunnerCommand
        do {
            command = try resolvedCommand()
        } catch {
            setStatus(.error("\(error)"))
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: command.workingDirectoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            setStatus(.error("Working directory does not exist: \(command.workingDirectoryURL.path)"))
            return
        }
        guard FileManager.default.isExecutableFile(atPath: command.executableURL.path) else {
            setStatus(.error("Not an executable file: \(command.executableURL.path)"))
            return
        }

        stdoutRemainder = Data()
        stderrRemainder = Data()
        logLines.removeAll(keepingCapacity: true)
        openLogFile()

        let monitorExecutableURL = Self.monitorExecutableURL()
        guard FileManager.default.isExecutableFile(atPath: monitorExecutableURL.path) else {
            closeLogFile()
            setStatus(.error("Monitor helper is missing: \(monitorExecutableURL.path)"))
            return
        }

        let launchPlan = RunnerProcessLauncher.monitoredLaunchPlan(
            for: command,
            monitorExecutableURL: monitorExecutableURL,
            parentProcessID: ProcessInfo.processInfo.processIdentifier,
            shutdownTimeoutSeconds: Self.gracefulShutdownTimeout
        )

        let process = Process()
        process.executableURL = launchPlan.executableURL
        process.arguments = launchPlan.arguments
        process.currentDirectoryURL = command.workingDirectoryURL
        // The helper inherits the app environment and starts Amp directly. It exists only
        // to forward stops and kill Amp if the app is killed before normal cleanup runs.
        process.environment = ProcessInfo.processInfo.environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.ingest(data, isStandardError: false) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.ingest(data, isStandardError: true) }
        }

        process.terminationHandler = { [weak self] finished in
            let reason = finished.terminationReason
            let code = finished.terminationStatus
            Task { @MainActor in self?.handleTermination(reason: reason, exitCode: code) }
        }

        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            closeLogFile()
            setStatus(.error("Failed to launch: \(error.localizedDescription)"))
            return
        }

        self.process = process
        self.stdoutPipe = out
        self.stderrPipe = err
        append(logLine: "[amp-runner] equivalent terminal command: " + RunnerCommandBuilder.commandPreview(for: command))
        setStatus(.starting)
    }

    /// SIGINT first so `amp` can run its own graceful shutdown (it prompts about
    /// in-flight threads), escalating to SIGTERM only if it does not exit in time.
    func stop() {
        guard let process, process.isRunning else {
            setStatus(.stopped)
            return
        }

        append(logLine: "[amp-runner] sending SIGINT (graceful stop)")
        kill(process.processIdentifier, SIGINT)

        escalationTask?.cancel()
        escalationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.gracefulShutdownTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.escalateShutdown()
        }
    }

    func restart() {
        if isRunning {
            restartAfterStop()
        } else {
            start()
        }
    }

    private func restartAfterStop() {
        stop()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Self.gracefulShutdownTimeout + 4)
            while self.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            self.start()
        }
    }

    private func escalateShutdown() {
        guard let process, process.isRunning else { return }
        append(logLine: "[amp-runner] graceful stop timed out, sending SIGTERM")
        process.terminate()
    }

    private static func monitorExecutableURL() -> URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("AmpRunnerMonitor")
    }

    // MARK: - Output handling

    private func ingest(_ data: Data, isStandardError: Bool) {
        var buffer = isStandardError ? stderrRemainder : stdoutRemainder
        buffer.append(data)

        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            lines.append(String(decoding: lineData, as: UTF8.self))
        }

        if isStandardError {
            stderrRemainder = buffer
        } else {
            stdoutRemainder = buffer
        }

        for line in lines {
            handle(line: line)
        }
    }

    private func handle(line: String) {
        let cleaned = line.replacingOccurrences(of: "\r", with: "")
        append(logLine: cleaned)

        guard let event = parser.parse(line: cleaned) else { return }
        lastEvent = event
        events.send(event)

        // A heuristic log line must never resurrect a process that already exited.
        if let implied = event.impliedStatus, isRunning {
            setStatus(implied)
        }
    }

    private func append(logLine: String) {
        logLines.append(logLine)
        if logLines.count > Self.logCapacity {
            logLines.removeFirst(logLines.count - Self.logCapacity)
        }
        writeToLogFile(logLine)
    }

    private func handleTermination(reason: Process.TerminationReason, exitCode: Int32) {
        escalationTask?.cancel()
        escalationTask = nil

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        flushRemainders()
        stdoutPipe = nil
        stderrPipe = nil
        process = nil

        // Exit-code detection is authoritative and always overrides the log heuristics.
        if reason == .uncaughtSignal {
            append(logLine: "[amp-runner] process terminated by signal \(exitCode)")
            setStatus(.stopped)
        } else if exitCode == 0 {
            append(logLine: "[amp-runner] process exited cleanly")
            setStatus(.stopped)
        } else {
            append(logLine: "[amp-runner] process exited with code \(exitCode)")
            setStatus(.error("exit code \(exitCode)"))
        }
        closeLogFile()
    }

    private func flushRemainders() {
        for remainder in [stdoutRemainder, stderrRemainder] where !remainder.isEmpty {
            handle(line: String(decoding: remainder, as: UTF8.self))
        }
        stdoutRemainder = Data()
        stderrRemainder = Data()
    }

    private func setStatus(_ newStatus: RunnerStatus) {
        guard status != newStatus else { return }
        status = newStatus
    }

    // MARK: - Log file mirror

    /// Mirrors output to `~/Library/Logs/AmpRunner/<profile-id>.log` so the log viewer
    /// can offer "Reveal in Finder" and so output survives an app restart.
    static func logFileURL(profileID: UUID, homeDirectoryPath: String) -> URL {
        URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("AmpRunner", isDirectory: true)
            .appendingPathComponent("\(profileID.uuidString).log", isDirectory: false)
    }

    var logFileURL: URL {
        Self.logFileURL(profileID: profileID, homeDirectoryPath: homeDirectoryPath)
    }

    private func openLogFile() {
        closeLogFile()
        let url = logFileURL
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            logFileHandle = handle
        } catch {
            // Log mirroring is a convenience; failing to open it must not block a run.
            logFileHandle = nil
        }
    }

    private func writeToLogFile(_ line: String) {
        guard let logFileHandle else { return }
        try? logFileHandle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func closeLogFile() {
        try? logFileHandle?.close()
        logFileHandle = nil
    }
}
