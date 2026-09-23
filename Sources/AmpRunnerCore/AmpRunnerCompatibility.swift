import Foundation

public enum AmpRunnerCompatibility {
    /// Conservative known-good build verified on September 22, 2026, not a claim
    /// about the first release containing every runner feature.
    public static let minimumVersion = AmpVersion("0.0.1790103932-g7c3282")!

    public enum Error: Swift.Error, LocalizedError {
        case tooOld(AmpVersion)

        public var errorDescription: String? {
            switch self {
            case .tooOld(let installed):
                return "Installed Amp \(installed) is too old. Amp Runner requires \(minimumVersion) or later for multi-directory runners, cloud environment variables, and self-updates."
            }
        }
    }

    public static func validate(_ output: String) throws -> AmpVersion {
        let installed = try AmpVersionCommandOutput.parse(output)
        guard installed >= minimumVersion else { throw Error.tooOld(installed) }
        return installed
    }
}
