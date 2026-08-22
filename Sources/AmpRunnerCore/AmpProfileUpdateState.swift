public enum AmpProfileUpdateState: Equatable, Sendable {
    case versionUnknown
    case upToDate(AmpVersion)
    case updateAvailable(installed: AmpVersion, latest: AmpVersion)
    case installing(installed: AmpVersion?)
    case restartRequired(running: AmpVersion, installed: AmpVersion)
    case updateFailed(installed: AmpVersion?, message: String)

    public static func derive(
        status: RunnerStatus,
        runningVersion: AmpVersion?,
        installedVersion: AmpVersion?,
        latestVersion: AmpVersion?,
        installationInProgress: Bool,
        installationFailure: String?
    ) -> Self {
        if installationInProgress { return .installing(installed: installedVersion) }
        guard let installedVersion else { return .versionUnknown }
        if status.isRunning, let runningVersion, runningVersion < installedVersion {
            return .restartRequired(running: runningVersion, installed: installedVersion)
        }
        if let installationFailure {
            return .updateFailed(installed: installedVersion, message: installationFailure)
        }
        if let latestVersion, installedVersion < latestVersion {
            return .updateAvailable(installed: installedVersion, latest: latestVersion)
        }
        return .upToDate(installedVersion)
    }
}
