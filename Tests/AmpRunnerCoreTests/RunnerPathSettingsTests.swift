import XCTest
@testable import AmpRunnerCore

final class RunnerPathSettingsTests: XCTestCase {

    private let home = "/Users/tester"

    func testResolveOrdersUserInheritedAndExistingConventionalDirectories() {
        let resolved = RunnerPathResolver.resolve(
            settings: RunnerPathSettings(userDirectories: ["~/custom/bin", "/tools/bin"]),
            inheritedPath: "/inherited/one:/inherited/two",
            homeDirectoryPath: home
        ) { path in
            path == "/Users/tester/.local/bin" || path == "/usr/bin"
        }

        XCTAssertEqual(
            resolved.directories,
            [
                "/Users/tester/custom/bin", "/tools/bin", "/inherited/one", "/inherited/two",
                "/Users/tester/.local/bin", "/usr/bin"
            ]
        )
        XCTAssertEqual(resolved.path, resolved.directories.joined(separator: ":"))
    }

    func testStatusExpandsBareAndPrefixedTildes() {
        XCTAssertEqual(
            RunnerPathResolver.status(of: "~", homeDirectoryPath: home, directoryExists: { _ in true }),
            .valid(home)
        )
        XCTAssertEqual(
            RunnerPathResolver.status(of: "~/bin", homeDirectoryPath: home, directoryExists: { _ in true }),
            .valid("/Users/tester/bin")
        )
    }

    func testStatusNormalizesTrailingSlashAndDotComponents() {
        XCTAssertEqual(
            RunnerPathResolver.status(
                of: "/tools/./bin/",
                homeDirectoryPath: home,
                directoryExists: { $0 == "/tools/bin" }
            ),
            .valid("/tools/bin")
        )
    }

    func testResolveStableDeduplicatesNormalizedDirectories() {
        let resolved = RunnerPathResolver.resolve(
            settings: RunnerPathSettings(userDirectories: ["/tools/bin/", "~/bin"]),
            inheritedPath: "/tools/./bin:/Users/tester/bin:/usr/bin:/usr/bin/",
            homeDirectoryPath: home,
            directoryExists: { $0 == "/usr/bin" }
        )

        XCTAssertEqual(resolved.directories, ["/tools/bin", "/Users/tester/bin", "/usr/bin"])
    }

    func testResolveIgnoresInvalidInheritedEntries() {
        let resolved = RunnerPathResolver.resolve(
            settings: RunnerPathSettings(),
            inheritedPath: "relative/bin::  :~/valid:~other/bin:/absolute/bin",
            homeDirectoryPath: home,
            directoryExists: { _ in false }
        )

        XCTAssertEqual(resolved.directories, ["/Users/tester/valid", "/absolute/bin"])
    }

    func testResolveIncludesOnlyExistingConventionalDirectories() {
        let resolved = RunnerPathResolver.resolve(
            settings: RunnerPathSettings(),
            inheritedPath: nil,
            homeDirectoryPath: home
        ) { path in
            path == "/Users/tester/.amp/bin" || path == "/opt/homebrew/sbin" || path == "/sbin"
        }

        XCTAssertEqual(
            resolved.directories,
            ["/Users/tester/.amp/bin", "/opt/homebrew/sbin", "/sbin"]
        )
    }

    func testResolvePreservesMissingValidUserDirectories() {
        let resolved = RunnerPathResolver.resolve(
            settings: RunnerPathSettings(userDirectories: ["/missing/bin"]),
            inheritedPath: nil,
            homeDirectoryPath: home,
            directoryExists: { _ in false }
        )

        XCTAssertEqual(resolved.directories, ["/missing/bin"])
        XCTAssertEqual(
            RunnerPathResolver.status(
                of: "/missing/bin",
                homeDirectoryPath: home,
                directoryExists: { _ in false }
            ),
            .missing("/missing/bin")
        )
    }

    func testStatusExplainsWhyEmptyWhitespaceAndUnsupportedPathValuesAreInvalid() {
        XCTAssertEqual(
            RunnerPathResolver.status(of: "   ", homeDirectoryPath: home, directoryExists: { _ in true }),
            .invalid("Path cannot be empty.")
        )
        XCTAssertEqual(
            RunnerPathResolver.status(of: "relative/bin", homeDirectoryPath: home, directoryExists: { _ in true }),
            .invalid("Enter an absolute directory, ~, or a path beginning with ~/.")
        )
        XCTAssertEqual(
            RunnerPathResolver.status(of: "~other/bin", homeDirectoryPath: home, directoryExists: { _ in true }),
            .invalid("Enter an absolute directory, ~, or a path beginning with ~/.")
        )
        XCTAssertEqual(
            RunnerPathResolver.status(of: "/tools:other", homeDirectoryPath: home, directoryExists: { _ in true }),
            .invalid("Path cannot contain : because it separates PATH entries.")
        )
    }

    func testResolveExcludesUserDirectoriesContainingPathSeparators() {
        let resolved = RunnerPathResolver.resolve(
            settings: RunnerPathSettings(userDirectories: ["/valid/bin", "/tools:other"]),
            inheritedPath: nil,
            homeDirectoryPath: home,
            directoryExists: { _ in false }
        )

        XCTAssertEqual(resolved.directories, ["/valid/bin"])
    }

    func testStatusAllowsSpacesWithinAnAbsolutePath() {
        XCTAssertEqual(
            RunnerPathResolver.status(
                of: " /Users/tester/Tool Bin ",
                homeDirectoryPath: home,
                directoryExists: { $0 == "/Users/tester/Tool Bin" }
            ),
            .valid("/Users/tester/Tool Bin")
        )
    }

    func testSettingsCodableRoundTripPreservesOrderedUserDirectories() throws {
        let settings = RunnerPathSettings(userDirectories: ["~/bin", "/tools/bin"])
        let decoded = try JSONDecoder().decode(RunnerPathSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertEqual(decoded, settings)
    }

    func testSettingsDefaultInitializerIsEmpty() {
        XCTAssertEqual(RunnerPathSettings().userDirectories, [])
    }

    func testPublicTypesAreEquatableAndSendable() {
        func acceptsSendable<T: Sendable>(_: T) {}

        acceptsSendable(RunnerPathSettings())
        acceptsSendable(RunnerPathEntryStatus.valid("/bin"))
        acceptsSendable(ResolvedRunnerPath(directories: ["/bin"]))

        XCTAssertEqual(RunnerPathEntryStatus.valid("/bin"), .valid("/bin"))
        XCTAssertEqual(
            ResolvedRunnerPath(directories: ["/bin"]),
            ResolvedRunnerPath(directories: ["/bin"])
        )
    }
}
