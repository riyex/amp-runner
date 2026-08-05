import Foundation

/// The Amp command for a profile, after tilde expansion and path normalisation. This is
/// what the confirmation sheet displays and what the native monitor helper launches.
public struct ResolvedRunnerCommand: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let workingDirectoryURL: URL

    public init(executableURL: URL, arguments: [String], workingDirectoryURL: URL) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectoryURL = workingDirectoryURL
    }
}

public enum RunnerCommandBuilderError: Error, Equatable, CustomStringConvertible {
    case emptyExecutablePath
    case emptyWorkingDirectory
    case relativeExecutablePath(String)
    case relativeWorkingDirectory(String)

    public var description: String {
        switch self {
        case .emptyExecutablePath:
            return "No Amp executable path is configured for this profile."
        case .emptyWorkingDirectory:
            return "No working directory is configured for this profile."
        case .relativeExecutablePath(let path):
            return "Amp executable path must be absolute, got \(path)."
        case .relativeWorkingDirectory(let path):
            return "Working directory must be absolute, got \(path)."
        }
    }
}

/// Pure translation of a `RunnerProfile` into the Amp command the monitor helper runs.
///
/// Deliberately free of any process/file-system side effects so it can be unit tested
/// and so the confirmation sheet and process launcher share one resolved command.
public enum RunnerCommandBuilder {

    /// Expands a leading `~` (or `~/…`) against the given home directory and
    /// standardises the result. Paths that do not begin with `~` are returned
    /// standardised but otherwise untouched.
    public static func expand(path: String, homeDirectoryPath: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        var expanded = trimmed
        if trimmed == "~" {
            expanded = homeDirectoryPath
        } else if trimmed.hasPrefix("~/") {
            let suffix = String(trimmed.dropFirst(2))
            expanded = URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
                .appendingPathComponent(suffix)
                .path
        }

        guard expanded.hasPrefix("/") else { return expanded }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    public static func resolve(
        profile: RunnerProfile,
        homeDirectoryPath: String
    ) throws -> ResolvedRunnerCommand {
        let executablePath = expand(
            path: profile.ampExecutablePath,
            homeDirectoryPath: homeDirectoryPath
        )
        guard !executablePath.isEmpty else {
            throw RunnerCommandBuilderError.emptyExecutablePath
        }
        guard executablePath.hasPrefix("/") else {
            throw RunnerCommandBuilderError.relativeExecutablePath(executablePath)
        }

        let workingDirectoryPath = expand(
            path: profile.workingDirectoryPath,
            homeDirectoryPath: homeDirectoryPath
        )
        guard !workingDirectoryPath.isEmpty else {
            throw RunnerCommandBuilderError.emptyWorkingDirectory
        }
        guard workingDirectoryPath.hasPrefix("/") else {
            throw RunnerCommandBuilderError.relativeWorkingDirectory(workingDirectoryPath)
        }

        let arguments = profile.arguments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return ResolvedRunnerCommand(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            workingDirectoryURL: URL(fileURLWithPath: workingDirectoryPath, isDirectory: true)
        )
    }

    /// A copy-pasteable terminal equivalent for the resolved command, e.g.
    /// `cd /Users/me/src/sample-project && /opt/homebrew/bin/amp --no-tui --runner-id sample-runner`
    public static func commandPreview(for command: ResolvedRunnerCommand) -> String {
        let parts = [command.executableURL.path] + command.arguments
        let rendered = parts.map(shellQuote).joined(separator: " ")
        return "cd \(shellQuote(command.workingDirectoryURL.path)) && \(rendered)"
    }

    /// Convenience overload used by the live preview in the profile editor. Returns the
    /// validation failure text instead of throwing so the editor can render it inline.
    public static func commandPreview(
        for profile: RunnerProfile,
        homeDirectoryPath: String
    ) -> String {
        do {
            return commandPreview(for: try resolve(profile: profile, homeDirectoryPath: homeDirectoryPath))
        } catch let error as RunnerCommandBuilderError {
            return error.description
        } catch {
            return "\(error)"
        }
    }

    /// POSIX single-quote quoting. Only quotes when necessary so the common case stays
    /// readable.
    public static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-./:=@+,")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
