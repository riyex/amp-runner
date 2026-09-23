import XCTest
@testable import AmpRunnerCore

final class RunnerCommandBuilderTests: XCTestCase {

    private let home = "/Users/tester"

    private func makeProfile(
        workingDirectory: String = "/Users/tester/src/sample-project",
        executable: String = "/opt/homebrew/bin/amp",
        arguments: [String]? = nil,
        runnerID: String = "sample-runner"
    ) -> RunnerProfile {
        RunnerProfile(
            name: "Sample Project",
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
            [
                "--no-tui", "--runner-id", "sample-runner", "--remote-control-terminal",
                "--discover-dirs", "--amp-env"
            ]
        )
    }

    func testDefaultArgumentsOmitRunnerIDFlagWhenIDIsBlank() {
        XCTAssertEqual(
            RunnerProfile.defaultArguments(runnerID: "   "),
            ["--no-tui", "--remote-control-terminal", "--discover-dirs", "--amp-env"]
        )
    }

    func testProfileSeedsDefaultArgumentsWhenNoneProvided() {
        XCTAssertEqual(
            makeProfile().arguments,
            [
                "--no-tui", "--runner-id", "sample-runner", "--remote-control-terminal",
                "--discover-dirs", "--amp-env"
            ]
        )
    }

    func testDirectoryControlsParseMixedEqualsAndSpaceForms() {
        let profile = makeProfile(arguments: [
            "--custom", "value",
            "--discover-dirs", "--discover-dirs=../shared files", "--discover-dirs", "~/src/other",
            "--dir", "explicit one", "--dir=../explicit-two",
            "--amp-env", "--no-serve-cwd"
        ])

        XCTAssertTrue(profile.discoversWorkingDirectory)
        XCTAssertEqual(profile.discoveryDirectoryPaths, ["../shared files", "~/src/other"])
        XCTAssertEqual(profile.servedDirectoryPaths, ["explicit one", "../explicit-two"])
        XCTAssertTrue(profile.usesAmpEnvironment)
        XCTAssertFalse(profile.servesWorkingDirectory)
    }

    func testBareDiscoverDirsDoesNotConsumeFollowingFlagOrUnknownValue() {
        let profile = makeProfile(arguments: ["--discover-dirs", "--custom", "value"])
        XCTAssertTrue(profile.discoversWorkingDirectory)
        XCTAssertEqual(profile.discoveryDirectoryPaths, [])
        XCTAssertEqual(profile.arguments, ["--discover-dirs", "--custom", "value"])
    }

    func testBareDiscoveryDoesNotTurnShortOptionsIntoDirectoryPaths() throws {
        var profile = makeProfile(arguments: ["--discover-dirs", "-m", "low"])
        XCTAssertTrue(profile.discoversWorkingDirectory)
        XCTAssertEqual(profile.discoveryDirectoryPaths, [])
        let command = try RunnerCommandBuilder.resolve(profile: profile, homeDirectoryPath: home)
        XCTAssertEqual(command.arguments, ["--discover-dirs", "-m", "low"])
        profile.discoversWorkingDirectory = false
        XCTAssertEqual(profile.arguments, ["-m", "low"])
    }

    func testDirectoryControlSettersPreserveUnknownFlagsAndAvoidDuplicates() {
        var profile = makeProfile(arguments: [
            "--custom", "keep me", "--discover-dirs", "--discover-dirs=old",
            "--dir", "old served", "--amp-env", "--amp-env", "--no-serve-cwd"
        ])

        profile.discoversWorkingDirectory = false
        profile.discoveryDirectoryPaths = ["one path", "two"]
        profile.servedDirectoryPaths = ["served path"]
        profile.usesAmpEnvironment = false
        profile.servesWorkingDirectory = true

        XCTAssertEqual(profile.arguments, [
            "--custom", "keep me", "--discover-dirs=one path", "--discover-dirs=two",
            "--dir", "served path"
        ])
        XCTAssertEqual(profile.discoveryDirectoryPaths, ["one path", "two"])
        XCTAssertEqual(profile.servedDirectoryPaths, ["served path"])
    }

