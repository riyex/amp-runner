import Foundation
import Combine
import Darwin
import AmpRunnerCore

struct AmpExecutableRegistration: Equatable, Sendable {
    let executableURL: URL
    let configuredExecutableURL: URL
    let environment: [String: String]

    init(
        executableURL: URL,
        configuredExecutableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executableURL = executableURL
        self.configuredExecutableURL = configuredExecutableURL ?? executableURL
        self.environment = environment
    }
}

struct AmpExecutableUsage: Equatable, Sendable {
    let runnerCount: Int
    let alternatePathCount: Int
}

struct AmpExecutableIdentity: Equatable, Sendable {
    var modificationDate: Date?
    var fileSize: Int?
    var fileIdentifier: String?
}

enum AmpUpdateCheckState: Equatable, Sendable {
    case idle
    case checking
}

enum AmpExecutableInstallState: Equatable, Sendable {
    case idle
    case installing
    case succeeded(AmpVersion)
    case failed(String)
}

struct AmpInstallBatch: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case updated(AmpVersion)
        case noUpdateNeeded
        case failed
    }

    struct Result: Equatable, Sendable {
        let path: String
        let state: AmpExecutableInstallState
        let outcome: Outcome
    }

    let id: UUID
    let completedAt: Date
    let results: [Result]

    init(id: UUID = UUID(), completedAt: Date, results: [Result]) {
        self.id = id
        self.completedAt = completedAt
        self.results = results
    }
}

@MainActor
final class AmpUpdateController: ObservableObject {
    typealias ReleaseFetcher = (URLRequest) async throws -> Data
    typealias CommandExecution = (AmpCommandRequest) async throws -> AmpCommandResult
    typealias Sleeper = (TimeInterval) async throws -> Void
    typealias IdentityReader = (URL) -> AmpExecutableIdentity

    @Published private(set) var latestVersion: AmpVersion?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var checkState: AmpUpdateCheckState = .idle
    @Published private(set) var checkError: String?
    @Published private(set) var registeredExecutableURLs: [URL] = []
    @Published private(set) var registeredExecutableUsage: [String: AmpExecutableUsage] = [:]
    @Published private(set) var installedVersions: [String: AmpVersion] = [:]
    @Published private(set) var probeErrors: [String: String] = [:]
    @Published private(set) var installStates: [String: AmpExecutableInstallState] = [:]
    @Published private(set) var lastCompletedInstallBatch: AmpInstallBatch?

    private let fetchRelease: ReleaseFetcher
    private let executeCommand: CommandExecution
    private let sleep: Sleeper
    private let now: () -> Date
    private let readIdentity: IdentityReader
    private var automaticInstallEnabled = false
    private var scheduleTask: Task<Void, Never>?
    private var checkTask: Task<Result<AmpVersion, Error>, Never>?
    private var checkToken: UUID?
    private var probeReconciliationTask: Task<Void, Never>?
    private var probeTasks: [String: ProbeFlight] = [:]
    private var probedIdentities: [String: AmpExecutableIdentity] = [:]
    private var probedRelease: [String: AmpVersion?] = [:]
    private var probedEnvironments: [String: [String: String]] = [:]
    private var automaticAttempts: [String: AutomaticAttempt] = [:]
    private var installBatchTask: Task<Void, Never>?
    private var registeredEnvironments: [String: [String: String]] = [:]
    private var registrationGenerations: [String: UInt64] = [:]
    private var nextRegistrationGeneration: UInt64 = 0
    private var operationGeneration: UInt64 = 0

