import Foundation
import XCTest
@testable import AmpRunnerCore

final class AmpIdleRestartPolicyTests: XCTestCase {
    private let old = AmpVersion("1.0")!
    private let new = AmpVersion("2.0")!

    func testOnlyOnlineOutdatedRunnerWithoutActiveThreadRestartsImmediately() {
        let eligible = UUID()
        let decisions = AmpIdleRestartPolicy.decide(
            snapshots: [snapshot(eligible, .online, active: false)],
            enabled: true,
            queuedProfileIDs: [eligible]
        )
        XCTAssertEqual(decisions, AmpIdleRestartDecision(restartNow: [eligible], keepQueued: [], removeFromQueue: []))
    }

    func testWorkingAndOnlineWithThreadStayQueued() {
        let working = UUID(), active = UUID()
        let decisions = AmpIdleRestartPolicy.decide(
            snapshots: [snapshot(working, .working), snapshot(active, .online, active: true)],
            enabled: true,
            queuedProfileIDs: [working, active]
        )
        XCTAssertEqual(decisions.keepQueued, [working, active])
        XCTAssertTrue(decisions.restartNow.isEmpty)
    }

    func testIneligibleStatesAndVersionsAreRemoved() {
        let stopped = UUID(), starting = UUID(), error = UUID(), equal = UUID(), unknown = UUID(), restarting = UUID()
        let snapshots = [
            snapshot(stopped, .stopped), snapshot(starting, .starting), snapshot(error, .error("x")),
            snapshot(equal, .online, running: new), snapshot(unknown, .online, running: nil),
            snapshot(restarting, .online, restartInFlight: true)
        ]
        let queued = Set(snapshots.map(\.profileID))

        let decisions = AmpIdleRestartPolicy.decide(snapshots: snapshots, enabled: true, queuedProfileIDs: queued)

        XCTAssertEqual(decisions.removeFromQueue, queued)
        XCTAssertTrue(decisions.restartNow.isEmpty)
        XCTAssertTrue(decisions.keepQueued.isEmpty)
    }

    func testDisabledPreferenceRemovesEverythingFromQueue() {
        let id = UUID()
        XCTAssertEqual(
            AmpIdleRestartPolicy.decide(snapshots: [snapshot(id, .online)], enabled: false, queuedProfileIDs: [id]).removeFromQueue,
            [id]
        )
    }

    private func snapshot(
        _ id: UUID, _ status: RunnerStatus, active: Bool = false,
        running: AmpVersion? = AmpVersion("1.0")!, installed: AmpVersion? = AmpVersion("2.0")!,
        restartInFlight: Bool = false
    ) -> AmpRunnerUpdateSnapshot {
        AmpRunnerUpdateSnapshot(
            profileID: id, status: status, hasActiveThread: active,
            runningVersion: running, installedVersion: installed, restartInFlight: restartInFlight
        )
    }
}
