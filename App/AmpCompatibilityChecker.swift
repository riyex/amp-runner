import Foundation
import AmpRunnerCore

/// A local minimum-version check, never a latest-release check or an installer.
enum AmpCompatibilityChecker {
    static func check(command: ResolvedRunnerCommand, environment: [String: String]) async throws -> AmpVersion {
        let result: AmpCommandResult
        do {
            result = try await AmpCommandExecutor().execute(AmpCommandRequest(
                executableURL: command.executableURL, arguments: ["--version"],
                environment: environment, timeout: 10, outputLimit: 4_096,
                workingDirectoryURL: command.workingDirectoryURL
            ))
        } catch AmpCommandExecutor.Error.timedOut {
            throw NSError(domain: "AmpRunner.Compatibility", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not verify Amp: --version did not respond within 10 seconds."
            ])
        }
        guard result.exitCode == 0 else {
            throw NSError(domain: "AmpRunner.Compatibility", code: Int(result.exitCode), userInfo: [
                NSLocalizedDescriptionKey: "Could not verify Amp: --version exited with status \(result.exitCode)."
            ])
        }
        guard let output = String(data: result.stdout, encoding: .utf8) else {
            throw AmpVersionParseError.invalidUTF8
        }
        return try AmpRunnerCompatibility.validate(output)
    }
}