    init(
        fetchRelease: ReleaseFetcher? = nil,
        executeCommand: CommandExecution? = nil,
        sleep: Sleeper? = nil,
        now: @escaping () -> Date = Date.init,
        readIdentity: IdentityReader? = nil
    ) {
        self.fetchRelease = fetchRelease ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ControllerError.message("Release check returned HTTP \(http.statusCode).")
            }
            return data
        }
        self.executeCommand = executeCommand ?? { try await AmpCommandExecutor().execute($0) }
        self.sleep = sleep ?? { seconds in try await Task.sleep(for: .seconds(seconds)) }
        self.now = now
        self.readIdentity = readIdentity ?? Self.fileIdentity
    }

    func synchronizeExecutables(_ registrations: [AmpExecutableRegistration]) {
        let previousEnvironments = registeredEnvironments
        var seen = Set<String>()
        registeredExecutableURLs = registrations.compactMap { registration in
            let url = registration.executableURL.standardizedFileURL
            return seen.insert(url.path).inserted ? url : nil
        }
        let paths = Set(registeredExecutableURLs.map(\.path))
        registeredExecutableUsage = Dictionary(grouping: registrations) {
            $0.executableURL.standardizedFileURL.path
        }.mapValues { registrations in
            let canonicalPath = registrations[0].executableURL.standardizedFileURL.path
            let alternatePaths = Set(registrations.map {
                $0.configuredExecutableURL.standardizedFileURL.path
            }).subtracting([canonicalPath])
            return AmpExecutableUsage(
                runnerCount: registrations.count,
                alternatePathCount: alternatePaths.count
            )
        }
        var synchronizedEnvironments: [String: [String: String]] = [:]
        for registration in registrations {
            let path = registration.executableURL.standardizedFileURL.path
            if paths.contains(path), synchronizedEnvironments[path] == nil {
                synchronizedEnvironments[path] = registration.environment
            }
        }
        let changedEnvironmentPaths = paths.filter {
            registeredEnvironments[$0] != nil && registeredEnvironments[$0] != synchronizedEnvironments[$0]
        }
        let changedRegistrationPaths = Set(previousEnvironments.keys).union(synchronizedEnvironments.keys).filter {
            previousEnvironments[$0] != synchronizedEnvironments[$0]
        }
        for path in changedRegistrationPaths {
            nextRegistrationGeneration &+= 1
            registrationGenerations[path] = nextRegistrationGeneration
        }
        registeredEnvironments = synchronizedEnvironments
        installStates = installStates.filter { paths.contains($0.key) }
        installedVersions = installedVersions.filter { paths.contains($0.key) }
        probeErrors = probeErrors.filter { paths.contains($0.key) }
        for (path, flight) in probeTasks where !paths.contains(path) || changedEnvironmentPaths.contains(path) {
            flight.task.cancel()
            probeTasks[path] = nil
        }
        for path in changedRegistrationPaths where previousEnvironments[path] != nil {
            installStates[path] = nil
            probedIdentities[path] = nil
            probedRelease[path] = nil
            probedEnvironments[path] = nil
            automaticAttempts[path] = nil
        }
        registrationGenerations = registrationGenerations.filter { paths.contains($0.key) }
        probedIdentities = probedIdentities.filter { paths.contains($0.key) }
        probedRelease = probedRelease.filter { paths.contains($0.key) }
        probedEnvironments = probedEnvironments.filter { paths.contains($0.key) }
        automaticAttempts = automaticAttempts.filter { paths.contains($0.key) }
        triggerNeededProbes()
    }

    func registeredEnvironment(for executableURL: URL) -> [String: String]? {
        registeredEnvironments[executableURL.standardizedFileURL.path]
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        if enabled {
            guard scheduleTask == nil else { return }
            scheduleTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.sleep(3)
                    while !Task.isCancelled {
                        await self.checkNow(automatic: true)
                        try await self.sleep(3_600)
                    }
                } catch { }
            }
        } else {
            scheduleTask?.cancel()
            scheduleTask = nil
        }
    }

    func setAutomaticInstallEnabled(_ enabled: Bool) {
        automaticInstallEnabled = enabled
    }

    func checkNow(automatic: Bool = false) async {
        if let checkTask {
            _ = await checkTask.value
            return
        }
        let generation = operationGeneration
        let token = UUID()
        let fetchRelease = fetchRelease
        checkState = .checking
        checkToken = token
        let task = Task<Result<AmpVersion, Error>, Never> {
            var request = URLRequest(url: URL(string: "https://static.ampcode.com/cli/cli-version.txt")!)
            request.timeoutInterval = 5
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            do { return .success(try AmpReleaseResponse.parse(await fetchRelease(request))) }
            catch { return .failure(error) }
        }
        checkTask = task
        let result = await task.value
        guard operationGeneration == generation, checkToken == token else { return }
        checkTask = nil
        checkToken = nil
        checkState = .idle
        switch result {
        case let .success(version):
            latestVersion = version
            lastCheckedAt = now()
            checkError = nil
            triggerNeededProbes()
            if automaticInstallEnabled {
                await installOutdatedExecutables(automatic: automatic)
            }
        case let .failure(error):
            checkError = bounded(error.localizedDescription)
        }
    }

    private func triggerNeededProbes() {
        var needed: [(URL, [String: String])] = []
        for url in registeredExecutableURLs {
            let environment = registeredEnvironments[url.path] ?? ProcessInfo.processInfo.environment
            let path = url.path
            let identity = readIdentity(url)
            guard installedVersions[path] == nil || probedIdentities[path] != identity ||
                    probedRelease[path] != latestVersion ||
                    probedEnvironments[path] != environment else { continue }
            needed.append((url, environment))
        }
        guard !needed.isEmpty else { return }
        probeReconciliationTask?.cancel()
        probeReconciliationTask = Task { [weak self] in
            for (url, environment) in needed {
                guard let self else { return }
                guard !Task.isCancelled else { return }
                let path = url.path
                _ = await self.probeVersion(for: url, environment: environment, force: false)
                if self.probedRelease[path] != self.latestVersion,
                   self.probedIdentities[path] != self.readIdentity(url) {
                    _ = await self.probeVersion(for: url, environment: environment, force: false)
                }
            }
        }
    }

    func installedVersion(
        for executableURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> AmpVersion? {
        await probeVersion(for: executableURL, environment: environment, force: false)
    }

    private func probeVersion(
        for executableURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        force: Bool
    ) async -> AmpVersion? {
        let url = executableURL.standardizedFileURL
        let path = url.path
        let identity = readIdentity(url)
        let release = latestVersion
        if let flight = probeTasks[path], flight.identity == identity, flight.environment == environment {
            return await flight.task.value
        }
        if !force, let version = installedVersions[path],
           probedIdentities[path] == identity,
           probedRelease[path] == release,
           probedEnvironments[path] == environment {
            return version
        }

        let executor = executeCommand
        let generation = operationGeneration
        let token = UUID()
        let task = Task<AmpVersion?, Never> {
            do {
                let request = AmpCommandRequest(
                    executableURL: url,
                    arguments: ["version"],
                    environment: environment,
                    timeout: 5,
                    outputLimit: 64 * 1_024
                )
                let result = try await executor(request)
                guard result.exitCode == 0 else {
                    throw ControllerError.commandFailed(result)
                }
                guard let output = String(data: result.stdout, encoding: .utf8) else {
                    throw AmpVersionParseError.invalidUTF8
                }
                return try AmpVersionCommandOutput.parse(output)
            } catch {
                return nil
            }
        }
        probeTasks[path] = ProbeFlight(
            token: token,
            identity: identity,
            release: release,
            environment: environment,
            task: task
        )
        let version = await task.value
        guard operationGeneration == generation,
              probeTasks[path]?.token == token,
              registeredExecutableURLs.contains(where: { $0.path == path }) else {
            return version
        }
        probeTasks[path] = nil
        probedIdentities[path] = identity
        probedRelease[path] = release
        probedEnvironments[path] = environment
        if let version {
            installedVersions[path] = version
            probeErrors[path] = nil
            if case .failed = installStates[path],
               let latestVersion,
               version >= latestVersion {
                installStates[path] = nil
            }
        } else {
            probeErrors[path] = "Could not determine the installed Amp version."
        }
        return version
    }

    func installOutdatedExecutables(automatic: Bool = false) async {
        let generation = operationGeneration
        guard let latestVersion else { return }
        if let installBatchTask {
            return await installBatchTask.value
        }

        let urls: [URL]
        if automatic {
            urls = registeredExecutableURLs.filter { url in
                let environment = registeredEnvironments[url.path] ?? ProcessInfo.processInfo.environment
                let attempt = AutomaticAttempt(
                    version: latestVersion,
                    identity: readIdentity(url),
                    environment: environment,
                    count: 1,
                    consumed: false
                )
                if var previous = automaticAttempts[url.path], previous.matches(attempt) {
                    guard !previous.consumed, previous.count < 3 else { return false }
                    previous.count += 1
                    automaticAttempts[url.path] = previous
                } else {
                    automaticAttempts[url.path] = attempt
                }
                return true
            }
        } else {
            urls = registeredExecutableURLs
        }
        let reservedAutomaticAttempts = automatic ? automaticAttempts : [:]
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performInstallBatch(
                urls: urls,
                latestVersion: latestVersion,
                reservedAutomaticAttempts: reservedAutomaticAttempts
            )
        }
        installBatchTask = task
        await task.value
        if operationGeneration == generation, installBatchTask != nil { installBatchTask = nil }
    }

    private func performInstallBatch(
        urls: [URL],
        latestVersion: AmpVersion,
        reservedAutomaticAttempts: [String: AutomaticAttempt]
    ) async {
        let generation = operationGeneration
        var results: [AmpInstallBatch.Result] = []
        var discardedStaleResult = false
        for url in urls {
            guard operationGeneration == generation else { return }
            let path = url.path
            let environment = registeredEnvironments[path] ?? ProcessInfo.processInfo.environment
            let registrationGeneration = registrationGenerations[path, default: 0]
            guard let installed = await probeVersion(for: url, environment: environment, force: true) else {
                releaseAutomaticAttempt(path: path, reserved: reservedAutomaticAttempts[path])
                continue
            }
            guard installed < latestVersion else {
                consumeAutomaticAttempt(path: path, reserved: reservedAutomaticAttempts[path])
                continue
            }
            guard registrationGenerations[path] == registrationGeneration,
                  registeredEnvironments[path] == environment,
                  operationGeneration == generation else {
                releaseAutomaticAttempt(path: path, reserved: reservedAutomaticAttempts[path])
                discardedStaleResult = true
                continue
            }
            installStates[path] = .installing
            let finalState: AmpExecutableInstallState
            let outcome: AmpInstallBatch.Outcome
            do {
                let request = AmpCommandRequest(
                    executableURL: url,
                    arguments: ["update", "--porcelain"],
                    environment: environment,
                    timeout: 300,
                    outputLimit: 64 * 1_024
                )
                let commandResult = try await executeCommand(request)
                guard commandResult.exitCode == 0 else { throw ControllerError.commandFailed(commandResult) }
                guard let output = String(data: commandResult.stdout, encoding: .utf8) else {
                    throw AmpUpdateOutputParseError.invalidOutput("invalid UTF-8")
                }
                switch try AmpUpdateOutput.parse(output) {
                case let .updated(version):
                    if registeredExecutableURLs.contains(where: { $0.path == path }) {
                        installedVersions[path] = version
                    }
                    if registrationGenerations[path] == registrationGeneration,
                       registeredEnvironments[path] == environment {
                        probedIdentities[path] = readIdentity(url)
                        probedRelease[path] = latestVersion
                        probedEnvironments[path] = environment
                    }
                    finalState = .succeeded(version)
                    outcome = .updated(version)
                case .noUpdateNeeded:
                    finalState = .succeeded(installed)
                    outcome = .noUpdateNeeded
                }
                consumeAutomaticAttempt(path: path, reserved: reservedAutomaticAttempts[path])
            } catch {
                finalState = .failed(bounded(error.localizedDescription))
                outcome = .failed
            }
            if operationGeneration == generation,
               registrationGenerations[path] == registrationGeneration,
               registeredEnvironments[path] == environment {
                installStates[path] = finalState
                results.append(.init(path: path, state: finalState, outcome: outcome))
            } else {
                discardedStaleResult = true
            }
        }
        guard operationGeneration == generation,
              !results.isEmpty || !discardedStaleResult else { return }
        lastCompletedInstallBatch = AmpInstallBatch(completedAt: now(), results: results)
    }

    private func consumeAutomaticAttempt(path: String, reserved: AutomaticAttempt?) {
        guard let reserved, var current = automaticAttempts[path], current.matches(reserved) else { return }
        current.consumed = true
        automaticAttempts[path] = current
    }

    private func releaseAutomaticAttempt(path: String, reserved: AutomaticAttempt?) {
        guard let reserved, var current = automaticAttempts[path], current.matches(reserved) else { return }
        if current.count <= 1 {
            automaticAttempts[path] = nil
        } else {
            current.count -= 1
            automaticAttempts[path] = current
        }
    }

    func cancel() {
        operationGeneration &+= 1
        setAutomaticChecksEnabled(false)
        checkTask?.cancel()
        checkTask = nil
        checkToken = nil
        checkState = .idle
        probeReconciliationTask?.cancel()
        probeReconciliationTask = nil
        for flight in probeTasks.values { flight.task.cancel() }
        probeTasks.removeAll()
        installBatchTask?.cancel()
        installBatchTask = nil
    }

    private func bounded(_ message: String) -> String { String(message.prefix(512)) }

    private static func fileIdentity(_ url: URL) -> AmpExecutableIdentity {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        var info = stat()
        let inode = url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path, stat(path, &info) == 0 else { return nil }
            return "\(info.st_dev):\(info.st_ino)"
        }
        return AmpExecutableIdentity(
            modificationDate: values?.contentModificationDate,
            fileSize: values?.fileSize,
            fileIdentifier: inode
        )
    }
}

private struct ProbeFlight {
    let token: UUID
    let identity: AmpExecutableIdentity
    let release: AmpVersion?
    let environment: [String: String]
    let task: Task<AmpVersion?, Never>
}

private struct AutomaticAttempt {
    let version: AmpVersion
    let identity: AmpExecutableIdentity
    let environment: [String: String]
    var count: Int
    var consumed: Bool

    func matches(_ other: AutomaticAttempt) -> Bool {
        version == other.version && identity == other.identity && environment == other.environment
    }
}

private enum ControllerError: LocalizedError {
    case message(String)
    case commandFailed(AmpCommandResult)

    var errorDescription: String? {
        switch self {
        case let .message(message): return message
        case let .commandFailed(result):
            let stderr = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return stderr?.isEmpty == false ? stderr : "Amp command failed with exit code \(result.exitCode)."
        }
    }
}
