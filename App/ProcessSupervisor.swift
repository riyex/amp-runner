import Foundation
import Combine
import AmpRunnerCore

typealias AmpVersionProvider = (ResolvedRunnerCommand, [String: String]) async -> AmpVersion?
typealias TerminationCallbackScheduler = (@escaping @MainActor () -> Void) -> Void

enum SupervisorRestartLifecycle: Equatable {
    case none
    case inProgress
    case completed
    case failed
    case aborted
}

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
    @Published private(set) var activeThread: RunnerThreadDetails?
    @Published private(set) var activeThreadStartedAt: Date?
    @Published private(set) var lastCompletedThread: RunnerThreadDetails?
    @Published private(set) var lastThreadDuration: TimeInterval?
    @Published private(set) var runningAmpVersion: AmpVersion?
    @Published private(set) var restartLifecycle: SupervisorRestartLifecycle = .none

    let profileID: UUID
    private(set) var profile: RunnerProfile

    /// Emits every parsed event so the coordinator can raise notifications.
    let events = PassthroughSubject<RunnerEvent, Never>()

    private let parser: RunnerLogParser
    private let homeDirectoryPath: String
    private let environmentProvider: () -> [String: String]
    private let versionProvider: AmpVersionProvider
    private let monitorExecutableURL: URL
    private let terminationCallbackScheduler: TerminationCallbackScheduler
    private let restartWaitTimeout: TimeInterval
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutRemainder = Data()
    private var stderrRemainder = Data()
    private var escalationTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var logFileHandle: FileHandle?
    private var runningCommand: ResolvedRunnerCommand?
    private var runningEnvironment: [String: String]?
    private var metadataTask: Task<RunnerThreadDetails?, Never>?
    private var metadataRequestID: UUID?
    private var restartPolicy: RunnerRestartPolicy
    private var isStoppingIntentionally = false
    private var restartPendingAfterTermination = false

    init(
        profile: RunnerProfile,
        parser: RunnerLogParser = RunnerLogParser(),
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environmentProvider: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
        versionProvider: @escaping AmpVersionProvider = { _, _ in nil },
        monitorExecutableURL: URL? = nil,
        terminationCallbackScheduler: @escaping TerminationCallbackScheduler = { callback in
            Task { @MainActor in callback() }
        },
        restartPolicy: RunnerRestartPolicy = RunnerRestartPolicy(),
        restartWaitTimeout: TimeInterval = 12
    ) {
        self.profileID = profile.id
        self.profile = profile
        self.parser = parser
        self.homeDirectoryPath = homeDirectoryPath
        self.environmentProvider = environmentProvider
        self.versionProvider = versionProvider
        self.monitorExecutableURL = monitorExecutableURL ?? Self.bundledMonitorExecutableURL()
        self.terminationCallbackScheduler = terminationCallbackScheduler
        self.restartPolicy = restartPolicy
        self.restartWaitTimeout = restartWaitTimeout
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
        start(resetRestartPolicy: true)
    }

    private func start(resetRestartPolicy: Bool) {
        guard !isRunning, launchTask == nil else { return }
        restartTask?.cancel()
        restartTask = nil
        isStoppingIntentionally = false
        if resetRestartPolicy {
            restartPolicy.reset()
        }

        let command: ResolvedRunnerCommand
        do {
            command = try resolvedCommand()
        } catch {
            if restartLifecycle == .inProgress { restartLifecycle = .failed }
            setStatus(.error("\(error)"))
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: command.workingDirectoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            if restartLifecycle == .inProgress { restartLifecycle = .failed }
            setStatus(.error("Working directory does not exist: \(command.workingDirectoryURL.path)"))
            return
        }
        guard FileManager.default.isExecutableFile(atPath: command.executableURL.path) else {
            if restartLifecycle == .inProgress { restartLifecycle = .failed }
            setStatus(.error("Not an executable file: \(command.executableURL.path)"))
            return
        }

        let launchEnvironment = environmentProvider()
        runningAmpVersion = nil
        setStatus(.starting)

        let versionProvider = versionProvider
        launchTask = Task { @MainActor [weak self] in
            let version = await versionProvider(command, launchEnvironment)
            guard let self, !Task.isCancelled else { return }
            self.launchTask = nil
            self.launch(command: command, environment: launchEnvironment, version: version)
        }
    }

    private func launch(
        command: ResolvedRunnerCommand,
        environment launchEnvironment: [String: String],
        version: AmpVersion?
    ) {
        guard !isStoppingIntentionally, !isRunning else { return }
        stdoutRemainder = Data()
        stderrRemainder = Data()
        logLines.removeAll(keepingCapacity: true)
        activeThread = nil
        activeThreadStartedAt = nil
        lastCompletedThread = nil
        lastThreadDuration = nil
        metadataTask?.cancel()
        metadataRequestID = nil
        openLogFile()

        let monitorExecutableURL = monitorExecutableURL
        guard FileManager.default.isExecutableFile(atPath: monitorExecutableURL.path) else {
            closeLogFile()
            if restartLifecycle == .inProgress { restartLifecycle = .failed }
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
        // The helper and Amp share one environment snapshot for this launch. The helper
        // exists only to forward stops and kill Amp if the app is killed before normal cleanup runs.
        process.environment = launchEnvironment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                guard let self, let process, self.process === process else { return }
                self.ingest(data, isStandardError: false)
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                guard let self, let process, self.process === process else { return }
                self.ingest(data, isStandardError: true)
            }
        }

        let terminationCallbackScheduler = terminationCallbackScheduler
        process.terminationHandler = { [weak self, weak out, weak err] finished in
            let reason = finished.terminationReason
            let code = finished.terminationStatus
            terminationCallbackScheduler {
                out?.fileHandleForReading.readabilityHandler = nil
                err?.fileHandleForReading.readabilityHandler = nil
                self?.handleTermination(process: finished, reason: reason, exitCode: code)
            }
        }

        self.process = process
        self.stdoutPipe = out
        self.stderrPipe = err
        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            runningEnvironment = nil
            runningAmpVersion = nil
            self.process = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            closeLogFile()
            if restartLifecycle == .inProgress { restartLifecycle = .failed }
            setStatus(.error("Failed to launch: \(error.localizedDescription)"))
            return
        }

        runningCommand = command
        runningEnvironment = launchEnvironment
        runningAmpVersion = version
        if restartLifecycle == .inProgress { restartLifecycle = .completed }

        append(logLine: "[amp-runner] equivalent terminal command: " + RunnerCommandBuilder.commandPreview(for: command))
    }

    /// SIGINT first so `amp` can run its own graceful shutdown (it prompts about
    /// in-flight threads), escalating to SIGTERM only if it does not exit in time.
    func stop() {
        restartPendingAfterTermination = false
        if restartLifecycle == .inProgress { restartLifecycle = .aborted }
        launchTask?.cancel()
        launchTask = nil
        restartTask?.cancel()
        restartTask = nil
        isStoppingIntentionally = true

        guard let process else {
            isStoppingIntentionally = false
            runningAmpVersion = nil
            setStatus(.stopped)
            return
        }
        guard process.isRunning else { return }

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
        restartLifecycle = .inProgress
        if process != nil {
            restartAfterStop()
        } else {
            start()
        }
    }

    private func restartAfterStop() {
        stop()
        restartLifecycle = .inProgress
        guard restartTask == nil else { return }
        restartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(self.restartWaitTimeout)
            while !Task.isCancelled && self.process != nil && Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard !Task.isCancelled else { return }
            self.restartTask = nil
            guard self.process == nil else {
                self.append(logLine: "[amp-runner] restart timed out waiting for the previous process to exit")
                self.restartPendingAfterTermination = true
                self.restartLifecycle = .failed
                return
            }
            self.start()
        }
    }

    private func escalateShutdown() {
        guard let process, process.isRunning else { return }
        append(logLine: "[amp-runner] graceful stop timed out, sending SIGTERM")
        process.terminate()
    }

    private static func bundledMonitorExecutableURL() -> URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("AmpRunnerMonitor")
    }

    var threadSummary: String? {
        if let activeThread {
            var parts = [activeThread.displayName]
            if let project = activeThread.projectDisplayName {
                parts.append(project)
            }
            if let activeThreadStartedAt {
                parts.append("running \(Self.formattedDuration(Date().timeIntervalSince(activeThreadStartedAt)))")
            }
            return parts.joined(separator: " - ")
        }

        if let lastCompletedThread {
            var parts = ["Last: \(lastCompletedThread.displayName)"]
            if let lastThreadDuration {
                parts.append(Self.formattedDuration(lastThreadDuration))
            }
            return parts.joined(separator: " - ")
        }

        return nil
    }

    var threadURLString: String? {
        activeThread?.webURLString ?? lastCompletedThread?.webURLString
    }

    static func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }

        let totalMinutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if totalMinutes < 60 {
            return seconds == 0 ? "\(totalMinutes)m" : "\(totalMinutes)m \(seconds)s"
        }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
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

        guard let parsedEvent = parser.parse(line: cleaned) else { return }
        lastEvent = parsedEvent

        guard let event = record(event: parsedEvent) else { return }

        // A heuristic log line must never resurrect a process that already exited.
        if let implied = event.impliedStatus, isRunning {
            setStatus(implied)
        }

        emit(event: event)
    }

    private func record(event: RunnerEvent) -> RunnerEvent? {
        switch event {
        case .threadStarted(let observed):
            let previous = activeThread
            let hadActiveThread = activeThreadStartedAt != nil
            let merged = (previous ?? RunnerThreadDetails()).merging(observed)
            activeThread = merged
            if activeThreadStartedAt == nil {
                activeThreadStartedAt = Date()
            }
            scheduleMetadataRefresh(for: merged)

            guard !isDuplicateStart(
                hadActiveThread: hadActiveThread,
                previous: previous,
                observed: observed
            ) else {
                return nil
            }
            return .threadStarted(merged)

        case .threadIdle(let observed):
            let duration = activeThreadStartedAt.map { Date().timeIntervalSince($0) }
            let merged = (activeThread ?? RunnerThreadDetails()).merging(observed)
            let thread = merged.isEmpty ? nil : merged
            activeThread = nil
            activeThreadStartedAt = nil
            lastCompletedThread = thread
            lastThreadDuration = duration
            return .threadIdle(thread)

        case .threadFinished(let observed, _):
            let duration = activeThreadStartedAt.map { Date().timeIntervalSince($0) }
            let merged = (activeThread ?? RunnerThreadDetails()).merging(observed)
            let thread = merged.isEmpty ? nil : merged
            activeThread = nil
            activeThreadStartedAt = nil
            lastCompletedThread = thread
            lastThreadDuration = duration
            return .threadFinished(thread, duration: duration)

        case .threadFailed(let detail, let observed, _):
            let duration = activeThreadStartedAt.map { Date().timeIntervalSince($0) }
            let merged = (activeThread ?? RunnerThreadDetails()).merging(observed)
            let thread = merged.isEmpty ? nil : merged
            activeThread = nil
            activeThreadStartedAt = nil
            lastCompletedThread = thread
            lastThreadDuration = duration
            return .threadFailed(detail, thread: thread, duration: duration)

        case .statusChanged, .unrecognizedLine:
            return event
        }
    }

    private func isDuplicateStart(
        hadActiveThread: Bool,
        previous: RunnerThreadDetails?,
        observed: RunnerThreadDetails
    ) -> Bool {
        guard hadActiveThread else { return false }
        guard let previousID = previous?.id, let observedID = observed.id else { return true }
        return previousID == observedID
    }

    private func emit(event: RunnerEvent) {
        guard event.isNotifiable else {
            events.send(event)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let enriched = await self.enrichedNotificationEvent(event)
            self.events.send(enriched)
        }
    }

    private func enrichedNotificationEvent(_ event: RunnerEvent) async -> RunnerEvent {
        guard let metadata = await metadataTask?.value else { return event }

        switch event {
        case .threadStarted(let details):
            let enriched = details.merging(metadata)
            if activeThread != nil {
                activeThread = activeThread?.merging(metadata) ?? metadata
            }
            return .threadStarted(enriched)

        case .threadIdle(let details):
            let enriched = (details ?? RunnerThreadDetails()).merging(metadata)
            let thread = enriched.isEmpty ? details : enriched
            lastCompletedThread = thread
            return .threadIdle(thread)

        case .threadFinished(let details, let duration):
            let enriched = (details ?? RunnerThreadDetails()).merging(metadata)
            let thread = enriched.isEmpty ? details : enriched
            lastCompletedThread = thread
            return .threadFinished(thread, duration: duration)

        case .threadFailed(let detail, let details, let duration):
            let enriched = (details ?? RunnerThreadDetails()).merging(metadata)
            let thread = enriched.isEmpty ? details : enriched
            lastCompletedThread = thread
            return .threadFailed(detail, thread: thread, duration: duration)

        case .statusChanged, .unrecognizedLine:
            return event
        }
    }

    private func scheduleMetadataRefresh(for thread: RunnerThreadDetails) {
        guard let runningCommand, let runningEnvironment else { return }

        metadataTask?.cancel()
        let requestID = UUID()
        metadataRequestID = requestID

        let task = Task.detached(priority: .utility) {
            AmpThreadMetadataFetcher.fetchMatchingThread(
                observed: thread,
                command: runningCommand,
                environment: runningEnvironment
            )
        }
        metadataTask = task

        Task { @MainActor [weak self] in
            guard let self, let metadata = await task.value else { return }
            guard self.metadataRequestID == requestID, self.activeThread != nil else { return }
            self.activeThread = self.activeThread?.merging(metadata) ?? metadata
        }
    }

    private func append(logLine: String) {
        logLines.append(logLine)
        if logLines.count > Self.logCapacity {
            logLines.removeFirst(logLines.count - Self.logCapacity)
        }
        writeToLogFile(logLine)
    }

    private func handleTermination(
        process finishedProcess: Process,
        reason: Process.TerminationReason,
        exitCode: Int32
    ) {
        guard process === finishedProcess else { return }
        let stoppedIntentionally = isStoppingIntentionally
        let restartAfterTermination = restartPendingAfterTermination
        isStoppingIntentionally = false
        restartPendingAfterTermination = false
        escalationTask?.cancel()
        escalationTask = nil

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        flushRemainders()
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        runningCommand = nil
        runningEnvironment = nil
        runningAmpVersion = nil
        metadataTask?.cancel()
        metadataRequestID = nil

        let terminationMessage: String
        let isAbnormalExit: Bool
        if reason == .uncaughtSignal {
            terminationMessage = "process terminated by signal \(exitCode)"
            isAbnormalExit = true
        } else if exitCode == 0 {
            terminationMessage = "process exited cleanly"
            isAbnormalExit = false
        } else {
            terminationMessage = "process exited with code \(exitCode)"
            isAbnormalExit = true
        }

        append(logLine: "[amp-runner] \(terminationMessage)")
        if stoppedIntentionally {
            restartPolicy.reset()
            setStatus(.stopped)
        } else if isAbnormalExit {
            scheduleRestart(afterAbnormalExit: terminationMessage)
        } else {
            restartPolicy.reset()
            setStatus(.stopped)
        }
        activeThread = nil
        activeThreadStartedAt = nil
        closeLogFile()
        if restartAfterTermination {
            restartLifecycle = .inProgress
            start()
        }
    }

    private func scheduleRestart(afterAbnormalExit terminationMessage: String) {
        switch restartPolicy.recordAbnormalExit() {
        case .restart(let delay, let attempt):
            let delayDescription = Self.formattedDuration(delay)
            append(logLine: "[amp-runner] restarting in \(delayDescription) after abnormal exit (attempt \(attempt))")
            setStatus(.error("\(terminationMessage); restarting in \(delayDescription)"))
            restartTask?.cancel()
            restartTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.start(resetRestartPolicy: false)
            }

        case .stop(let message):
            append(logLine: "[amp-runner] \(message); not restarting")
            setStatus(.error("\(message); \(terminationMessage)"))
        }
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

