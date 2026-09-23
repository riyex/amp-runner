import XCTest
import AmpRunnerCore
@testable import AmpRunner

final class RunnerDirectoryManagementTests: XCTestCase {
    @MainActor
    func testLiveAddListRemoveUsesOriginalLaunchAfterProfileEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("amp-fixture")
        try """
        #!/bin/sh
        if [ "$1" = '--version' ]; then
          printf '0.0.1790103932-g7c3282\n'
          exit 0
        fi
        if [ "$1" = '--no-tui' ]; then
          exec /bin/sleep 30
        fi
        [ "$1" = runner ] && [ "$2" = dirs ] || exit 11
        operation="$3"
        shift 3
        if [ "$operation" != list ]; then path="$1"; shift; fi
        [ "$1" = '--runner-id' ] && [ "$2" = original-runner ] || exit 12
        case "$operation" in
          add) printf '%s\\n' "$path" > live-dirs; printf 'Added directory' ;;
          list) if [ -f live-dirs ]; then /bin/cat live-dirs; else printf 'No live directories'; fi ;;
          remove)
            if [ "$path" = /not-live ]; then printf 'Not a live addition' >&2; exit 23; fi
            /bin/rm -f live-dirs; printf 'Removed directory' ;;
        esac
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let coordinator = RunnerCoordinator(homeDirectoryPath: root.path)
        var profile = RunnerProfile(name: "Fixture", runnerID: "original-runner",
                                    workingDirectoryPath: root.path, ampExecutablePath: executable.path,
                                    confirmBeforeStart: false)
        try coordinator.persist(profile)
        coordinator.requestStart(profile)
        let supervisor = try XCTUnwrap(coordinator.supervisors[profile.id])
        defer { coordinator.onTerminate() }
        let deadline = Date().addingTimeInterval(5)
        while !supervisor.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(supervisor.isRunning)

        // Saved edits must not redirect management to a different process or cwd.
        profile.syncRunnerID("edited-runner")
        profile.ampExecutablePath = "/does-not-exist"
        profile.workingDirectoryPath = "/"
        try coordinator.persist(profile)
        let added = try await coordinator.runDirectoryCommand(.add("/selected/my repo"), profileID: profile.id)
        XCTAssertEqual(added, "Added directory")
        let listed = try await coordinator.runDirectoryCommand(.list, profileID: profile.id)
        XCTAssertEqual(listed, "/selected/my repo")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("live-dirs")), "/selected/my repo\n")

        do {
            _ = try await coordinator.runDirectoryCommand(.remove("/not-live"), profileID: profile.id)
            XCTFail("Expected Amp's rejection to reach the UI")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Not a live addition")
        }
        _ = try await coordinator.runDirectoryCommand(.remove("/selected/my repo"), profileID: profile.id)
        let empty = try await coordinator.runDirectoryCommand(.list, profileID: profile.id)
        XCTAssertEqual(empty, "No live directories")
        coordinator.stop(profile)
        let stopDeadline = Date().addingTimeInterval(5)
        while supervisor.isRunning && Date() < stopDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(supervisor.isRunning)
        XCTAssertThrowsError(try supervisor.directoryRequest(.list))
    }
}
