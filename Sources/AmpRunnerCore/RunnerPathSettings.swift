import Foundation

public struct RunnerPathSettings: Codable, Equatable, Sendable {
    public var userDirectories: [String]

    public init(userDirectories: [String] = []) {
        self.userDirectories = userDirectories
    }
}

public enum RunnerPathEntryStatus: Equatable, Sendable {
    case valid(String)
    case missing(String)
    case invalid(String)
}

public struct ResolvedRunnerPath: Equatable, Sendable {
    public let directories: [String]
    public let path: String

    public init(directories: [String]) {
        self.directories = directories
        self.path = directories.joined(separator: ":")
    }
}

/// Resolves runner PATH entries without invoking a shell or inspecting process state.
public enum RunnerPathResolver {
    private static let conventionalDirectories = [
        "~/.amp/bin",
        "~/.local/bin",
        "~/bin",
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    public static func status(
        of directory: String,
        homeDirectoryPath: String,
        directoryExists: (String) -> Bool
    ) -> RunnerPathEntryStatus {
        guard !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid("Path cannot be empty.")
        }
        guard !directory.contains(":") else {
            return .invalid("Path cannot contain : because it separates PATH entries.")
        }
        guard let normalized = normalizedPath(for: directory, homeDirectoryPath: homeDirectoryPath) else {
            return .invalid("Enter an absolute directory, ~, or a path beginning with ~/.")
        }

        return directoryExists(normalized) ? .valid(normalized) : .missing(normalized)
    }

    public static func resolve(
        settings: RunnerPathSettings,
        inheritedPath: String?,
        homeDirectoryPath: String,
        directoryExists: (String) -> Bool
    ) -> ResolvedRunnerPath {
        let userDirectories = settings.userDirectories.compactMap { directory in
            switch status(
                of: directory,
                homeDirectoryPath: homeDirectoryPath,
                directoryExists: directoryExists
            ) {
            case .valid(let path), .missing(let path):
                return path
            case .invalid:
                return nil
            }
        }

        let inheritedDirectories = (inheritedPath ?? "")
            .split(separator: ":", omittingEmptySubsequences: false)
            .compactMap { normalizedPath(for: String($0), homeDirectoryPath: homeDirectoryPath) }

        let inferredDirectories = conventionalDirectories.compactMap { directory -> String? in
            guard case .valid(let path) = status(
                of: directory,
                homeDirectoryPath: homeDirectoryPath,
                directoryExists: directoryExists
            ) else {
                return nil
            }
            return path
        }

        return ResolvedRunnerPath(
            directories: stableDeduplicated(userDirectories + inheritedDirectories + inferredDirectories)
        )
    }

    private static func normalizedPath(for directory: String, homeDirectoryPath: String) -> String? {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expanded: String
        if trimmed == "~" {
            expanded = homeDirectoryPath
        } else if trimmed.hasPrefix("~/") {
            expanded = URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
                .appendingPathComponent(String(trimmed.dropFirst(2)))
                .path
        } else {
            expanded = trimmed
        }

        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }

    private static func stableDeduplicated(_ directories: [String]) -> [String] {
        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted }
    }
}