private struct AmpThreadListEntry: Decodable {
    var id: String
    var title: String?
    var updated: String?
    var tree: String?
    var messageCount: Int?

    var details: RunnerThreadDetails {
        RunnerThreadDetails(
            id: id,
            title: title,
            webURLString: "https://ampcode.com/threads/\(id)",
            treeURLString: tree,
            messageCount: messageCount,
            updatedAt: Self.parseDate(updated)
        )
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private enum AmpThreadMetadataFetcher {
    private static let timeout: TimeInterval = 3

    static func fetchMatchingThread(
        observed: RunnerThreadDetails,
        command: ResolvedRunnerCommand,
        environment: [String: String]
    ) -> RunnerThreadDetails? {
        guard let data = runThreadList(command: command, environment: environment),
              let jsonData = extractJSONData(from: data),
              let entries = try? JSONDecoder().decode([AmpThreadListEntry].self, from: jsonData)
        else {
            return nil
        }

        if let id = observed.id,
           let match = entries.first(where: { $0.id == id }) {
            return observed.merging(match.details)
        }

        let workingPath = normalizedPath(command.workingDirectoryURL.path)
        if let match = entries.first(where: { normalizedTreePath($0.tree) == workingPath }) {
            return observed.merging(match.details)
        }

        return nil
    }

    private static func runThreadList(
        command: ResolvedRunnerCommand,
        environment: [String: String]
    ) -> Data? {
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = ["threads", "list", "--json", "--limit", "25"]
        process.currentDirectoryURL = command.workingDirectoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let output = Pipe()
        process.standardOutput = output

        var metadataEnvironment = environment
        metadataEnvironment["NO_COLOR"] = "1"
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmpRunnerAmpCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        metadataEnvironment["XDG_CACHE_HOME"] = cacheURL.path
        metadataEnvironment["AMP_LOG_FILE"] = cacheURL.appendingPathComponent("cli.log").path
        process.environment = metadataEnvironment

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return output.fileHandleForReading.readDataToEndOfFile()
    }

    private static func extractJSONData(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let end = text.lastIndex(where: { $0 == "]" || $0 == "}" }),
              start <= end
        else {
            return nil
        }
        return Data(text[start...end].utf8)
    }

    private static func normalizedTreePath(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if let url = URL(string: value), url.isFileURL {
            return normalizedPath(url.path)
        }
        return normalizedPath(value)
    }

    private static func normalizedPath(_ value: String) -> String {
        var path = URL(fileURLWithPath: value).standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
