import XCTest
@testable import AmpRunnerCore

final class AmpUpdateNotificationPolicyTests: XCTestCase {
    private let v2 = AmpVersion("2.0")!

    func testAggregatesManyProfilesAndExecutablesIntoOneUpdateEventPerVersion() {
        let input = AmpUpdateNotificationInput(
            latestVersion: v2, outdatedExecutableCount: 2, affectedRunnerCount: 5,
            restartRequiredRunnerCount: 0, idleRunnerCount: 0, workingRunnerCount: 0,
            automaticallyRestartsWhenIdle: false
        )
        let result = AmpUpdateNotificationPolicy.evaluate(input: input, notificationsEnabled: true, ledger: .init())

        XCTAssertEqual(result.events, [.updateAvailable(version: v2, executableCount: 2, runnerCount: 5)])
        XCTAssertEqual(result.ledger.lastUpdateAvailableVersion, v2)
    }

    func testSamePersistedLedgerSuppressesUpdateAfterRelaunch() {
        let input = AmpUpdateNotificationInput(
            latestVersion: v2, outdatedExecutableCount: 1, affectedRunnerCount: 3,
            restartRequiredRunnerCount: 0, idleRunnerCount: 0, workingRunnerCount: 0,
            automaticallyRestartsWhenIdle: false
        )
        let ledger = AmpUpdateNotificationLedger(lastUpdateAvailableVersion: v2)
        XCTAssertTrue(AmpUpdateNotificationPolicy.evaluate(input: input, notificationsEnabled: true, ledger: ledger).events.isEmpty)
    }

    func testRestartEventIsAggregatedPerInstalledVersionAndUsesAutomaticWording() {
        let input = AmpUpdateNotificationInput(
            installedBatchVersion: v2, outdatedExecutableCount: 0, affectedRunnerCount: 4,
            restartRequiredRunnerCount: 4, idleRunnerCount: 1, workingRunnerCount: 2,
            automaticallyRestartsWhenIdle: true
        )
        let result = AmpUpdateNotificationPolicy.evaluate(input: input, notificationsEnabled: true, ledger: .init())

        XCTAssertEqual(result.events, [.restartRequired(
            version: v2, runnerCount: 4, idleCount: 1, workingCount: 2, automaticallyRestartsWhenIdle: true
        )])
        XCTAssertEqual(result.ledger.lastRestartRequiredVersion, v2)
    }

    func testDisabledNotificationsProduceNoEventsAndDoNotAdvanceLedger() {
        let input = AmpUpdateNotificationInput(
            latestVersion: v2, installedBatchVersion: v2, outdatedExecutableCount: 1,
            affectedRunnerCount: 2, restartRequiredRunnerCount: 2, idleRunnerCount: 1,
            workingRunnerCount: 1, automaticallyRestartsWhenIdle: false
        )
        XCTAssertEqual(
            AmpUpdateNotificationPolicy.evaluate(input: input, notificationsEnabled: false, ledger: .init()),
            AmpUpdateNotificationResult(events: [], ledger: .init())
        )
    }
}
