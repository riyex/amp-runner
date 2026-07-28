import XCTest
@testable import AmpRunnerCore

final class RunnerCommandBuilderTests: XCTestCase {

    private let home = "/Users/tester"

    private func makeProfile(
        workingDirectory: String = "/Users/tester/src/sampleProject",
        executable: String = "/opt/homebrew/bin/amp",
        arguments: [String]? = nil,
        runnerID: String = "sample-runner"
    ) -> RunnerProfile {
        RunnerProfile(
            name: "SampleProject",
            runnerID: runnerID,
            workingDirectoryPath: workingDirectory,
            ampExecutablePath: executable,
            arguments: arguments
        )
    }

    // MARK: - Default arguments

    func testDefaultArgumentsIncludeRunnerID() {
        XCTAssertEqual(
            RunnerProfile.defaultArguments(runnerID: "sample-runner"),
            ["--no-tui", "--runner-id", "sample-runner", "--remote-control-terminal"]
        )
    }

    func testDefaultArgumentsOmitRunnerIDFlagWhenIDIsBlank() {
        XCTAssertEqual(
            RunnerProfile.defaultArguments(runnerID: "   "),
            ["--no-tui", "--remote-control-terminal"]
        )
    }

    func testProfileSeedsDefaultArgumentsWhenNoneProvided() {
        XCTAssertEqual(
            makeProfile().arguments,
            ["--no-tui", "--runner-id", "sample-runner", "--remote-control-terminal"]
        )
    }

    // MARK: - Tilde expansion

    func testExpandsTildePrefix() {
        XCTAssertEqual(
            RunnerCommandBuilder.expand(path: "~/src/sampleProject", homeDirectoryPath: home),
            "/Users/tester/src/sampleProject"
        )
    }

    func testExpandsBareTilde() {
        XCTAssertEqual(
            RunnerCommandBuilder.expand(path: "~", homeDirectoryPath: home),
            home
        )
    }

    func testDoesNotExpandTildeInsideOtherUserPath() {
        // "~other/x" is not this app's business to resolve — leave it alone.
        XCTAssertEqual(
            RunnerCommandBuilder.expand(path: "~other/x", homeDirectoryPath: home),
            "~other/x"
        )
    }

    func testStandardizesRedundantPathComponents() {
        XCTAssertEqual(
            RunnerCommandBuilder.expand(path: "/Users/tester/./src//sampleProject/", homeDirectoryPath: home),
            "/Users/tester/src/sampleProject"
        )
    }

    // MARK: - Resolution

    func testResolveProducesAbsoluteURLsAndArguments() throws {
        let command = try RunnerCommandBuilder.resolve(
            profile: makeProfile(workingDirectory: "~/src/sampleProject"),
            homeDirectoryPath: home
        )
        XCTAssertEqual(command.executableURL.path, "/opt/homebrew/bin/amp")
        XCTAssertEqual(command.workingDirectoryURL.path, "/Users/tester/src/sampleProject")
        XCTAssertEqual(
            command.arguments,
            ["--no-tui", "--runner-id", "sample-runner", "--remote-control-terminal"]
        )
    }

    func testResolveDropsBlankArguments() throws {
        let command = try RunnerCommandBuilder.resolve(
            profile: makeProfile(arguments: ["--no-tui", "  ", "", " --remote-control-terminal "]),
            homeDirectoryPath: home
        )
        XCTAssertEqual(command.arguments, ["--no-tui", "--remote-control-terminal"])
    }

    func testResolvePreservesArgumentOrderAndDuplicates() throws {
        let command = try RunnerCommandBuilder.resolve(
            profile: makeProfile(arguments: ["--a", "--b", "--a"]),
            homeDirectoryPath: home
        )
        XCTAssertEqual(command.arguments, ["--a", "--b", "--a"])
    }

