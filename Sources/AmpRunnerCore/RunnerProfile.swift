import Foundation

/// A single, explicitly user-configured Amp runner.
///
/// A profile is the unit of supervision: one profile maps to exactly one working
/// directory, which is also how Amp itself identifies a runner (host + working
/// directory). Nothing secret is ever stored here — only non-secret configuration
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

    /// `--no-tui --runner-id <id> --remote-control-terminal`
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
            return "Another profile already uses the working directory \(path). Each runner needs its own isolated directory."
        case .duplicateRunnerID(let id):
            return "Another profile already uses the runner ID \(id)."
        }
    }
}

extension RunnerProfile {
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
