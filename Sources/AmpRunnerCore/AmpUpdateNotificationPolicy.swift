public struct AmpUpdateNotificationInput: Equatable, Sendable {
    public let latestVersion: AmpVersion?
    public let installedBatchVersion: AmpVersion?
    public let installedBatchIdentity: String?
    public let outdatedExecutableCount: Int
    public let affectedRunnerCount: Int
    public let restartRequiredRunnerCount: Int
    public let idleRunnerCount: Int
    public let workingRunnerCount: Int
    public let automaticallyRestartsWhenIdle: Bool

    public init(
        latestVersion: AmpVersion? = nil,
        installedBatchVersion: AmpVersion? = nil,
        installedBatchIdentity: String? = nil,
        outdatedExecutableCount: Int,
        affectedRunnerCount: Int,
        restartRequiredRunnerCount: Int,
        idleRunnerCount: Int,
        workingRunnerCount: Int,
        automaticallyRestartsWhenIdle: Bool
    ) {
        self.latestVersion = latestVersion
        self.installedBatchVersion = installedBatchVersion
        self.installedBatchIdentity = installedBatchIdentity
        self.outdatedExecutableCount = outdatedExecutableCount
        self.affectedRunnerCount = affectedRunnerCount
        self.restartRequiredRunnerCount = restartRequiredRunnerCount
        self.idleRunnerCount = idleRunnerCount
        self.workingRunnerCount = workingRunnerCount
        self.automaticallyRestartsWhenIdle = automaticallyRestartsWhenIdle
    }
}

public struct AmpUpdateNotificationLedger: Equatable, Sendable {
    public var lastUpdateAvailableVersion: AmpVersion?
    public var lastRestartRequiredVersion: AmpVersion?
    public var lastRestartRequiredBatchIdentity: String?

    public init(
        lastUpdateAvailableVersion: AmpVersion? = nil,
        lastRestartRequiredVersion: AmpVersion? = nil,
        lastRestartRequiredBatchIdentity: String? = nil
    ) {
        self.lastUpdateAvailableVersion = lastUpdateAvailableVersion
        self.lastRestartRequiredVersion = lastRestartRequiredVersion
        self.lastRestartRequiredBatchIdentity = lastRestartRequiredBatchIdentity
    }
}

public enum AmpUpdateNotificationEvent: Equatable, Sendable {
    case updateAvailable(version: AmpVersion, executableCount: Int, runnerCount: Int)
    case restartRequired(
        version: AmpVersion,
        runnerCount: Int,
        idleCount: Int,
        workingCount: Int,
        automaticallyRestartsWhenIdle: Bool
    )
}

public struct AmpUpdateNotificationResult: Equatable, Sendable {
    public let events: [AmpUpdateNotificationEvent]
    public let ledger: AmpUpdateNotificationLedger

    public init(events: [AmpUpdateNotificationEvent], ledger: AmpUpdateNotificationLedger) {
        self.events = events
        self.ledger = ledger
    }
}

public enum AmpUpdateNotificationPolicy {
    public static func evaluate(
        input: AmpUpdateNotificationInput,
        notificationsEnabled: Bool,
        ledger: AmpUpdateNotificationLedger
    ) -> AmpUpdateNotificationResult {
        guard notificationsEnabled else { return AmpUpdateNotificationResult(events: [], ledger: ledger) }

        var events = [AmpUpdateNotificationEvent]()
        var updatedLedger = ledger
        if let latest = input.latestVersion,
           input.outdatedExecutableCount > 0,
           ledger.lastUpdateAvailableVersion.map({ latest > $0 }) ?? true {
            events.append(.updateAvailable(
                version: latest,
                executableCount: input.outdatedExecutableCount,
                runnerCount: input.affectedRunnerCount
            ))
            updatedLedger.lastUpdateAvailableVersion = latest
        }
        if let installed = input.installedBatchVersion,
           input.restartRequiredRunnerCount > 0,
           input.installedBatchIdentity != ledger.lastRestartRequiredBatchIdentity {
            events.append(.restartRequired(
                version: installed,
                runnerCount: input.restartRequiredRunnerCount,
                idleCount: input.idleRunnerCount,
                workingCount: input.workingRunnerCount,
                automaticallyRestartsWhenIdle: input.automaticallyRestartsWhenIdle
            ))
            updatedLedger.lastRestartRequiredVersion = installed
            updatedLedger.lastRestartRequiredBatchIdentity = input.installedBatchIdentity
        }
        return AmpUpdateNotificationResult(events: events, ledger: updatedLedger)
    }
}
