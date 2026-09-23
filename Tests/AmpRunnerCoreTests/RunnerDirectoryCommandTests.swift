import XCTest
@testable import AmpRunnerCore

final class RunnerDirectoryCommandTests: XCTestCase {
    func testTargetsLaunchedIDAndSettingsWithoutPassingStartupFlags() throws {
        let launch = ResolvedRunnerCommand(
            executableURL: URL(fileURLWithPath: "/tools/amp"),
            arguments: ["--no-tui", "--runner-id=actual-runner", "--discover-dirs", "--amp-env", "--settings-file", "/config/custom settings.json"],
            workingDirectoryURL: URL(fileURLWithPath: "/projects")
        )
        let command = try RunnerDirectoryCommand.resolve(.add("/other/my repo"), launch: launch)
        XCTAssertEqual(command.arguments, ["runner", "dirs", "add", "/other/my repo", "--runner-id", "actual-runner", "--settings-file", "/config/custom settings.json"])
        XCTAssertEqual(command.executableURL.path, "/tools/amp")
        XCTAssertEqual(command.workingDirectoryURL.path, "/projects")
    }

    func testListAndRemoveAlwaysTargetAnExplicitRunner() throws {
        let launch = ResolvedRunnerCommand(
            executableURL: URL(fileURLWithPath: "/tools/amp"),
            arguments: ["--runner-id", "second", "--settings-file=/config/settings.json"],
            workingDirectoryURL: URL(fileURLWithPath: "/projects")
        )
        XCTAssertEqual(try RunnerDirectoryCommand.resolve(.list, launch: launch).arguments,
                       ["runner", "dirs", "list", "--runner-id", "second", "--settings-file", "/config/settings.json"])
        XCTAssertEqual(try RunnerDirectoryCommand.resolve(.remove("/projects/old"), launch: launch).arguments,
                       ["runner", "dirs", "remove", "/projects/old", "--runner-id", "second", "--settings-file", "/config/settings.json"])
        let unnamed = ResolvedRunnerCommand(executableURL: launch.executableURL, arguments: ["--no-tui"], workingDirectoryURL: launch.workingDirectoryURL)
        XCTAssertThrowsError(try RunnerDirectoryCommand.resolve(.list, launch: unnamed))
    }
}
