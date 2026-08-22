import Foundation

public struct AmpRunnerUpdateSnapshot: Equatable, Sendable {
    public let profileID: UUID
    public let status: RunnerStatus
    public let hasActiveThread: Bool
    public let runningVersion: AmpVersion?
    public let installedVersion: AmpVersion?
    public let restartInFlight: Bool

    public init(
        profileID: UUID, status: RunnerStatus, hasActiveThread: Bool,
        runningVersion: AmpVersion?, installedVersion: AmpVersion?, restartInFlight: Bool
    ) {
        self.profileID = profileID
        self.status = status
        self.hasActiveThread = hasActiveThread
        self.runningVersion = runningVersion
        self.installedVersion = installedVersion
        self.restartInFlight = restartInFlight
    }
}

public struct AmpIdleRestartDecision: Equatable, Sendable {
    public let restartNow: Set<UUID>
    public let keepQueued: Set<UUID>
    public let removeFromQueue: Set<UUID>

    public init(restartNow: Set<UUID>, keepQueued: Set<UUID>, removeFromQueue: Set<UUID>) {
        self.restartNow = restartNow
        self.keepQueued = keepQueued
        self.removeFromQueue = removeFromQueue
    }
}

public enum AmpIdleRestartPolicy {
    public static func decide(
        snapshots: [AmpRunnerUpdateSnapshot],
        enabled: Bool,
        queuedProfileIDs: Set<UUID>
    ) -> AmpIdleRestartDecision {
        guard enabled else {
            return AmpIdleRestartDecision(restartNow: [], keepQueued: [], removeFromQueue: queuedProfileIDs)
        }

        var restartNow = Set<UUID>()
        var keepQueued = Set<UUID>()
        var removeFromQueue = queuedProfileIDs
        for snapshot in snapshots where queuedProfileIDs.contains(snapshot.profileID) {
            guard !snapshot.restartInFlight,
                  let running = snapshot.runningVersion,
                  let installed = snapshot.installedVersion,
                  running < installed else { continue }

            switch snapshot.status {
            case .online where !snapshot.hasActiveThread:
                restartNow.insert(snapshot.profileID)
                removeFromQueue.remove(snapshot.profileID)
            case .online, .working:
                keepQueued.insert(snapshot.profileID)
                removeFromQueue.remove(snapshot.profileID)
            case .stopped, .starting, .error:
                break
            }
        }
        return AmpIdleRestartDecision(
            restartNow: restartNow,
            keepQueued: keepQueued,
            removeFromQueue: removeFromQueue
        )
    }
}
