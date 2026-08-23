import Foundation

/// Locates an `amp` executable without invoking a shell.
///
/// Menu-bar apps are usually launched by LaunchServices or a login item, so their
/// inherited `PATH` may be much smaller than an interactive Terminal session. Detection
/// prefers installer-owned binaries, then checks inherited `PATH`, then falls back to
/// common absolute install paths.
public enum AmpExecutableDetector {
    private static let executableName = "amp"

    public static func detect(
        environmentPath: String?,
        ampHomePath: String? = nil,
        homeDirectoryPath: String,
        isExecutable: (String) -> Bool
    ) -> String? {
        candidatePaths(
            environmentPath: environmentPath,
            ampHomePath: ampHomePath,
            homeDirectoryPath: homeDirectoryPath
        )
        .first(where: isExecutable)
    }

    public static func candidatePaths(
        environmentPath: String?,
        ampHomePath: String? = nil,
        homeDirectoryPath: String
    ) -> [String] {
        let installerCandidates = RunnerProfile.preferredAmpExecutablePaths(
            homeDirectoryPath: homeDirectoryPath,
            ampHomePath: ampHomePath
        )

        let pathCandidates = (environmentPath ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .map { RunnerCommandBuilder.expand(path: $0, homeDirectoryPath: homeDirectoryPath) }
            .filter { $0.hasPrefix("/") }
            .map { directory in
                URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent(executableName)
                    .standardizedFileURL
                    .path
            }

        return deduplicated(
            installerCandidates + pathCandidates + RunnerProfile.commonAmpExecutablePaths(
                homeDirectoryPath: homeDirectoryPath,
                ampHomePath: ampHomePath
            )
        )
    }

    private static func deduplicated(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}

/// Resolves launch aliases to the physical Amp installation that owns updates.
public enum AmpExecutableResolver {
    private static let ampPathWrapperCommand = #"exec "${AMP_HOME:-$HOME/.amp}/bin/amp" "$@""#
    private static let maximumWrapperSize = 4_096

    public static func resolveUpdateExecutable(
        configuredURL: URL,
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> URL {
        let resolvedConfiguredURL = configuredURL.standardizedFileURL.resolvingSymlinksInPath()
        guard isAmpPathWrapper(at: resolvedConfiguredURL, fileManager: fileManager) else {
            return resolvedConfiguredURL
        }

        let ampHomePath: String
        if let configuredAmpHome = environment["AMP_HOME"], !configuredAmpHome.isEmpty {
            guard configuredAmpHome.hasPrefix("/") else { return resolvedConfiguredURL }
            ampHomePath = configuredAmpHome
        } else {
            guard let homePath = environment["HOME"], homePath.hasPrefix("/") else {
                return resolvedConfiguredURL
            }
            ampHomePath = "\(homePath)/.amp"
        }
        let targetURL = URL(fileURLWithPath: ampHomePath, isDirectory: true)
            .appendingPathComponent("bin/amp")
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard fileManager.isExecutableFile(atPath: targetURL.path),
              (try? targetURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return resolvedConfiguredURL
        }
        return targetURL
    }

    private static func isAmpPathWrapper(at url: URL, fileManager: FileManager) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize <= maximumWrapperSize,
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        let commands = contents
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return commands == [ampPathWrapperCommand]
    }
}
