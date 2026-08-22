import XCTest
@testable import AmpRunnerCore

final class AmpProfileUpdateStateTests: XCTestCase {
    private let old = AmpVersion("1.0")!
    private let installed = AmpVersion("2.0")!
    private let latest = AmpVersion("3.0")!

    func testActiveInstallationHasHighestPrecedence() {
        XCTAssertEqual(derive(running: old, installing: true, failure: "failed"), .installing(installed: installed))
    }

    func testRestartRequiredOutranksPriorFailureAndAvailableUpdate() {
        XCTAssertEqual(derive(running: old, failure: "failed"), .restartRequired(running: old, installed: installed))
    }

    func testFailureOutranksAvailableUpdateWhenRestartIsNotRequired() {
        XCTAssertEqual(derive(running: installed, failure: "failed"), .updateFailed(installed: installed, message: "failed"))
    }

    func testLatestNewerThanInstalledIsAvailableOtherwiseUpToDate() {
        XCTAssertEqual(derive(running: installed), .updateAvailable(installed: installed, latest: latest))
        XCTAssertEqual(derive(running: installed, latest: installed), .upToDate(installed))
    }

    func testStoppedProfileUsesInstalledVersionAndNeverRequiresRestart() {
        XCTAssertEqual(derive(status: .stopped, running: old), .updateAvailable(installed: installed, latest: latest))
    }

    func testUnknownVersionsDoNotGuess() {
        XCTAssertEqual(derive(installed: nil), .versionUnknown)
        XCTAssertEqual(derive(status: .online, running: nil), .versionUnknown)
        XCTAssertEqual(derive(status: .online, running: nil, failure: "failed"), .versionUnknown)
        XCTAssertEqual(derive(status: .online, running: nil, latest: installed), .versionUnknown)
        XCTAssertEqual(derive(status: .stopped, latest: nil), .upToDate(installed))
    }

    private func derive(
        status: RunnerStatus = .online,
        running: AmpVersion? = nil,
        installed: AmpVersion? = AmpVersion("2.0")!,
        latest: AmpVersion? = AmpVersion("3.0")!,
        installing: Bool = false,
        failure: String? = nil
    ) -> AmpProfileUpdateState {
        AmpProfileUpdateState.derive(
            status: status,
            runningVersion: running,
            installedVersion: installed,
            latestVersion: latest,
            installationInProgress: installing,
            installationFailure: failure
        )
    }
}
