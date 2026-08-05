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
