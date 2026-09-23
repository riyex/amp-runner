import Foundation

/// A single, explicitly user-configured Amp runner.
///
/// A profile is the unit of supervision: one process with a stable launch directory
/// can serve multiple explicit directories and discovery roots. Nothing secret is
/// ever stored here — only non-secret configuration
/// the user typed or picked themselves.
public struct RunnerProfile: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var runnerID: String
    public var workingDirectoryPath: String
    public var ampExecutablePath: String
    public var arguments: [String]
    public var autoStart: Bool
    /// Defaults to `true`: the confirmation sheet showing the resolved launch settings
    /// is opt-out, never opt-in.
    public var confirmBeforeStart: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        runnerID: String,
        workingDirectoryPath: String,
        ampExecutablePath: String,
        arguments: [String]? = nil,
        autoStart: Bool = false,
        confirmBeforeStart: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.runnerID = runnerID
        self.workingDirectoryPath = workingDirectoryPath
        self.ampExecutablePath = ampExecutablePath
        self.arguments = arguments ?? RunnerProfile.defaultArguments(runnerID: runnerID)
        self.autoStart = autoStart
        self.confirmBeforeStart = confirmBeforeStart
        // Truncated to whole seconds so a profile survives a JSON round trip
        // unchanged — the store encodes dates as ISO-8601, which has no sub-second
        // component, and profiles are compared by value.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
    }

    /// `--no-tui --runner-id <id> --remote-control-terminal --discover-dirs --amp-env`
    ///
    /// These are treated as an opaque, user-editable argument string list; the app
    /// never rewrites them behind the user's back.
    public static func defaultArguments(runnerID: String) -> [String] {
        var args = ["--no-tui"]
        let trimmed = runnerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            args.append("--runner-id")
            args.append(trimmed)
        }
        args.append("--remote-control-terminal")
        args.append("--discover-dirs")
        args.append("--amp-env")
        return args
    }

    /// Installer-owned `amp` locations preferred over PATH-facing wrappers.
    public static func preferredAmpExecutablePaths(
        homeDirectoryPath: String,
        ampHomePath: String? = nil
    ) -> [String] {
        let defaultAmpHomePath = "~/.amp"
        let ampHomeCandidates = [ampHomePath, defaultAmpHomePath]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return deduplicated(
            ampHomeCandidates.map {
                executablePath(inAmpHome: $0, homeDirectoryPath: homeDirectoryPath)
            }
        )
    }

    /// Well-known install locations checked when auto-detecting the `amp` binary.
    public static func commonAmpExecutablePaths(
        homeDirectoryPath: String,
        ampHomePath: String? = nil
    ) -> [String] {
        deduplicated(
            preferredAmpExecutablePaths(
                homeDirectoryPath: homeDirectoryPath,
                ampHomePath: ampHomePath
            ) + [
                "/opt/homebrew/bin/amp",
                "/usr/local/bin/amp",
                "~/.local/bin/amp",
                "~/bin/amp",
                "~/.bin/amp"
            ]
            .map { RunnerCommandBuilder.expand(path: $0, homeDirectoryPath: homeDirectoryPath) }
        )
    }

    private static func executablePath(inAmpHome ampHomePath: String, homeDirectoryPath: String) -> String {
        let expandedAmpHomePath = RunnerCommandBuilder.expand(
            path: ampHomePath,
            homeDirectoryPath: homeDirectoryPath
        )
        return URL(fileURLWithPath: expandedAmpHomePath, isDirectory: true)
            .appendingPathComponent("bin/amp")
            .standardizedFileURL
            .path
    }

    private static func deduplicated(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}

// MARK: - Validation

public enum RunnerProfileValidationError: Error, Equatable, CustomStringConvertible {
    case emptyName
    case emptyRunnerID
    case emptyWorkingDirectory
    case emptyExecutablePath
    case duplicateWorkingDirectory(String)
    case duplicateRunnerID(String)

    public var description: String {
        switch self {
        case .emptyName:
            return "Profile name must not be empty."
        case .emptyRunnerID:
            return "Runner ID must not be empty."
        case .emptyWorkingDirectory:
            return "Working directory must be chosen explicitly."
        case .emptyExecutablePath:
            return "Amp executable path must not be empty."
        case .duplicateWorkingDirectory(let path):
            return "Another profile already uses the launch directory \(path). Each runner needs its own launch directory for persisted live additions."
        case .duplicateRunnerID(let id):
            return "Another profile already uses the runner ID \(id)."
        }
    }
}

extension RunnerProfile {
    /// Whether a bare `--discover-dirs` asks Amp to discover from the profile's
    /// working directory.
    public var discoversWorkingDirectory: Bool {
        get { RunnerManagedArguments(arguments).containsBareDiscoverDirectories }
        set {
            arguments = RunnerManagedArguments(arguments).settingBareDiscoverDirectories(newValue)
        }
    }

    /// Explicit discovery roots from either `--discover-dirs=<path>` or
    /// `--discover-dirs <path>`. Setters canonicalise these to the equals form.
    public var discoveryDirectoryPaths: [String] {
        get { RunnerManagedArguments(arguments).discoveryDirectoryPaths }
        set {
            arguments = RunnerManagedArguments(arguments).settingDiscoveryDirectoryPaths(newValue)
        }
    }