    func testMalformedManagedFlagsDoNotConsumeUnknownFlags() {
        var profile = makeProfile(arguments: ["--dir", "--custom", "--runner-id", "--other"])

        profile.servedDirectoryPaths = ["served"]
        profile.syncRunnerID("new")

        XCTAssertEqual(profile.arguments, [
            "--dir", "--custom", "--runner-id", "--other", "--dir", "served", "--runner-id", "new"
        ])
    }

    func testExplicitOnlyDirectoryConfiguration() {
        var profile = makeProfile(arguments: ["--discover-dirs", "--amp-env"])
        profile.discoversWorkingDirectory = false
        profile.discoveryDirectoryPaths = []
        profile.servedDirectoryPaths = ["../one", "/tmp/two"]

        XCTAssertFalse(profile.discoversWorkingDirectory)
        XCTAssertEqual(profile.arguments, ["--amp-env", "--dir", "../one", "--dir", "/tmp/two"])
    }

    func testSyncRunnerIDPreservesCustomFlagsAndReplacesAllRunnerIDForms() {
        var profile = makeProfile(arguments: [
            "--custom", "keep", "--runner-id", "old", "--runner-id=older", "--amp-env"
        ])

        profile.syncRunnerID("new runner")

        XCTAssertEqual(profile.runnerID, "new runner")
        XCTAssertEqual(profile.arguments, ["--custom", "keep", "--runner-id", "new runner", "--amp-env"])
    }

    // MARK: - Tilde expansion

    func testExpandsTildePrefix() {
        XCTAssertEqual(
            RunnerCommandBuilder.expand(path: "~/src/sample-project", homeDirectoryPath: home),
            "/Users/tester/src/sample-project"
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
            RunnerCommandBuilder.expand(path: "/Users/tester/./src//sample-project/", homeDirectoryPath: home),
            "/Users/tester/src/sample-project"
        )
    }

    // MARK: - Resolution

    func testResolveProducesAbsoluteURLsAndArguments() throws {
        let command = try RunnerCommandBuilder.resolve(
            profile: makeProfile(workingDirectory: "~/src/sample-project"),
            homeDirectoryPath: home
        )
        XCTAssertEqual(command.executableURL.path, "/opt/homebrew/bin/amp")
        XCTAssertEqual(command.workingDirectoryURL.path, "/Users/tester/src/sample-project")
        XCTAssertEqual(
            command.arguments,
            [
                "--no-tui", "--runner-id", "sample-runner", "--remote-control-terminal",
                "--discover-dirs", "--amp-env"
            ]
        )
    }

    func testResolveDirectoryArgumentsAgainstWorkingDirectoryWithoutSplittingSpaces() throws {
        let command = try RunnerCommandBuilder.resolve(
            profile: makeProfile(
                workingDirectory: "~/My Projects/main",
                arguments: [
                    "--discover-dirs=../shared files", "--discover-dirs", "~/other project",
                    "--dir", "relative served", "--dir=/absolute served"
                ]
            ),
            homeDirectoryPath: home
        )

        XCTAssertEqual(command.arguments, [
            "--discover-dirs=/Users/tester/My Projects/shared files",
            "--discover-dirs=/Users/tester/other project",
            "--dir", "/Users/tester/My Projects/main/relative served",
            "--dir", "/absolute served"
        ])
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
                profile: makeProfile(workingDirectory: "src/sample-project"),
                homeDirectoryPath: home
            )
        ) { error in
            XCTAssertEqual(
                error as? RunnerCommandBuilderError,
                .relativeWorkingDirectory("src/sample-project")
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
            "cd /Users/tester/src/sample-project && /opt/homebrew/bin/amp --no-tui --runner-id sample-runner --remote-control-terminal --discover-dirs --amp-env"
        )
    }

    func testCommandPreviewQuotesPathsContainingSpaces() throws {
        let command = try RunnerCommandBuilder.resolve(
            profile: makeProfile(workingDirectory: "/Users/tester/My Projects/sample-project"),
            homeDirectoryPath: home
        )
        let preview = RunnerCommandBuilder.commandPreview(for: command)
        XCTAssertTrue(preview.hasPrefix("cd '/Users/tester/My Projects/sample-project' && "), preview)
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

    func testConfirmBeforeStartDefaultsToTrue() {
        XCTAssertTrue(makeProfile().confirmBeforeStart)
    }
}