    func testResolveRejectsEmptyExecutable() {
        XCTAssertThrowsError(
            try RunnerCommandBuilder.resolve(
                profile: makeProfile(executable: "   "),
                homeDirectoryPath: home
            )
        ) { error in
            XCTAssertEqual(error as? RunnerCommandBuilderError, .emptyExecutablePath)
        }
    }

    func testResolveRejectsEmptyWorkingDirectory() {
        XCTAssertThrowsError(
            try RunnerCommandBuilder.resolve(
                profile: makeProfile(workingDirectory: ""),
                homeDirectoryPath: home
            )
        ) { error in
            XCTAssertEqual(error as? RunnerCommandBuilderError, .emptyWorkingDirectory)
        }
    }

    func testResolveRejectsRelativeExecutable() {
        XCTAssertThrowsError(
            try RunnerCommandBuilder.resolve(
                profile: makeProfile(executable: "amp"),
                homeDirectoryPath: home
            )
        ) { error in
            XCTAssertEqual(error as? RunnerCommandBuilderError, .relativeExecutablePath("amp"))
        }
    }

    func testResolveRejectsRelativeWorkingDirectory() {
        XCTAssertThrowsError(
            try RunnerCommandBuilder.resolve(
                profile: makeProfile(workingDirectory: "src/sampleProject"),
                homeDirectoryPath: home
            )
        ) { error in
            XCTAssertEqual(
                error as? RunnerCommandBuilderError,
                .relativeWorkingDirectory("src/sampleProject")
            )
        }
    }

    // MARK: - Preview

    func testCommandPreviewIsCopyPasteable() throws {
        let command = try RunnerCommandBuilder.resolve(
            profile: makeProfile(),
            homeDirectoryPath: home
        )
        XCTAssertEqual(
            RunnerCommandBuilder.commandPreview(for: command),
            "cd /Users/tester/src/sampleProject && /opt/homebrew/bin/amp --no-tui --runner-id sample-runner --remote-control-terminal"
        )
    }

    func testCommandPreviewQuotesPathsContainingSpaces() throws {
        let command = try RunnerCommandBuilder.resolve(
            profile: makeProfile(workingDirectory: "/Users/tester/My Projects/sampleProject"),
            homeDirectoryPath: home
        )
        let preview = RunnerCommandBuilder.commandPreview(for: command)
        XCTAssertTrue(preview.hasPrefix("cd '/Users/tester/My Projects/sampleProject' && "), preview)
    }

    func testCommandPreviewEscapesEmbeddedSingleQuote() {
        XCTAssertEqual(RunnerCommandBuilder.shellQuote("it's"), #"'it'\''s'"#)
    }

    func testCommandPreviewQuotesEmptyString() {
        XCTAssertEqual(RunnerCommandBuilder.shellQuote(""), "''")
    }

    func testCommandPreviewForInvalidProfileReturnsReadableError() {
        let preview = RunnerCommandBuilder.commandPreview(
            for: makeProfile(executable: ""),
            homeDirectoryPath: home
        )
        XCTAssertEqual(preview, RunnerCommandBuilderError.emptyExecutablePath.description)
    }

    // MARK: - Quick start seed

    func testSampleProjectQuickStartMatchesSpecifiedDefaults() {
        let profile = RunnerProfile.sampleProjectQuickStart(
            homeDirectoryPath: home,
            ampExecutablePath: "/opt/homebrew/bin/amp"
        )
        XCTAssertEqual(profile.name, "SampleProject")
        XCTAssertEqual(profile.runnerID, "sample-runner")
        XCTAssertEqual(profile.workingDirectoryPath, "/Users/tester/src/sampleProject")
        XCTAssertEqual(profile.ampExecutablePath, "/opt/homebrew/bin/amp")
        XCTAssertTrue(profile.confirmBeforeStart)
        XCTAssertFalse(profile.autoStart)
    }

    func testConfirmBeforeStartDefaultsToTrue() {
        XCTAssertTrue(makeProfile().confirmBeforeStart)
    }
}