    /// Explicit served roots from either `--dir <path>` or `--dir=<path>`.
    public var servedDirectoryPaths: [String] {
        get { RunnerManagedArguments(arguments).servedDirectoryPaths }
        set {
            arguments = RunnerManagedArguments(arguments).settingServedDirectoryPaths(newValue)
        }
    }

    public var usesAmpEnvironment: Bool {
        get { arguments.contains("--amp-env") }
        set { arguments = RunnerManagedArguments.settingFlag("--amp-env", enabled: newValue, in: arguments) }
    }

    /// Amp serves the working directory unless `--no-serve-cwd` is present.
    public var servesWorkingDirectory: Bool {
        get { !arguments.contains("--no-serve-cwd") }
        set { arguments = RunnerManagedArguments.settingFlag("--no-serve-cwd", enabled: !newValue, in: arguments) }
    }

    /// Updates the persisted ID and its command-line flag while retaining all
    /// unrelated/custom arguments.
    public mutating func syncRunnerID(_ newRunnerID: String) {
        runnerID = newRunnerID
        arguments = RunnerManagedArguments(arguments).settingRunnerID(newRunnerID)
    }

    /// Field-level validation that does not depend on other profiles.
    public func validateFields() throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RunnerProfileValidationError.emptyName
        }
        if runnerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RunnerProfileValidationError.emptyRunnerID
        }
        if workingDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RunnerProfileValidationError.emptyWorkingDirectory
        }
        if ampExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RunnerProfileValidationError.emptyExecutablePath
        }
    }
}

private struct RunnerManagedArguments {
    let arguments: [String]

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    var containsBareDiscoverDirectories: Bool {
        parsed.contains { if case .bareDiscover = $0.kind { return true }; return false }
    }

    var discoveryDirectoryPaths: [String] {
        parsed.compactMap { if case .discoverPath(let path) = $0.kind { return path }; return nil }
    }

    var servedDirectoryPaths: [String] {
        parsed.compactMap { if case .servedPath(let path) = $0.kind { return path }; return nil }
    }

    func settingBareDiscoverDirectories(_ enabled: Bool) -> [String] {
        replacing({ if case .bareDiscover = $0 { return true }; return false }, with: enabled ? ["--discover-dirs"] : [])
    }

    func settingDiscoveryDirectoryPaths(_ paths: [String]) -> [String] {
        replacing(
            { if case .discoverPath = $0 { return true }; return false },
            with: paths.map { "--discover-dirs=\($0)" }
        )
    }

    func settingServedDirectoryPaths(_ paths: [String]) -> [String] {
        replacing(
            { if case .servedPath = $0 { return true }; return false },
            with: paths.flatMap { ["--dir", $0] }
        )
    }

    func settingRunnerID(_ runnerID: String) -> [String] {
        let trimmed = runnerID.trimmingCharacters(in: .whitespacesAndNewlines)
        return replacing(
            { if case .runnerID = $0 { return true }; return false },
            with: trimmed.isEmpty ? [] : ["--runner-id", trimmed]
        )
    }

    static func settingFlag(_ flag: String, enabled: Bool, in arguments: [String]) -> [String] {
        var result = arguments.filter { $0 != flag }
        if enabled { result.append(flag) }
        return result
    }

    private enum Kind {
        case bareDiscover
        case discoverPath(String)
        case servedPath(String)
        case runnerID(String)
    }

    private struct Parsed {
        let range: Range<Int>
        let kind: Kind
    }

    private var parsed: [Parsed] {
        var result: [Parsed] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--discover-dirs" {
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
                    result.append(Parsed(range: index..<(index + 2), kind: .discoverPath(arguments[index + 1])))
                    index += 2
                } else {
                    result.append(Parsed(range: index..<(index + 1), kind: .bareDiscover))
                    index += 1
                }
            } else if argument.hasPrefix("--discover-dirs=") {
                result.append(Parsed(range: index..<(index + 1), kind: .discoverPath(String(argument.dropFirst("--discover-dirs=".count)))))
                index += 1
            } else if argument == "--dir",
                      index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("-") {
                result.append(Parsed(range: index..<(index + 2), kind: .servedPath(arguments[index + 1])))
                index += 2
            } else if argument.hasPrefix("--dir=") {
                result.append(Parsed(range: index..<(index + 1), kind: .servedPath(String(argument.dropFirst("--dir=".count)))))
                index += 1
            } else if argument == "--runner-id",
                      index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("-") {
                result.append(Parsed(range: index..<(index + 2), kind: .runnerID(arguments[index + 1])))
                index += 2
            } else if argument.hasPrefix("--runner-id=") {
                result.append(Parsed(range: index..<(index + 1), kind: .runnerID(String(argument.dropFirst("--runner-id=".count)))))
                index += 1
            } else {
                index += 1
            }
        }
        return result
    }

    private func replacing(_ matches: (Kind) -> Bool, with replacement: [String]) -> [String] {
        let ranges = parsed.filter { matches($0.kind) }.map(\.range)
        guard let insertionIndex = ranges.first?.lowerBound else {
            return arguments + replacement
        }
        let removed = Set(ranges.flatMap { $0 })
        var result = arguments.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        let adjustedIndex = arguments[..<insertionIndex].indices.filter { !removed.contains($0) }.count
        result.insert(contentsOf: replacement, at: adjustedIndex)
        return result
    }
}
